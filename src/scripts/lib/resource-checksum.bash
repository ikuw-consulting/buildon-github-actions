#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# resource-checksum.bash - Checksum-marked resource renaming with tree-wide
# reference rewrite. See todo-checked/ResourceChecksum.md for the design.
#
# Opt-in by name: the marker is the whole '-<kind>-checksum' double banger
# (e.g. app-configmap-checksum) and it is REPLACED by the hash
# (app-configmap-checksum -> app-x2y5z). The kind fragment is type-noise
# (we don't call things NameString in code) so it goes away with the
# marker. Resources without the marker pass through untouched. A name
# ending '-checksum' WITHOUT its own lowercased kind fragment in front
# (bare foo-checksum, wrong case, another kind's fragment) could be a
# legit customer resource name, so it is warned and passed through
# untouched rather than failed.
#
# One entry point, called from the resource-checksum step of the
# *-finalise entrypoints:
#
#   checksum_tree <tree> <secrets-dir-or-empty> <order-file>
#       1. Inventory: scan the whole tree once and list every marked
#          resource.
#       2. Process Secret templates FIRST (Secrets are tier-1 leaves;
#          consumer-tier hashes must be computed over final Secret
#          names), hashing the INPUT SET: the rendered template's raw
#          bytes plus the base64 of each referenced token's encrypted
#          on-disk value (<secrets-dir>/<Token>.<type>), one per line in
#          LC_ALL=C token order, no name prefixes. The combined blob is
#          written under RESOURCE_CHECKSUM_AUDIT_DIR (default
#          ${OUTPUT_SUB_PATH}/run-finalise/secret-checksum-inputs) and
#          LEFT BEHIND for inspection. Pass an empty secrets-dir to skip
#          Secret templates entirely (RP builds: child-owned secrets).
#       3. Process remaining kinds in <order-file> sequence. Each
#          resource is hashed over its LIVE yq-canonicalised document
#          (so earlier rewrites are included), renamed, and every
#          bounded textual reference across the tree is rewritten
#          IMMEDIATELY: one checksum, one global rewrite, repeat.
#       4. Fail if any inventoried resource was never processed (its
#          kind is missing from the order file, or a marked Secret sits
#          outside a *.template.yaml).
#
# Reference rewriting is a plain bounded text replace, not a structured
# field matrix: checksum-marked names are unique by design and can be
# referenced anywhere (env values, CRD fields, annotations - any kind,
# current or future). Boundaries: adjacent characters must not be name
# characters [A-Za-z0-9_-], so wtf-bbq-configmap-checksum can never maul
# omg-wtf-bbq-configmap-checksum.
#
# Configuration env vars (read here, set by the entrypoint):
#   RESOURCE_CHECKSUM_LENGTH    Suffix length in Base32 chars. Default 5.
#                               Warns <4 or >12. Hard-fails >52
#                               (SHA-256 has 256 bits = 52 Base32 chars).
#   RESOURCE_CHECKSUM_AUDIT_DIR Where secret input blobs are kept.
#   TOKEN_DELIMITER_STYLE / TOKEN_NAME_STYLE  How secret-template tokens are
#                               matched (defaults/tokens.bash).
#
# Requires lib/token-format.bash and lib/secret-encryption-types.bash
# sourced by the caller.
#
# Required tools: yq 4, find, sed, sha256sum (via hash-base32.sh).

# shellcheck source=src/scripts/lib/hash-base32.sh
RESOURCE_CHECKSUM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RESOURCE_CHECKSUM_LIB_DIR}/hash-base32.sh"

