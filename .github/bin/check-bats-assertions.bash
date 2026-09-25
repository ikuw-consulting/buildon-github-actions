#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# check-bats-assertions.bash - Find BATS assertions that can never fail a test
#
# BATS fails a test when a command in its body fails under set -e, or when
# the body's last command fails. Two assertion shapes are exempt from set -e,
# so anywhere but last they pass silently whatever they test:
#
#   1. A negated command: '! grep -q x file'. set -e ignores the status of any
#      command prefixed with '!', in every bash version.
#      Fix: [ "$(grep -c x file)" -eq 0 ]   or   run ! grep -q x file
#
#   2. A bare '[[ ... ]]'. Bash 3.2 (macOS) does not trigger set -e when a
#      [[ ]] compound command fails.
#      Fix: [[ ... ]] || return 1
#
# Each @test body and each function body is checked. Its last command is
# exempt: that one sets the result. Backslash continuations are joined and
# heredoc contents skipped.
#
# Usage: check-bats-assertions.bash [<file>...]
#   Defaults to src/test/*.bats and src/test/helpers.bash, from the repo root.
#
# Exits 1 and prints file:line: reason for every dead assertion found.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  files=("${PROJECT_ROOT}"/src/test/*.bats "${PROJECT_ROOT}/src/test/helpers.bash")
fi

findings=$(awk '
  function flush(   i, last) {
    last = 0
    for (i = n; i > 0; i--) {
      if (text[i] !~ /^[[:space:]]*(#.*)?$/) { last = i; break }
    }
    for (i = 1; i <= n; i++) {
      if (i == last) continue
      if (text[i] ~ /^[[:space:]]+![[:space:]]/) {
        print FILENAME ":" line[i] ": negated command is ignored by set -e; use [ \"$(grep -c ...)\" -eq 0 ] or run !"
      } else if (text[i] ~ /^[[:space:]]+\[\[/ && text[i] ~ /\]\][[:space:]]*$/) {
        print FILENAME ":" line[i] ": bare [[ ]] is ignored by set -e on bash 3.2; append || return 1"
      }
    }
    n = 0
    inbody = 0
  }
  FNR == 1 { if (inbody) flush(); inbody = 0; heredoc = ""; cont = 0 }
  heredoc != "" { if ($0 ~ "^[[:space:]]*" heredoc "[[:space:]]*$") heredoc = ""; next }
  /^(@test .*|[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*)\{[[:space:]]*$/ { inbody = 1; n = 0; cont = 0; next }
  inbody && /^\}/ { flush(); next }
  inbody {
    if (cont) {
      text[n] = text[n] " " $0
    } else {
      n++
      text[n] = $0
      line[n] = FNR
    }
    cont = ($0 ~ /\\$/)
    # Heredoc start, ignoring <<< herestrings.
    stripped = $0
    gsub(/<<</, "", stripped)
    if (match(stripped, /<<-?[[:space:]]*["'\'']?[A-Za-z_][A-Za-z0-9_]*["'\'']?/)) {
      marker = substr(stripped, RSTART, RLENGTH)
      gsub(/<<-?[[:space:]]*|["'\'']/, "", marker)
      heredoc = marker
    }
  }
  END { if (inbody) flush() }
' "${files[@]}")

if [[ -n "${findings}" ]]; then
  count=$(printf '%s\n' "${findings}" | wc -l | tr -d ' ')
  printf '%s\n' "${findings}" | sed "s|^${PROJECT_ROOT}/||" >&2
  echo "ERROR: ${count} BATS assertion(s) can never fail their test" >&2
  exit 1
fi

echo "No dead BATS assertions in ${#files[@]} file(s)"
