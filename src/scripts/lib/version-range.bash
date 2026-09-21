#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# version-range.bash - Maven-style version range resolution
#
# Reusable library for resolving version ranges against a set of available versions.
# Sourced by artifact provider plugins that need version range support.
#
# Supports Maven 2/3 range syntax:
#   [1.0,2.0)  - >= 1.0, < 2.0
#   [1.0,2.0]  - >= 1.0, <= 2.0
#   (1.0,2.0)  - > 1.0, < 2.0
#   (1.0,2.0]  - > 1.0, <= 2.0
#   [1.0,)     - >= 1.0 (no upper bound)
#   (1.0,)     - > 1.0 (no upper bound)
#   (,2.0]     - <= 2.0 (no lower bound)
#   (,2.0)     - < 2.0 (no lower bound)
#   1.0        - exact match
#
# Versions are compared numerically part by part (1.10 > 1.9).
# Missing parts are treated as 0 (1.2 == 1.2.0).
#
# Ranges that cannot be satisfied by any version are rejected up front, before
# candidates are considered: a lower bound above the upper bound ([3.2,1.2]),
# or equal bounds with either bracket exclusive ([2.0,2.0)). Equal bounds with
# both brackets inclusive ([2.0,2.0]) are fine and pin that one version.

# Compare two version strings numerically.
# Handles suffixed versions (e.g. 1.1-PRERELEASE): suffix is stripped for
# numeric comparison, then unsuffixed > suffixed at the same numeric version.
# Returns via exit code: 0 = equal, 1 = v1 > v2, 2 = v1 < v2
version_compare() {
  local v1="${1}" v2="${2}"

  if [[ "${v1}" == "${v2}" ]]; then
    return 0
  fi

  # Split off suffix (everything after first hyphen)
  local v1_numeric="${v1%%-*}" v1_suffix=""
  local v2_numeric="${v2%%-*}" v2_suffix=""
  [[ "${v1}" == *-* ]] && v1_suffix="${v1#*-}"
  [[ "${v2}" == *-* ]] && v2_suffix="${v2#*-}"

  local -a parts1 parts2
  IFS='.' read -ra parts1 <<< "${v1_numeric}"
  IFS='.' read -ra parts2 <<< "${v2_numeric}"

  local max=${#parts1[@]}
  if [[ ${#parts2[@]} -gt ${max} ]]; then
    max=${#parts2[@]}
  fi

  local i
  for ((i = 0; i < max; i++)); do
    local p1=${parts1[i]:-0}
    local p2=${parts2[i]:-0}
    if ((p1 > p2)); then
      return 1
    elif ((p1 < p2)); then
      return 2
    fi
  done

  # Numeric parts equal - unsuffixed wins over suffixed
  if [[ -z "${v1_suffix}" && -n "${v2_suffix}" ]]; then
    return 1
  elif [[ -n "${v1_suffix}" && -z "${v2_suffix}" ]]; then
    return 2
  fi

  # Both suffixed: shorter/alphabetically earlier suffix wins
  if [[ -n "${v1_suffix}" && -n "${v2_suffix}" ]]; then
    if [[ "${v1_suffix}" < "${v2_suffix}" ]]; then
      return 1
    elif [[ "${v1_suffix}" > "${v2_suffix}" ]]; then
      return 2
    fi
  fi

  return 0
}

# Check if v1 > v2
version_gt() {
  local rc=0
  version_compare "${1}" "${2}" || rc=$?
  [[ ${rc} -eq 1 ]]
}

# Check if v1 >= v2
version_ge() {
  local rc=0
  version_compare "${1}" "${2}" || rc=$?
  [[ ${rc} -eq 1 || ${rc} -eq 0 ]]
}

# Check if v1 < v2
version_lt() {
  local rc=0
  version_compare "${1}" "${2}" || rc=$?
  [[ ${rc} -eq 2 ]]
}

# Check if v1 <= v2
version_le() {
  local rc=0
  version_compare "${1}" "${2}" || rc=$?
  [[ ${rc} -eq 2 || ${rc} -eq 0 ]]
}

# Filter a newline-delimited version list to only pure numeric versions
# (no hyphens). Removes suffixed versions like 1.1-PRERELEASE, 1.1-linux-amd64.
# Usage: version_filter_release "<newline-delimited-versions>"
# stdout: filtered list (newline-delimited)
version_filter_release() {
  local versions="${1}"
  local version
  while IFS= read -r version; do
    [[ -z "${version}" ]] && continue
    [[ "${version}" != *-* ]] && echo "${version}"
  done <<< "${versions}"
  return 0
}

# Filter a newline-delimited tag list to those ending exactly in `-<variant>`,
# and strip that suffix. Tags with anything after `-<variant>` (e.g. a
# platform suffix `-<variant>-linux-amd64`) are dropped: those are per-arch
# children of the multi-arch index, not the index itself.
#
# Usage: version_filter_variant <variant> "<newline-delimited-tags>"
# stdout: canonical versions (newline-delimited)
version_filter_variant() {
  local variant="${1}"
  local tags="${2}"
  local suffix="-${variant}"
  local tag
  while IFS= read -r tag; do
    [[ -z "${tag}" ]] && continue
    [[ "${tag}" == *"${suffix}" ]] && echo "${tag%"${suffix}"}"
  done <<< "${tags}"
  return 0
}

# Unwrap a degenerate single-value bracket range "[N]" to "N". Other forms
# pass through unchanged. Used so that "[1.0]" (a range with equal bounds)
# can be treated as an exact version, skipping unnecessary resolution.
version_unwrap_exact() {
  local version="${1}"
  if [[ "${version}" == "["*"]" && "${version}" != *","* ]]; then
    version="${version#[}"
    version="${version%]}"
  fi
  printf '%s' "${version}"
}

# Check if a version is an exact version (no range syntax). Also returns true
# for degenerate single-value bracketed form "[N]", which is equivalent to "N".
version_is_exact() {
  local version
  version=$(version_unwrap_exact "${1}")
  [[ "${version}" != *"["* && "${version}" != *"("* && "${version}" != *"]"* && "${version}" != *")"* && "${version}" != *","* ]]
}

# Resolve a version range against a newline-delimited list of available versions.
# For exact versions, validates the version exists in the list.
# For ranges, returns the highest version satisfying the range.
#
# Usage: version_resolve_range "<range>" "<newline-delimited-versions>"
# Sets: VERSION_RESOLVE_RESULT - resolved version
# exit 1: no match found
version_resolve_range() {
  local range="${1}"
  local available="${2}"

  if [[ -z "${available}" ]]; then
    log_error "No available versions provided"
    return 1
  fi

  # Exact version: trust it, no existence check. Existence verification is a
  # separate concern handled by callers via artifact-exists. Also handles the
  # degenerate "[N]" form by unwrapping to "N".
  if version_is_exact "${range}"; then
    # shellcheck disable=SC2034  # Read by callers
    VERSION_RESOLVE_RESULT=$(version_unwrap_exact "${range}")
    return 0
  fi

  # Parse range syntax
  local lower_bracket lower_version upper_version upper_bracket

  lower_bracket="${range:0:1}"
  upper_bracket="${range: -1}"

  # Strip brackets
  local inner="${range:1:${#range}-2}"

  # Split on comma
  lower_version="${inner%%,*}"
  upper_version="${inner#*,}"

  # Trim whitespace
  lower_version="${lower_version// /}"
  upper_version="${upper_version// /}"

  # Validate bracket characters
  if [[ "${lower_bracket}" != "[" && "${lower_bracket}" != "(" ]]; then
    log_error "Invalid range syntax: must start with [ or ( : ${range}"
    return 1
  fi
  if [[ "${upper_bracket}" != "]" && "${upper_bracket}" != ")" ]]; then
    log_error "Invalid range syntax: must end with ] or ) : ${range}"
    return 1
  fi

  # A range whose bounds cannot both be satisfied matches nothing, whatever is
  # published. Rejecting it here names the range as the fault; falling through
  # to the scan reports "no version matching" instead, which reads as "not
  # published yet" and sends the reader to the registry hunting a version that
  # was never the problem. The schema cannot catch this: patterns are regexes
  # and a regex cannot compare one captured number against another.
  if [[ -n "${lower_version}" && -n "${upper_version}" ]]; then
    local bound_order=0
    version_compare "${lower_version}" "${upper_version}" || bound_order=$?
    if [[ ${bound_order} -eq 1 ]]; then
      log_error "Impossible range ${range}: lower bound ${lower_version} is above upper bound ${upper_version}"
      return 1
    fi
    # Equal bounds are satisfiable only when both brackets are inclusive.
    if [[ ${bound_order} -eq 0 ]] \
       && { [[ "${lower_bracket}" == "(" ]] || [[ "${upper_bracket}" == ")" ]]; }; then
      log_error "Empty range ${range}: bounds are equal but excluded by the brackets - use [${lower_version}] to pin that version"
      return 1
    fi
  fi

  # Find the highest matching version
  local best=""
  local version
  while IFS= read -r version; do
    [[ -z "${version}" ]] && continue

    # Check lower bound
    if [[ -n "${lower_version}" ]]; then
      if [[ "${lower_bracket}" == "[" ]]; then
        version_ge "${version}" "${lower_version}" || continue
      else
        version_gt "${version}" "${lower_version}" || continue
      fi
    fi

    # Check upper bound
    if [[ -n "${upper_version}" ]]; then
      if [[ "${upper_bracket}" == "]" ]]; then
        version_le "${version}" "${upper_version}" || continue
      else
        version_lt "${version}" "${upper_version}" || continue
      fi
    fi

    # Track highest match
    if [[ -z "${best}" ]]; then
      best="${version}"
    elif version_gt "${version}" "${best}"; then
      best="${version}"
    fi
  done <<< "${available}"

  if [[ -z "${best}" ]]; then
    log_error "No version matching range ${range} found in available versions"
    return 1
  fi

  # shellcheck disable=SC2034  # Read by callers
  VERSION_RESOLVE_RESULT="${best}"
}
