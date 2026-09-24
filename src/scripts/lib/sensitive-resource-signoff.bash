#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# sensitive-resource-signoff.bash - Verify every sensitive K8s resource in
# the assembled manifest tree has a matching checked-in signoff.
#
# Sensitive kinds (Ingress, Gateway, RBAC, webhook configurations, etc.)
# can silently introduce privilege escalation, data exfiltration, or
# traffic redirection. Aggregating a product or bundle into an env (or
# run-platform) without explicit review is the failure mode. This
# library enforces the review by requiring a per-manifest signoff file
# under <signoffs-dir>, located at the manifest's path within the
# assembled tree.
#
# Signoff layout: the signoff path mirrors the manifest's path within
# the assembled tree, env-root segment stripped. Manifests can come
# from local src/kubernetes, aggregated apps, bundles, or products -
# wherever the manifest lands in the tree is where the signoff sits
# under <signoffs-dir>. <signoffs-dir> is caller-supplied (signoffsSubPath
# setting); the master disable lives at the entrypoint too
# (trustedContributorsOnly=true skips the call).
#
# Example: a manifest at  <tree>/run-foo/widgets/extra/gateway.yaml
# expects its signoff at  <signoffs-dir>/widgets/extra/gateway.yaml
#
# Signoff file shape (YAML):
#
#   sourcePath: widgets/extra/gateway.yaml
#   checksum:   sha256:<hex>
#   references:                  # optional, informational
#     - widgets/extra/httproute.yaml
#   reviewer:    fred             # optional, informational
#   ticket:      KAP-1234         # optional, informational
#
# Granularity: per-manifest-file (multi-doc YAML files are signed off
# as a single unit). Rationale: multi-doc YAML is a common K8s pattern
# and per-doc signoff would require a synthetic identifier; per-file
# matches how reviewers already think about a change.
#
# Canonicalisation: the hash is over the file projected to exclude
# build-injected provenance and integration annotations - otherwise the
# hash would couple to the pipeline rather than the resource content.
# Stripped keys:
#   metadata.annotations: our provenance annotations by exact name
#     (kaptain.org/ build-timestamp built-by generated-by git-sha
#     helm-upstream-chart image-uri source-repository), and ^keel.sh/
#     ^keelson.io/
#   metadata.labels      matching ^kaptain.org/version$ ^app.kubernetes.io/version$
#   metadata.creationTimestamp / resourceVersion / uid / generation /
#   managedFields, and status
# The same stripping applies inside spec.template.metadata for kinds that
# have a pod template (those carry the rollout-trigger annotations).
#
# Our annotations are listed by name rather than stripped by prefix so the
# check fails safe: a new kaptain.org/ annotation is hashed, and so reviewed,
# until it is deliberately added here. Stripping by prefix would silently
# exempt any future annotation that changes behaviour.
#
# Failure modes:
#   - Sensitive resource in tree, no matching signoff -> fail.
#   - Signoff file present but checksum mismatches -> fail (resource
#     changed since sign-off; requires re-review).
#   - Signoff file present but no matching sensitive resource -> fail
#     (stale signoff; either delete or investigate).
#
# Functions:
#   signoff_check_tree <manifests-dir> <signoffs-dir> [<sensitive-kinds-file>]
#       Top-level. Walks the tree, computes canonical hashes, validates
#       coverage and integrity against the signoff directory.
#
#   signoff_canonical_hash <manifest-file>
#       Compute and print the canonical hash for one manifest file
#       (hex SHA-256, no prefix).
#
# <sensitive-kinds-file> is optional. Format: one Kind per line, '#'
# starts a comment. Mapped from spec.main.environment.sensitiveResourceKinds
# (or src/config/SensitiveResourceKinds) by the caller.
#
# SIGNOFF_SKELETON_DIR (optional env): when set, every missing-signoff
# failure also writes a review-ready skeleton file (sourcePath + computed
# canonical checksum) at <SIGNOFF_SKELETON_DIR>/<sourcePath>, so
# configuring the signoff is a review plus a copy. Unset = messages only.