# Validate the configured checksum length and normalise
# RESOURCE_CHECKSUM_LENGTH to the effective value in place. No stdout:
# the warnings below must reach the build log, not a
# command-substitution capture.
resource_checksum_length() {
  local length="${RESOURCE_CHECKSUM_LENGTH:-5}"
  if [[ ! "${length}" =~ ^[0-9]+$ ]]; then
    log_error "RESOURCE_CHECKSUM_LENGTH must be a positive integer, got '${length}'"
    return 1
  fi
  if (( length > 52 )); then
    log_error "RESOURCE_CHECKSUM_LENGTH=${length} exceeds 52 (SHA-256 only yields 52 Base32 chars)"
    return 1
  fi
  if (( length < 4 )); then
    log_warning "RESOURCE_CHECKSUM_LENGTH=${length} (< 4); collision risk rises sharply"
  elif (( length > 12 )); then
    log_warning "RESOURCE_CHECKSUM_LENGTH=${length} (> 12); long suffixes hurt readability"
  fi
  RESOURCE_CHECKSUM_LENGTH="${length}"
}

# Find every YAML file under <tree>. Null-delimited, LC_ALL=C sorted:
# processing order must be deterministic across builds, platforms, and
# locales. Note: same-kind reference chains (rare) only cascade correctly
# when the referenced resource sorts first - the order file guarantees
# leaves-before-consumers ACROSS kinds, not within one. If a real
# same-kind chain shows up, the fix is a dependency sort within the kind
# pass, not a smarter file order.
resource_checksum_find_yaml() {
  local tree="$1"
  find "${tree}" -type f -name '*.yaml' -print0 | LC_ALL=C sort -z
}

# Running totals for the whole pass, printed by the orchestrating step.
RESOURCE_CHECKSUM_TOTAL_RESOURCES=0
RESOURCE_CHECKSUM_TOTAL_REFS=0
RESOURCE_CHECKSUM_TOTAL_REF_FILES=0

