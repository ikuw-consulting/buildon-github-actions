#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# manifest-patch-apply.bash - Apply yq patches to the manifests beside them
#
# See YqPatches.md for the design. The grammar (what a patch file is called,
# which types exist, what a description may hold) lives in
# lib/manifest-file-kinds.bash; this library is only about applying them.
#
# Each target is patched inside its own sandbox holding that manifest and its
# own patches and nothing else, so a patch for one file cannot reach another
# and every intermediate state is left behind for provenance. The result is
# copied back over the target.
#
# Three rules apply to every patch, whatever its type:
#
#   The baseline is NORMALISED, not the original bytes. yq reformats a whole
#   file even for a semantic no-op (indentation normalised, comment spacing
#   collapsed), so comparing raw bytes would report "changed" for a patch that
#   did nothing and the no-op rule would be defeated by its own tooling.
#
#   A patch that changes nothing FAILS. yq exits 0 and says nothing when an
#   expression matches no path, so the diff is the only thing that will notice.
#
#   Output is checked by SHAPE, not by parsing. yq cannot emit invalid YAML -
#   `null`, a bare scalar and `del(.)` all re-parse cleanly - so a parse check
#   can never fail. Non-empty, a mapping, with kind and apiVersion is the check
#   that catches a line which destroyed the manifest.
#
# Functions:
#   manifest_patch_tree - apply every patch in a tree, in order, per target
#
# Requires lib/log.bash and lib/manifest-file-kinds.bash. Requires yq 4.
#
# shellcheck disable=SC2154  # MANIFEST_FILE_* set by lib/manifest-file-kinds.bash
# shellcheck disable=SC2016  # '$ENV' is a yq operator name, not a shell expansion

# Operators that read outside the patch file. Banned in the two expression
# types, which is a boundary the sandbox cannot provide: yq's file operators
# take any path, so `..` and absolute paths resolve against the real
# filesystem regardless of which directory the patch is applied in.
#
# Verified reachable without this: load_str reads any file as a raw string,
# strenv reads any environment variable, and either can be written straight
# into a manifest that is then packaged and pushed.
#
# Matched as a pattern, not as literal strings. yq accepts whitespace between an
# operator and its parenthesis (`load_str ("f")`), and its file readers are a
# family (load, load_str, load_props, load_xml, load_base64, loadJson, ...), so
# a list of exact spellings let `load_str (` and `load_props(` straight through.
# Covered: any load* call, env( and strenv( calls, $ENV, and envsubst, which
# reads the environment with no argument at all. A preceding '.' or identifier
# character means a key, not an operator, so `.metadata.labels.env = "prod"` and
# a key named `load` are still allowed. A string literal that merely contains
# one of these names is rejected too - fail-safe, and trivially reworded.
# merge-yaml is exempt: its content is data that is never evaluated.
MANIFEST_PATCH_BANNED_PATTERN='(^|[^A-Za-z0-9_.$])(load[A-Za-z0-9_]*|strenv|env)[[:space:]]*\(|\$ENV([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_.$])envsubst([^A-Za-z0-9_]|$)'

# Defence in depth, where yq supports it (4.45+; Kaptain's floor is older): the
# expression types run with yq's own file and env operators disabled, so an
# operator this pattern has not anticipated still cannot read the host.
# merge-yaml cannot take these flags - it merges through load() - and does not
# need them, because its patch is never evaluated as an expression. Probed once,
# on the first expression patch, so a build with no patches never pays for it.
MANIFEST_PATCH_YQ_SANDBOX_FLAGS=()
MANIFEST_PATCH_YQ_SANDBOX_PROBED=false

# Internal: fill MANIFEST_PATCH_YQ_SANDBOX_FLAGS on first use.
manifest_patch_probe_sandbox() {
  ${MANIFEST_PATCH_YQ_SANDBOX_PROBED} && return 0
  MANIFEST_PATCH_YQ_SANDBOX_PROBED=true
  case "$(yq --help 2>/dev/null)" in
    *--security-disable-file-ops*)
      MANIFEST_PATCH_YQ_SANDBOX_FLAGS=(--security-disable-file-ops --security-disable-env-ops)
      ;;
  esac
}

