#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# token-usage.bash - Token usage accounting + unreferenced value check.
#
# One scan of the PRE-substitution manifest trees serving two outputs for
# the env/RP aggregate steps:
#
#   1. token-usage.yaml: which provided tokens the manifest set actually
#      references, attributed to the tier that provided them. Attribution
#      follows the stacking order (later wins on collision): child
#      contract-zip defaults < project config dir < built-ins, so a token
#      supplied by two tiers is credited to the winner. Referenced tokens
#      provided only by an encrypted secret value are deploy-time secrets
#      and are counted downstream (consumption report), not here.
#
#   2. The unreferenced list: config / secret VALUE files whose token is
#      never referenced anywhere in the manifest set (schema field
#      failOnUnreferencedConfigOrSecrets governs fail-vs-warn at the
#      caller). Child defaults are exempt by design - an unused default
#      is a permitted fallback.
#
# Referenced tokens are collected from BOTH pre-substitution trees: the
# workload aggregate (normalised) AND the deploy-manifests tree, whose
# tokens resolve at deploy time but consume the same config/secrets
# pools. Default Kaptain shell-style ${Token} references; refine the
# regex if other delimiter/name styles need this code path.
#
# Usage:
#   token_usage_report <scan-dir> <scan-dir-2-or-empty> \
#     <defaults-merged-dir-or-empty> <tokens-tmp-dir> <config-dir> \
#     <secrets-dir-or-empty> <out-yaml>
#
# Writes <out-yaml> (counts + per-tier name lists, LC_ALL=C sorted) and
# sets:
#   TOKEN_USAGE_UNREFERENCED        - newline list of "config <Name>" /
#                                     "secret <value-file-name>" entries
#   TOKEN_USAGE_UNREFERENCED_COUNT  - how many of those
#
# Required tools: grep, sed, find.

# Emit one YAML list: 'name: []' when empty, else one '  - item' per line.
token_usage_emit_list() {
  local name="$1"
  local items="$2"
  if [[ -z "${items}" ]]; then
    echo "${name}: []"
    return 0
  fi
  echo "${name}:"
  local item
  while IFS= read -r item; do
    [[ -z "${item}" ]] && continue
    echo "  - ${item}"
  done <<< "${items}"
}

token_usage_report() {
  local scan_dir="$1"
  local scan_dir2="$2"
  local defaults_dir="$3"
  local tokens_tmp_dir="$4"
  local config_dir="$5"
  local secrets_dir="$6"
  local out_yaml="$7"
  if [[ -z "${scan_dir}" || -z "${tokens_tmp_dir}" || -z "${config_dir}" || -z "${out_yaml}" ]]; then
    log_error "token_usage_report: usage: <scan-dir> <scan-dir-2-or-empty> <defaults-merged-dir-or-empty> <tokens-tmp-dir> <config-dir> <secrets-dir-or-empty> <out-yaml>"
    return 1
  fi
  if [[ ! -d "${scan_dir}" ]]; then
    log_error "token_usage_report: scan dir not found: ${scan_dir}"
    return 1
  fi

  # Every distinct token referenced across both trees. LC_ALL=C: the
  # lists land in a published report and must be stable across platforms.
  local referenced
  referenced=$(
    {
      grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${scan_dir}" 2>/dev/null || true
      if [[ -n "${scan_dir2}" && -d "${scan_dir2}" ]]; then
        grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${scan_dir2}" 2>/dev/null || true
      fi
    } | sed -E 's/^\$\{|\}$//g' | LC_ALL=C sort -u
  )

  # Attribute each referenced token to the tier that provided it.
  local from_config=""
  local from_defaults=""
  local from_builtins=""
  local tok
  while IFS= read -r tok; do
    [[ -z "${tok}" ]] && continue
    if [[ -f "${tokens_tmp_dir}/${tok}" ]]; then
      # The config + built-ins layer wins over child defaults. Within
      # it, a token backed by a file in the project config dir is user
      # config; anything else the layer emitted is a built-in.
      if [[ -f "${config_dir}/${tok}" ]]; then
        from_config="${from_config}${tok}
"
      else
        from_builtins="${from_builtins}${tok}
"
      fi
    elif [[ -n "${defaults_dir}" && -f "${defaults_dir}/${tok}" ]]; then
      from_defaults="${from_defaults}${tok}
"
    fi
    # Anything else is either a deploy-time secret token (counted by the
    # consumption report) or unprovided (the substitution gate's job).
  done <<< "${referenced}"

  local config_count defaults_count builtins_count
  config_count=$(printf '%s' "${from_config}" | grep -c . || true)
  defaults_count=$(printf '%s' "${from_defaults}" | grep -c . || true)
  builtins_count=$(printf '%s' "${from_builtins}" | grep -c . || true)

  mkdir -p "$(dirname "${out_yaml}")"
  {
    echo "usedCount: $((config_count + defaults_count + builtins_count))"
    echo "fromConfigCount: ${config_count}"
    echo "fromChildDefaultsCount: ${defaults_count}"
    echo "fromBuiltInsCount: ${builtins_count}"
    token_usage_emit_list "fromConfig" "${from_config}"
    token_usage_emit_list "fromChildDefaults" "${from_defaults}"
    token_usage_emit_list "fromBuiltIns" "${from_builtins}"
  } > "${out_yaml}"

  # --- Unreferenced value files (config + secrets; defaults exempt) ---
  TOKEN_USAGE_UNREFERENCED=""
  TOKEN_USAGE_UNREFERENCED_COUNT=0
  local file base
  if [[ -d "${config_dir}" ]]; then
    while IFS= read -r -d '' file; do
      base=$(basename "${file}")
      [[ "${base}" == .* ]] && continue
      if ! grep -qxF "${base}" <<< "${referenced}"; then
        TOKEN_USAGE_UNREFERENCED="${TOKEN_USAGE_UNREFERENCED}config ${base}
"
        TOKEN_USAGE_UNREFERENCED_COUNT=$((TOKEN_USAGE_UNREFERENCED_COUNT + 1))
      fi
    done < <(find "${config_dir}" -type f -print0 | LC_ALL=C sort -z)
  fi
  if [[ -n "${secrets_dir}" && -d "${secrets_dir}" ]]; then
    while IFS= read -r -d '' file; do
      base=$(basename "${file}")
      [[ "${base}" == .* ]] && continue
      # Encrypted values are <Token>.<type> (type may itself contain
      # dots, e.g. sha256.aes256.10k); token names never do.
      tok="${base%%.*}"
      if ! grep -qxF "${tok}" <<< "${referenced}"; then
        TOKEN_USAGE_UNREFERENCED="${TOKEN_USAGE_UNREFERENCED}secret ${base}
"
        TOKEN_USAGE_UNREFERENCED_COUNT=$((TOKEN_USAGE_UNREFERENCED_COUNT + 1))
      fi
    done < <(find "${secrets_dir}" -type f -print0 | LC_ALL=C sort -z)
  fi
}