# Rewrite every bounded textual occurrence of <old> to <new> across all
# YAML files in <tree>, in the exact output format the build log wants:
#
#   Found M referring resources:
#   Z  references replaced in <file>
#
# Two passes: count matches per file first (exact-token counting: split on
# every non-name character and count whole-token matches - immune to the
# adjacency undercounting a boundary-consuming regex suffers), print the
# header, then replace and print one line per file. Z is printed %-2d so
# file names sit in a neat left-aligned column for ref counts under 100.
rewrite_name_refs() {
  local tree="$1"
  local old="$2"
  local new="$3"

  # Names containing characters outside the token alphabet cannot be
  # token-bounded; refuse loudly rather than rewrite wrongly.
  if [[ "${old}" == *[!A-Za-z0-9_-]* ]]; then
    log_warning "'${old}' contains non name-token characters; textual ref rewrite skipped"
    return 0
  fi

  # Pass 1: count bounded occurrences per file.
  local file count
  local match_lines=""
  local match_count=0
  while IFS= read -r -d '' file; do
    count=$(tr -cs 'A-Za-z0-9_-' '\n' < "${file}" | grep -cxF "${old}" || true)
    if [[ "${count}" -gt 0 ]]; then
      match_lines="${match_lines}${count}	${file}
"
      match_count=$((match_count + 1))
    fi
  done < <(resource_checksum_find_yaml "${tree}")

  log "  Found ${match_count} referring resources:"

  [[ "${match_count}" -eq 0 ]] && return 0

  # Pass 2: replace and report. The boundary-consuming regex needs
  # re-runs when two occurrences share a single boundary character
  # (e.g. 'x,x'); loop to stability. Replacing old with new can never
  # re-match: new is the marker swapped for '-<hash>', and '-' is a name
  # character.
  local tmp line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    count="${line%%	*}"
    file="${line#*	}"
    tmp=$(mktemp)
    cp "${file}" "${tmp}"
    while :; do
      sed -E "s#(^|[^A-Za-z0-9_-])(${old})([^A-Za-z0-9_-]|\$)#\\1${new}\\3#g" "${tmp}" > "${tmp}.next"
      if cmp -s "${tmp}" "${tmp}.next"; then
        rm -f "${tmp}.next"
        break
      fi
      mv "${tmp}.next" "${tmp}"
    done
    mv "${tmp}" "${file}"
    # shellcheck disable=SC2059 # fixed format, %-2d keeps the file column aligned
    log "$(printf '  %-2d references replaced in %s' "${count}" "${file#"${tree}"/}")"
    RESOURCE_CHECKSUM_TOTAL_REFS=$((RESOURCE_CHECKSUM_TOTAL_REFS + count))
    RESOURCE_CHECKSUM_TOTAL_REF_FILES=$((RESOURCE_CHECKSUM_TOTAL_REF_FILES + 1))
  done <<< "${match_lines}"
}

# Hash a single Secret template's input set: the rendered manifest's raw
# bytes as-is (no parser in the loop: fast, stable against yq printer
# changes), then the raw base64 of each referenced token's encrypted
# on-disk value, one per line, in LC_ALL=C-sorted token order. NO
# token-name prefixes: a token rename with an unchanged value must not add
# hash-change surface beyond the document text itself. The combined blob
# is left behind under the audit dir for inspection.
#
# Sets SECRET_HASH and SECRET_TOKEN_COUNT on success. Returns 2 for the
# local-build skip case (missing value, warn), 1 for hard errors.
checksum_secret_input_set() {
  local tree="$1"
  local template_file="$2"
  local secrets_dir="$3"
  local length="$4"

  # Token names referenced by the template, in the configured delimiter
  # and name style, nested names included. LC_ALL=C: the token order feeds
  # the hash input, so collation MUST be identical across platforms and
  # locales. The sort runs on the delimited matches, before stripping, as it
  # always has: sorting the bare names instead would reorder existing hash
  # inputs (${Ab} sorts before ${A}, Ab after A) and rename every
  # checksummed Secret on its next build.
  local token_regex
  # shellcheck disable=SC2154 # TOKEN_*_STYLE set by the caller (defaults/tokens.bash)
  token_regex=$(unresolved_token_regex "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}") || return 1
  local tokens
  tokens=$(grep -oE "${token_regex}" "${template_file}" \
             | LC_ALL=C sort -u | strip_token_delimiters "${TOKEN_DELIMITER_STYLE}")

  local rel_path="${template_file#"${tree}"/}"
  local input_blob="${RESOURCE_CHECKSUM_AUDIT_DIR:-${OUTPUT_SUB_PATH:-kaptain-out}/run-finalise/secret-checksum-inputs}/${rel_path}.checksum-input"
  mkdir -p "$(dirname "${input_blob}")"

  cat "${template_file}" > "${input_blob}"

  local tok value_file
  while IFS= read -r tok; do
    [[ -z "${tok}" ]] && continue
    # Encrypted values carry an encryption-type suffix the deploy base
    # image can decrypt (<Token>.age etc; lib/secret-encryption-types.bash).
    secret_encryption_types_load || return 1
    value_file=$(secret_value_file_for_token "${secrets_dir}" "${tok}" || true)
    if [[ -z "${value_file}" || ! -f "${value_file}" ]]; then
      # No build-mode branch: this step runs after the substitution gate,
      # which now fails a missing secret value in every mode, so reaching
      # here at all means the gate was bypassed or has a hole.
      log_error "  Secret template ${rel_path} references token '${tok}'"
      log_error "  but no value exists at ${secrets_dir}/${tok}.<type>"
      log_error "  The upstream substitution gate should have failed this build already."
      return 1
    fi
    printf '%s\n' "$(base64 < "${value_file}" | tr -d '\n')" >> "${input_blob}"
  done <<< "${tokens}"

  SECRET_HASH=$(hash_base32 "${input_blob}" "${length}")
  SECRET_TOKEN_COUNT=$(printf '%s' "${tokens}" | grep -c . || true)
}

# Top-level orchestrator. See the file header for the full contract.
# Usage: checksum_tree <tree> <secrets-dir-or-empty> <order-file>
checksum_tree() {
  local tree="$1"
  local secrets_dir="$2"
  local order_file="$3"
  if [[ -z "${tree}" || -z "${order_file}" ]]; then
    log_error "checksum_tree: usage: <tree> <secrets-dir-or-empty> <order-file>"
    return 1
  fi
  if [[ ! -d "${tree}" ]]; then
    log_error "checksum_tree: tree dir not found: ${tree}"
    return 1
  fi
  if [[ ! -f "${order_file}" ]]; then
    log_error "checksum_tree: order file not found: ${order_file}"
    return 1
  fi

  resource_checksum_length || return 1
  local length="${RESOURCE_CHECKSUM_LENGTH}"

  # --- 1. Inventory: one scan of the whole tree ---
  # Lines: file<TAB>kind<TAB>name. Secret docs inside *.template.yaml are
  # excluded when secrets processing is disabled (empty secrets dir - the
  # RP case, where those belong to the children's own deploys). Only an
  # exact '-<own lowercased kind>-checksum' marker opts in: any other
  # name ending '-checksum' could be a legit customer resource name, so
  # it is warned and left alone.
  local inventory=""
  local warn_lines=""
  local found=0
  local file doc_line doc_kind doc_name own_marker
  while IFS= read -r -d '' file; do
    while IFS= read -r doc_line; do
      doc_kind="${doc_line%%	*}"
      doc_name="${doc_line#*	}"
      [[ -z "${doc_name}" || "${doc_name}" == "null" ]] && continue
      [[ "${doc_name}" != *-checksum ]] && continue
      if [[ "${file}" == *.template.yaml && "${doc_kind}" == "Secret" && -z "${secrets_dir}" ]]; then
        continue
      fi
      own_marker="-$(printf '%s' "${doc_kind}" | tr '[:upper:]' '[:lower:]')-checksum"
      if [[ "${doc_name}" != *"${own_marker}" ]]; then
        warn_lines="${warn_lines}${file#"${tree}"/}: ${doc_kind} '${doc_name}' ends '-checksum' but not '${own_marker}'; assuming legit resource name - not processed
"
        continue
      fi
      inventory="${inventory}${file}	${doc_kind}	${doc_name}
"
      found=$((found + 1))
    done < <(yq ea '(.kind // "") + "	" + (.metadata.name // "")' "${file}" 2>/dev/null || true)
  done < <(resource_checksum_find_yaml "${tree}")

  # All paths logged from here on are tree-relative: the tree base is
  # stated in the step header and repeating it per line is noise.
  log "Found ${found} resources with metadata.name -kind-checksum suffix marker:"
  local entry
  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    file="${entry%%	*}"
    log "  ${file#"${tree}"/}: ${entry##*	}"
  done <<< "${inventory}"
  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    log_warning "${entry}"
  done <<< "${warn_lines}"
  log ""

  [[ "${found}" -eq 0 ]] && return 0

  local processed_keys=""
  local kind_lc marker old_name new_name hash tmp_doc doc_index doc_count

  # --- 2. Secret templates first (tier-1 leaves; consumer hashes must be
  # computed over final Secret names) ---
  if [[ -n "${secrets_dir}" ]]; then
    while IFS= read -r entry; do
      [[ -z "${entry}" ]] && continue
      file="${entry%%	*}"
      doc_kind=$(printf '%s' "${entry}" | cut -f2)
      old_name="${entry##*	}"
      [[ "${file}" != *.template.yaml || "${doc_kind}" != "Secret" ]] && continue

      checksum_secret_input_set "${tree}" "${file}" "${secrets_dir}" "${length}" || return 1
      processed_keys="${processed_keys}${file}	${old_name}
"
      new_name="${old_name%-secret-checksum}-${SECRET_HASH}"
      yq -i "(select(.kind == \"Secret\" and .metadata.name == \"${old_name}\") | .metadata.name) = \"${new_name}\"" "${file}"
      log "Processing ${file#"${tree}"/}:"
      log "  ${old_name} -> ${new_name} (input set: template + ${SECRET_TOKEN_COUNT} token value(s))"
      RESOURCE_CHECKSUM_TOTAL_RESOURCES=$((RESOURCE_CHECKSUM_TOTAL_RESOURCES + 1))
      rewrite_name_refs "${tree}" "${old_name}" "${new_name}" || return 1
      log ""
    done <<< "${inventory}"
  fi

  # --- 3. Remaining kinds in order-file sequence ---
  local kind
  while IFS= read -r kind; do
    kind="${kind%%#*}"
    kind="${kind## }"
    kind="${kind%% }"
    [[ -z "${kind}" ]] && continue
    kind_lc=$(printf '%s' "${kind}" | tr '[:upper:]' '[:lower:]')
    marker="-${kind_lc}-checksum"

    while IFS= read -r entry; do
      [[ -z "${entry}" ]] && continue
      file="${entry%%	*}"
      doc_kind=$(printf '%s' "${entry}" | cut -f2)
      old_name="${entry##*	}"
      [[ "${doc_kind}" != "${kind}" ]] && continue
      # Secret templates were handled (or deliberately excluded) above.
      [[ "${file}" == *.template.yaml && "${doc_kind}" == "Secret" ]] && continue
      # Already processed (defensive; inventory entries are unique).
      case "${processed_keys}" in *"${file}	${old_name}"*) continue ;; esac
      # Inventory admitted only exact own-kind markers, so old_name is
      # guaranteed to end "${marker}" here.

      # Locate the document by kind+name at processing time (indices are
      # stable across textual ref rewrites), hash it LIVE - earlier
      # resources' rewrites may have changed this very document and this
      # hash must be taken over that updated content.
      doc_count=$(yq ea '[.] | length' "${file}")
      doc_index=0
      while [[ "${doc_index}" -lt "${doc_count}" ]]; do
        doc_kind=$(DOC_INDEX="${doc_index}" yq ea 'select(document_index == (env(DOC_INDEX) | tonumber)) | .kind // ""' "${file}")
        doc_name=$(DOC_INDEX="${doc_index}" yq ea 'select(document_index == (env(DOC_INDEX) | tonumber)) | .metadata.name // ""' "${file}")
        if [[ "${doc_kind}" == "${kind}" && "${doc_name}" == "${old_name}" ]]; then
          break
        fi
        doc_index=$((doc_index + 1))
      done
      if [[ "${doc_index}" -ge "${doc_count}" ]]; then
        log_error "checksum_tree: inventoried ${kind} '${old_name}' no longer found in ${file#"${tree}"/}"
        return 1
      fi

      tmp_doc=$(mktemp)
      yq "select(di == ${doc_index})" "${file}" > "${tmp_doc}"
      hash=$(hash_base32 "${tmp_doc}" "${length}")
      rm -f "${tmp_doc}"
      new_name="${old_name%"${marker}"}-${hash}"

      yq -i "(select(di == ${doc_index}) | .metadata.name) = \"${new_name}\"" "${file}"
      log "Processing ${file#"${tree}"/}:"
      log "  ${old_name} -> ${new_name}"
      RESOURCE_CHECKSUM_TOTAL_RESOURCES=$((RESOURCE_CHECKSUM_TOTAL_RESOURCES + 1))
      processed_keys="${processed_keys}${file}	${old_name}
"
      rewrite_name_refs "${tree}" "${old_name}" "${new_name}" || return 1
      log ""
    done <<< "${inventory}"
  done < "${order_file}"

  # --- 4. Nothing marked may slip through unprocessed ---
  local leftovers=0
  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    file="${entry%%	*}"
    doc_kind=$(printf '%s' "${entry}" | cut -f2)
    old_name="${entry##*	}"
    case "${processed_keys}" in *"${file}	${old_name}"*) continue ;; esac
    log_error "  ${file#"${tree}"/}: ${doc_kind} '${old_name}' is checksum-marked but was never processed"
    log_error "  (kind missing from ${order_file}, or a marked Secret outside *.template.yaml)"
    leftovers=$((leftovers + 1))
  done <<< "${inventory}"
  if [[ "${leftovers}" -gt 0 ]]; then
    log_error "${leftovers} marked resource(s) left unprocessed."
    return 1
  fi
}