# Internal: normalised checksum of a manifest, the baseline a patch is
# measured against. Formatting-only differences are invisible to it by
# construction, because it is yq's own output either way.
manifest_patch_checksum() {
  yq e '.' "${1}" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

# Internal: does this file still look like a Kubernetes manifest?
# Usage: manifest_patch_shape_ok <file> <label>
manifest_patch_shape_ok() {
  local file="${1}" label="${2}"
  local kind api

  if [[ ! -s "${file}" ]]; then
    log_error "  ${label}: left the manifest empty"
    return 1
  fi
  kind=$(yq e '.kind // ""' "${file}" 2>/dev/null || true)
  api=$(yq e '.apiVersion // ""' "${file}" 2>/dev/null || true)
  if [[ -z "${kind}" || -z "${api}" ]]; then
    log_error "  ${label}: left the manifest without kind or apiVersion"
    return 1
  fi
  return 0
}

# Internal: reject an expression that reads outside itself.
# Usage: manifest_patch_check_operators <patch-file> <label>
manifest_patch_check_operators() {
  local patch="${1}" label="${2}"
  local content op clean=true

  # In-process regex, no subprocess per patch. Each match is named by trimming
  # its boundary character and everything from the first non-name character
  # (the parenthesis, whitespace), then consumed so the next one is found.
  content=$(<"${patch}")
  while [[ "${content}" =~ ${MANIFEST_PATCH_BANNED_PATTERN} ]]; do
    op="${BASH_REMATCH[0]#[!A-Za-z\$]}"
    op="${op%%[!A-Za-z0-9_\$]*}"
    log_error "  ${label}: uses '${op}', which reads outside the patch"
    clean=false
    content="${content#*"${BASH_REMATCH[0]}"}"
  done

  if ! ${clean}; then
    log_error "    A patch may use tokens, which resolve through substitution and are"
    log_error "    declared. Reading a file or an environment variable is neither."
  fi
  ${clean}
}

# Internal: apply one patch file to one manifest, in the sandbox.
# Usage: manifest_patch_apply_one <manifest> <patch> <type> <label> <sandbox> <seq>
manifest_patch_apply_one() {
  local manifest="${1}" patch="${2}" patch_type="${3}" label="${4}" sandbox="${5}" seq="${6}"

  case "${patch_type}" in
    merge-yaml)
      if ! yq e '.' "${patch}" >/dev/null 2>&1; then
        log_error "  ${label}: not valid YAML"
        return 1
      fi
      manifest_patch_step "${manifest}" "${label}" "${sandbox}" "${seq}" "" \
        ". *+ load(\"${patch}\")"
      ;;
    from-file)
      manifest_patch_check_operators "${patch}" "${label}" || return 1
      if [[ ! -s "${patch}" ]]; then
        log_error "  ${label}: empty patch file"
        return 1
      fi
      manifest_patch_step "${manifest}" "${label}" "${sandbox}" "${seq}" "" \
        "$(cat "${patch}")" sandboxed
      ;;
    expression-list)
      manifest_patch_check_operators "${patch}" "${label}" || return 1
      local line_no=0 expression applied=0
      while IFS= read -r expression || [[ -n "${expression}" ]]; do
        line_no=$((line_no + 1))
        case "${expression}" in
          ''|[[:space:]]*'#'*|'#'*) continue ;;
        esac
        [[ -z "${expression//[[:space:]]/}" ]] && continue
        manifest_patch_step "${manifest}" "${label} line ${line_no}" \
          "${sandbox}" "${seq}" "${line_no}" "${expression}" sandboxed || return 1
        applied=$((applied + 1))
      done < "${patch}"
      if [[ "${applied}" -eq 0 ]]; then
        log_error "  ${label}: no expressions, only blanks and comments"
        return 1
      fi
      ;;
  esac
}

