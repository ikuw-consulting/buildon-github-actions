#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# check-token-patterns.bash - Keep token matching and stripping in one place
#
# How a token looks is decided by the configured delimiter and name styles, and
# src/scripts/lib/token-format.bash is the one place that turns those styles
# into patterns: unresolved_token_regex, any_token_regex and
# strip_token_delimiters. A hand-built copy elsewhere silently assumes one style
# (usually shell + a fixed name charset) and drifts from the validators, so
# tokens the build accepts become invisible to whatever scans for them.
#
# Flags, outside token-format.bash:
#   1. A hand-built token regex: an escaped token opener followed by a character
#      class, e.g. '\$\{[A-Za-z_]...', '\{\{ [A-Za-z]...', '%\{[A-Za-z]...'.
#   2. A hand-rolled delimiter strip: a sed substitution anchored on a token
#      opener, e.g. sed 's/^\$\{|\}$//g' or sed 's/^{{ \(.*\) }}$/\1/'.
#
# The token-substitution-providers are exempt: they match one known name
# literally, which is the substitution itself rather than a scan for tokens.
#
# Usage: check-token-patterns.bash [<file>...]
#   Defaults to every file under src/scripts, from the repo root.
#
# Exits 1 and prints file:line: text for every hit.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Escaping varies with quoting ('\$\{[' vs "\\$\\{["), hence \\+ throughout.
hand_built_regex='\\+\$\\+\{(\\+\{)? *\[|\\+\{\\+\{ *(\\+\.Values\\+\.|\\+\$)?\[|%\\+\{\['
hand_rolled_strip='s[/|]\^(\\+\$\\?\{|\{\{|<[%#]=|%\{|\\\\+\(|\\+\$\\+\()'

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r -d '' file; do
    case "${file}" in
      */lib/token-format.bash) continue ;;
      */plugins/token-substitution-providers/*) continue ;;
      *.md) continue ;;
    esac
    files+=("${file}")
  done < <(find "${PROJECT_ROOT}/src/scripts" -type f -print0 | LC_ALL=C sort -z)
fi

findings=$(grep -nHE "${hand_built_regex}|${hand_rolled_strip}" "${files[@]}" || true)

if [[ -n "${findings}" ]]; then
  count=$(printf '%s\n' "${findings}" | wc -l | tr -d ' ')
  printf '%s\n' "${findings}" | sed "s|^${PROJECT_ROOT}/||" >&2
  echo "ERROR: ${count} hand-built token pattern(s) outside src/scripts/lib/token-format.bash" >&2
  echo "Use unresolved_token_regex / any_token_regex / strip_token_delimiters instead." >&2
  exit 1
fi

echo "No hand-built token patterns in ${#files[@]} file(s)"