# shellcheck disable=SC2034 # Public function output vars are read by callers.

# The sensitive-Kind list ships as versioned-immutable data
# (src/data/signoff-kinds/<name>-<version>.txt); the caller resolves the
# configured file name in that fixed directory and passes the path to
# signoff_check_tree. The selected file replaces any other list entirely
# (no merge).

# yq projection that strips build-injected metadata before hashing.
# Applied at both top-level metadata and, where the kind has one,
# spec.template.metadata so rollout annotations on workload pod templates
# don't pollute the hash.
# NOTE: `(.x // {}) |= with_entries(...)` looks tempting here but in yq it
# leaves `x: null` when x was absent vs `x: {}` when x had only stripped
# keys - those are different bytes and produce different SHAs. The explicit
# `.x = ((.x // {}) | with_entries(...))` form normalises both cases to {}.
SIGNOFF_STRIP_ANNOTATION_KEEP='(.key | test("^(kaptain\\.org/(build-timestamp|built-by|generated-by|git-sha|helm-upstream-chart|image-uri|source-repository)$|keel\\.sh/|keelson\\.io/)")) | not'
SIGNOFF_STRIP_LABEL_KEEP='(.key != "kaptain.org/version") and (.key != "app.kubernetes.io/version")'
SIGNOFF_STRIP_EXPR="
  .metadata.annotations = ((.metadata.annotations // {}) | with_entries(select(${SIGNOFF_STRIP_ANNOTATION_KEEP})))
  | .metadata.labels = ((.metadata.labels // {}) | with_entries(select(${SIGNOFF_STRIP_LABEL_KEEP})))
  | del(.metadata.creationTimestamp,
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.generation,
        .metadata.managedFields,
        .status)
  | with(select(.spec.template != null).spec.template;
      .metadata.annotations = ((.metadata.annotations // {}) | with_entries(select(${SIGNOFF_STRIP_ANNOTATION_KEEP})))
      | .metadata.labels = ((.metadata.labels // {}) | with_entries(select(${SIGNOFF_STRIP_LABEL_KEEP}))))
"

# Portable SHA-256. Mirrors checksum-resolve.bash; duplicated here so
# this library is sourceable on its own without coupling.
signoff_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    log_error "No SHA-256 tool found (sha256sum or shasum required)"
    return 1
  fi
}

# Compute the canonical hash of a single manifest file. yq is run with
# eval-all so multi-doc YAML is preserved (each document gets the strip
# expression applied independently); json output canonicalises field
# order; sha256sum yields the final hex.
#
# Usage: signoff_canonical_hash <manifest-file>
signoff_canonical_hash() {
  if [[ $# -ne 1 ]]; then
    log_error "signoff_canonical_hash requires exactly 1 argument, got $#"
    return 1
  fi
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    log_error "Manifest file not found: ${file}"
    return 1
  fi
  yq eval-all "${SIGNOFF_STRIP_EXPR}" -o=json "${file}" \
    | jq -cS '.' \
    | signoff_sha256_hex
}

# Load the active sensitive-kind list from the given kinds file (one
# Kind per line, '#' comments). Result emitted on stdout, one kind per
# line. A missing file is a hard error: the gate must never silently run
# with an empty list.
signoff_load_kinds() {
  local kinds_file="${1:-}"
  if [[ -z "${kinds_file}" || ! -f "${kinds_file}" ]]; then
    log_error "signoff_load_kinds: kinds file not found: ${kinds_file:-<empty>}"
    return 1
  fi
  # Strip blank lines and comments; trim surrounding whitespace.
  awk 'NF && $1 !~ /^#/ { gsub(/^[ \t]+|[ \t]+$/, "", $0); print }' "${kinds_file}"
}

# Walk the manifests tree; emit one line per manifest file that contains
# at least one sensitive document. Output format: '<file-path>\n'.
# Skips internal index files written by neighbouring libraries (anything
# whose basename starts with a dot).
signoff_find_sensitive_files() {
  local manifests_dir="$1"
  local kinds_pattern="$2"

  local file kinds matched
  while IFS= read -r -d '' file; do
    case "$(basename "${file}")" in
      .*) continue ;;
    esac
    # All distinct kinds inside this file.
    kinds=$(yq eval-all '.kind // ""' "${file}" 2>/dev/null | LC_ALL=C sort -u | grep -v '^$' || true)
    [[ -z "${kinds}" ]] && continue
    matched=false
    local k
    while IFS= read -r k; do
      [[ -z "${k}" ]] && continue
      if grep -qxF "${k}" <<< "${kinds_pattern}"; then
        matched=true
        break
      fi
    done <<< "${kinds}"
    if [[ "${matched}" == "true" ]]; then
      printf '%s\n' "${file}"
    fi
  done < <(find "${manifests_dir}" -type f -name '*.yaml' -print0)
  # Explicit success: with the old '[[ ... ]] && printf' tail, a final
  # non-sensitive file made the loop (and so the function) return 1, which
  # killed set -e callers silently mid-scan.
  return 0
}

# Translate an in-tree manifest path to its env-root-relative source
# path. The manifest tree's first segment is the run/RP project name
# (the env root); the signoff source-path strips that prefix.
#
# Usage: signoff_source_path <manifests-dir> <manifest-file>
signoff_source_path() {
  local manifests_dir="$1"
  local file="$2"
  local rel="${file#"${manifests_dir}/"}"
  # rel starts with '<run-name>/...'; strip the first segment.
  case "${rel}" in
    */*) echo "${rel#*/}" ;;
    *)   echo "${rel}" ;;
  esac
}

# Verify one manifest file against its expected signoff. Logs the
# success or the specific failure mode. Returns 0 on match, 1 on any
# failure (missing signoff, checksum mismatch, malformed signoff).
#
# Usage: signoff_verify_file <manifests-dir> <signoffs-dir> <manifest-file>
signoff_verify_file() {
  local manifests_dir="$1"
  local signoffs_dir="$2"
  local manifest="$3"

  local source_path
  source_path=$(signoff_source_path "${manifests_dir}" "${manifest}")
  local signoff_file="${signoffs_dir}/${source_path}"

  if [[ ! -f "${signoff_file}" ]]; then
    local actual_hash
    actual_hash=$(signoff_canonical_hash "${manifest}") || return 1
    log_error "Sensitive resource has no signoff:"
    log_error "  manifest:           ${manifest}"
    log_error "  source path:        ${source_path}"
    log_error "  expected at:        ${signoff_file}"
    log_error "  canonical checksum: sha256:${actual_hash}"
    if [[ -n "${SIGNOFF_SKELETON_DIR:-}" ]]; then
      # Write a review-ready skeleton so configuring the signoff is a
      # review plus a copy, not hand-computed hashes.
      local skeleton_file="${SIGNOFF_SKELETON_DIR}/${source_path}"
      mkdir -p "$(dirname "${skeleton_file}")"
      {
        echo "# Generated signoff skeleton - REVIEW THE RESOURCE FIRST."
        echo "# Once reviewed, copy this file to: ${signoff_file}"
        echo "sourcePath: ${source_path}"
        echo "checksum: sha256:${actual_hash}"
        echo "# reviewer: <who reviewed it>"
        echo "# ticket:   <review ticket/PR reference>"
      } > "${skeleton_file}"
      log_error "  skeleton written:   ${skeleton_file}"
    fi
    return 1
  fi

  local actual expected
  actual=$(signoff_canonical_hash "${manifest}") || return 1
  expected=$(yq -r '.checksum // ""' "${signoff_file}")
  expected="${expected#sha256:}"

  if [[ -z "${expected}" ]]; then
    log_error "Signoff file is missing 'checksum' field: ${signoff_file}"
    return 1
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    log_error "Signoff checksum mismatch:"
    log_error "  manifest: ${manifest}"
    log_error "  signoff:  ${signoff_file}"
    log_error "  expected: sha256:${expected}"
    log_error "  actual:   sha256:${actual}"
    log_error "Resource has changed since sign-off. Re-review and update the"
    log_error "checksum field in the signoff file."
    return 1
  fi

  log "  OK  ${source_path}"
}

# Detect signoff files that no longer match any sensitive resource in
# the assembled tree (stale signoffs). Empty <signoffs-dir> -> no-op.
signoff_find_stale() {
  local signoffs_dir="$1"
  local consumed_index="$2"

  [[ -d "${signoffs_dir}" ]] || return 0

  local file rel
  local stale=()
  while IFS= read -r -d '' file; do
    rel="${file#"${signoffs_dir}/"}"
    if ! grep -qxF "${rel}" "${consumed_index}"; then
      stale+=("${file}")
    fi
  done < <(find "${signoffs_dir}" -type f -name '*.yaml' -print0)

  if (( ${#stale[@]} > 0 )); then
    log_error "Stale signoff(s) - no matching sensitive resource in the assembled tree:"
    local entry
    for entry in "${stale[@]}"; do
      log_error "  ${entry}"
    done
    log_error "Delete the file if the resource was intentionally removed, or"
    log_error "investigate why the resource is no longer present."
    return 1
  fi
}

# Top-level: validate signoff coverage and integrity across the tree.
#
# Usage: signoff_check_tree <manifests-dir> <signoffs-dir> <sensitive-kinds-file>
signoff_check_tree() {
  if [[ $# -ne 3 ]]; then
    log_error "Usage: signoff_check_tree <manifests-dir> <signoffs-dir> <sensitive-kinds-file>"
    return 1
  fi
  local manifests_dir="$1"
  local signoffs_dir="$2"
  local kinds_file="$3"

  if [[ ! -d "${manifests_dir}" ]]; then
    log_error "Manifests directory not found: ${manifests_dir}"
    return 1
  fi
  # Checked here, not only in signoff_load_kinds: that runs inside a
  # command substitution, which would swallow its error message.
  if [[ ! -f "${kinds_file}" ]]; then
    log_error "Sensitive-kinds file not found: ${kinds_file}"
    return 1
  fi
  for tool in yq jq; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      log_error "${tool} is required for signoff_check_tree"
      return 1
    fi
  done

  local kinds_pattern
  kinds_pattern=$(signoff_load_kinds "${kinds_file}") || return 1
  log "Sensitive kinds in effect (${kinds_file}):"
  local k
  while IFS= read -r k; do
    log "  - ${k}"
  done <<< "${kinds_pattern}"
  log ""

  local consumed_index="${manifests_dir}/.signoff-consumed"
  : > "${consumed_index}"

  log "Scanning ${manifests_dir} for sensitive resources..."
  local sensitive_files
  sensitive_files=$(signoff_find_sensitive_files "${manifests_dir}" "${kinds_pattern}")
  if [[ -z "${sensitive_files}" ]]; then
    log "  None found."
  fi

  local failed=0
  local manifest source_path
  while IFS= read -r manifest; do
    [[ -z "${manifest}" ]] && continue
    source_path=$(signoff_source_path "${manifests_dir}" "${manifest}")
    printf '%s\n' "${source_path}" >> "${consumed_index}"
    if ! signoff_verify_file "${manifests_dir}" "${signoffs_dir}" "${manifest}"; then
      failed=$((failed + 1))
    fi
  done <<< "${sensitive_files}"

  log ""
  if ! signoff_find_stale "${signoffs_dir}" "${consumed_index}"; then
    failed=$((failed + 1))
  fi

  if (( failed > 0 )); then
    log_error ""
    log_error "${failed} signoff problem(s) detected."
    if [[ -n "${SIGNOFF_SKELETON_DIR:-}" ]]; then
      log_error "Review-ready skeletons for missing signoffs were written under:"
      log_error "  ${SIGNOFF_SKELETON_DIR}/"
      log_error "Review each resource, then copy its skeleton into ${signoffs_dir}/."
    fi
    return 1
  fi
  log "Signoff check passed."
}