# Internal: one yq application, with the before-state kept, the no-op check and
# the shape check. Every rule in the header is enforced here so no type can
# skip one.
#
# Usage: manifest_patch_step <manifest> <label> <sandbox> <seq> <line-or-empty> <expression> [sandboxed]
# 'sandboxed' applies MANIFEST_PATCH_YQ_SANDBOX_FLAGS; the expression types pass it.
manifest_patch_step() {
  local manifest="${1}" label="${2}" sandbox="${3}" seq="${4}" line="${5}" expression="${6}"
  local -a yq_flags=()
  if [[ "${7:-}" == "sandboxed" ]]; then
    manifest_patch_probe_sandbox
    yq_flags=(${MANIFEST_PATCH_YQ_SANDBOX_FLAGS[@]+"${MANIFEST_PATCH_YQ_SANDBOX_FLAGS[@]}"})
  fi
  local before_name
  before_name="before-$(printf '%03d' "${seq}")"
  [[ -n "${line}" ]] && before_name="${before_name}-line-$(printf '%03d' "${line}")"

  # The state going in, kept whatever happens next.
  cp "${manifest}" "${sandbox}/${before_name}.yaml"

  local baseline result
  baseline=$(manifest_patch_checksum "${manifest}")

  local tmp="${manifest}.applying"
  cp "${manifest}" "${tmp}"
  if ! yq e -i ${yq_flags[@]+"${yq_flags[@]}"} "${expression}" "${tmp}" 2>"${sandbox}/${before_name}.stderr"; then
    log_error "  ${label}: yq rejected the expression"
    while IFS= read -r line; do log_error "    ${line}"; done < "${sandbox}/${before_name}.stderr"
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${sandbox}/${before_name}.stderr"

  result=$(manifest_patch_checksum "${tmp}")
  if [[ "${result}" == "${baseline}" ]]; then
    log_error "  ${label}: changed nothing"
    log_error "    yq reports success when an expression matches no path, so a patch that"
    log_error "    does nothing is either already applied, aimed at the wrong thing, or"
    log_error "    written against a shape the manifest no longer has."
    rm -f "${tmp}"
    return 1
  fi

  if ! manifest_patch_shape_ok "${tmp}" "${label}"; then
    rm -f "${tmp}"
    return 1
  fi

  mv "${tmp}" "${manifest}"
}

# Apply every patch in a tree to the manifest beside it.
#
# Patches for one target apply in LC_ALL=C order of their descriptions, which
# is what the description is for. Sorting the whole filename instead would let
# the TYPE dominate, so a merge-yaml patch would always follow an
# expression-list one whatever the author named them.
#
# Usage: manifest_patch_tree <tree> <sandbox-base>
# Returns: 0 with every patch applied, 1 with the failures logged
# Sets: MANIFEST_PATCH_APPLIED_COUNT, MANIFEST_PATCH_TARGET_COUNT
manifest_patch_tree() {
  local tree="${1}" sandbox_base="${2}"
  local LC_ALL=C

  MANIFEST_PATCH_APPLIED_COUNT=0
  MANIFEST_PATCH_TARGET_COUNT=0

  # Index the patches by target: '<target-path>\t<desc>\t<patch-path>\t<type>'.
  local index="${sandbox_base}/patch-index.tsv"
  mkdir -p "${sandbox_base}"
  : > "${index}"

  local file target_path
  while IFS= read -r file; do
    manifest_file_classify "${file}" || continue
    [[ "${MANIFEST_FILE_KIND}" == "patch" ]] || continue
    target_path="$(dirname "${file}")/${MANIFEST_FILE_PATCH_TARGET}"
    printf '%s\t%s\t%s\t%s\n' "${target_path}" "${MANIFEST_FILE_PATCH_DESC}" \
      "${file}" "${MANIFEST_FILE_PATCH_TYPE}" >> "${index}"
  done < <(manifest_files_find_packageable "${tree}")

  [[ -s "${index}" ]] || return 0

  local failed=false current="" sandbox seq rel
  local sorted="${sandbox_base}/patch-order.tsv"
  LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 "${index}" > "${sorted}"

  # 'desc' is read only to consume the sort key's column; the ordering it
  # controls has already happened.
  local patch_path patch_type desc
  # shellcheck disable=SC2034
  while IFS="$(printf '\t')" read -r target_path desc patch_path patch_type; do
    if [[ "${target_path}" != "${current}" ]]; then
      current="${target_path}"
      seq=0
      MANIFEST_PATCH_TARGET_COUNT=$((MANIFEST_PATCH_TARGET_COUNT + 1))
      rel="${target_path#"${tree}"/}"
      sandbox="${sandbox_base}/$(printf '%s' "${rel}" | tr '/' '_')"
      mkdir -p "${sandbox}"
      log ""
      log "  ${rel}"
    fi
    seq=$((seq + 1))
    if manifest_patch_apply_one "${target_path}" "${patch_path}" "${patch_type}" \
        "${patch_path##*/}" "${sandbox}" "${seq}"; then
      log "    applied ${patch_path##*/}"
      MANIFEST_PATCH_APPLIED_COUNT=$((MANIFEST_PATCH_APPLIED_COUNT + 1))
    else
      failed=true
    fi
    cp "${target_path}" "${sandbox}/after-$(printf '%03d' "${seq}").yaml" 2>/dev/null || true
  done < "${sorted}"

  ! ${failed}
}
