#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# token-markers.bash - In-file markers that exempt selected tokens from a pass
#
# The keyword is a parameter, so a marker family is a keyword plus whatever the
# caller does with the records. The grammar, the validation and the diagnostics
# are the same whichever family is asking, which is what keeps two families
# from quietly disagreeing about what parses.
#
# Current caller: DoNotConvert* in src/scripts/util/convert-tokens-in-tree,
# exempting tokens from child token-scheme conversion.
#
# Markers live in comments - usually YAML comments, but inside an embedded
# block scalar the comment syntax of the embedded content is fine too; the
# marker only has to be findable without corrupting the payload. Scope is the
# file the marker sits in and nothing else, which is what makes the caller's
# pre-scan viable.
#
#   <Keyword>            on the line itself, covers that line
#   <Keyword>Above       on the line BELOW the target, covers the line above
#   <Keyword>Below       on the line ABOVE the target, covers the line below
#   <Keyword>Lines: ...  anywhere in the file, covers the listed lines
#
# The three positional forms take an optional ': ${A},${B}' suffix. Bare means
# every token on the target line; with a specifier only the named tokens are
# covered and everything else on the line is treated normally. The Lines form
# takes a comma-separated list whose entries are either a bare line number or
# 'line:${Token}', and may appear at most once per file.
#
# A marker starts a word: at the start of the line, or after whitespace. A line
# that merely contains the keyword - a token genuinely named ${DoNotConvertMe},
# say - is not a marker line.
#
# Stale markers are reported: a line number that does not exist, a named token
# that is not present on the line it points at, a marker pointing at a line
# with no token-shaped content, or an Above/Below marker with no line to point
# at. Token-shaped content is matched against the union of every supported
# delimiter style, not the configured one, because a file may carry a token in
# a foreign format on purpose. Callers decide whether that is fatal.
#
# Functions:
#   token_markers_files    - list files under a tree carrying the keyword
#   token_markers_collect  - parse and validate one file's markers into a TSV
#
# Requires lib/token-format.bash (any_token_regex) and lib/log.bash.

# Problems found since the last token_markers_reset. Callers read this to
# decide whether to fail, and every problem is logged as it is found so a file
# with several stale markers reports all of them in one pass.
TOKEN_MARKERS_ERROR_COUNT=0

# Usage: token_markers_reset
token_markers_reset() {
  TOKEN_MARKERS_ERROR_COUNT=0
}

# List every file under a tree that carries the keyword, one per line. Empty
# output - the overwhelmingly common case - means the caller can skip all of
# the line-aware machinery and behave exactly as it did before markers existed.
# Usage: token_markers_files <keyword> <directory>
token_markers_files() {
  local keyword="${1}" directory="${2}"
  grep -rl "${keyword}" "${directory}" 2>/dev/null || true
}

# Internal: strip leading and trailing whitespace. Bash 3.2 has none of the
# newer parameter expansions, and marker specifiers are few enough that
# clarity wins.
token_markers_trim() {
  local s="${1}"
  while [[ "${s}" == [[:space:]]* ]]; do s="${s#?}"; done
  while [[ "${s}" == *[[:space:]] ]]; do s="${s%?}"; done
  printf '%s' "${s}"
}

# Report a marker problem and count it. Callers use this for family-specific
# problems the parser cannot know about, so everything lands in one count.
token_markers_error() {
  TOKEN_MARKERS_ERROR_COUNT=$((TOKEN_MARKERS_ERROR_COUNT + 1))
  log_error "${1}"
}

# Internal: validate one coverage target and record it. Reads the file under
# inspection from TOKEN_MARKERS_LINES / TOKEN_MARKERS_TOTAL - bash 3.2 cannot
# pass arrays.
#
# The optional sixth argument narrows what the content checks look at. A
# same-line marker is its own target, so its specifier would always be "present
# on the line" - it is written there. The caller passes the text preceding the
# keyword so a stale specifier is still caught.
#
# Usage: token_markers_record <keyword> <relative-path> <marker-line> <target-line> <token-or-*> [search-text]
token_markers_record() {
  local keyword="${1}" relative="${2}" marker_line="${3}" target_line="${4}" token="${5}"

  if [[ "${target_line}" -lt 1 || "${target_line}" -gt "${TOKEN_MARKERS_TOTAL}" ]]; then
    token_markers_error "${relative}:${marker_line}: ${keyword} marker points at line ${target_line}, which does not exist (the file has ${TOKEN_MARKERS_TOTAL} lines)"
    return 0
  fi

  local target_content="${TOKEN_MARKERS_LINES[${target_line}]}"
  local where="line ${target_line}"
  if [[ $# -ge 6 ]]; then
    target_content="${6}"
    where="line ${target_line} outside the marker"
  fi

  if ! printf '%s\n' "${target_content}" | grep -qE "${TOKEN_MARKERS_SHAPE_REGEX}"; then
    token_markers_error "${relative}:${marker_line}: ${keyword} marker points at ${where}, which holds no token-shaped content"
    return 0
  fi

  if [[ "${token}" != "*" ]]; then
    if ! printf '%s\n' "${token}" | grep -qE "^(${TOKEN_MARKERS_SHAPE_REGEX})$"; then
      token_markers_error "${relative}:${marker_line}: ${keyword} specifier '${token}' is not a token reference in any supported delimiter style"
      return 0
    fi
    case "${target_content}" in
      *"${token}"*) ;;
      *)
        token_markers_error "${relative}:${marker_line}: ${keyword} specifier '${token}' is not present on ${where}"
        return 0
        ;;
    esac
  fi

  printf '%s\t%s\t%s\n' "${relative}" "${target_line}" "${token}" >> "${TOKEN_MARKERS_OUTPUT}"
}

# Parse every marker in one file, validating as it goes, appending
# '<relative>\t<line>\t<token-or-*>' records to the output TSV. A '*' record
# covers every token on that line.
#
# Usage: token_markers_collect <keyword> <path> <relative-path> <output-tsv>
token_markers_collect() {
  local keyword="${1}" file="${2}" relative="${3}"
  TOKEN_MARKERS_OUTPUT="${4}"
  TOKEN_MARKERS_SHAPE_REGEX=$(any_token_regex)

  TOKEN_MARKERS_LINES=()
  TOKEN_MARKERS_TOTAL=0
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    TOKEN_MARKERS_TOTAL=$((TOKEN_MARKERS_TOTAL + 1))
    TOKEN_MARKERS_LINES[TOKEN_MARKERS_TOTAL]="${line}"
  done < "${file}"

  local lines_form_line=0
  local i content found before remainder has_spec spec rest entry target token
  local scan consumed head trailing prefix marker_count
  local -a marker_search
  for (( i = 1; i <= TOKEN_MARKERS_TOTAL; i++ )); do
    content="${TOKEN_MARKERS_LINES[${i}]}"
    case "${content}" in
      *"${keyword}"*) ;;
      *) continue ;;
    esac

    # A marker starts a word: at the start of the line, or after whitespace.
    # Content that merely contains the keyword is not a marker.
    scan="${content}"
    consumed=""
    marker_count=0
    found=""
    before=""
    remainder=""
    while [[ "${scan}" == *"${keyword}"* ]]; do
      head="${scan%%"${keyword}"*}"
      trailing="${scan#*"${keyword}"}"
      prefix="${consumed}${head}"
      if [[ -z "${prefix}" || "${prefix}" == *[[:space:]] ]]; then
        marker_count=$((marker_count + 1))
        if [[ "${marker_count}" -eq 1 ]]; then
          before="${prefix}"
          # Longest form first: every other form extends the bare keyword.
          case "${trailing}" in
            Lines*) found="${keyword}Lines"; remainder="${trailing#Lines}" ;;
            Above*) found="${keyword}Above"; remainder="${trailing#Above}" ;;
            Below*) found="${keyword}Below"; remainder="${trailing#Below}" ;;
            *)      found="${keyword}";      remainder="${trailing}" ;;
          esac
        fi
      fi
      consumed="${prefix}${keyword}"
      scan="${trailing}"
    done

    if [[ "${marker_count}" -eq 0 ]]; then
      continue
    fi
    if [[ "${marker_count}" -gt 1 ]]; then
      token_markers_error "${relative}:${i}: more than one ${keyword} marker on a line; use one per line, or the ${keyword}Lines form"
      continue
    fi

    # The keyword ends the word: end of line or whitespace is a bare marker
    # (any trailing prose is ignored), ':' introduces the specifier list.
    has_spec=false
    spec=""
    if [[ -z "${remainder}" ]]; then
      :
    elif [[ "${remainder}" == :* ]]; then
      has_spec=true
      spec=$(token_markers_trim "${remainder#:}")
    elif [[ "${remainder}" == [[:space:]]* ]]; then
      :
    else
      token_markers_error "${relative}:${i}: unrecognised ${keyword} marker: ${content}"
      continue
    fi

    # Above/Below/Lines markers annotate a DIFFERENT line, so token references
    # in the marker text itself would be treated as payload by the pass that
    # follows. Same-line markers need no such treatment: their specifier names
    # tokens on the very line being covered, so the marker text is covered by
    # the coverage it declares.
    if [[ "${found}" != "${keyword}" ]]; then
      printf '%s\t%s\t%s\n' "${relative}" "${i}" "*" >> "${TOKEN_MARKERS_OUTPUT}"
    fi

    if [[ "${found}" == "${keyword}Lines" ]]; then
      if [[ "${lines_form_line}" -ne 0 ]]; then
        token_markers_error "${relative}:${i}: second ${keyword}Lines marker in this file (the first is on line ${lines_form_line}); at most one is allowed"
        continue
      fi
      lines_form_line="${i}"
      if ! ${has_spec} || [[ -z "${spec}" ]]; then
        token_markers_error "${relative}:${i}: ${keyword}Lines needs a line list, for example: ${keyword}Lines: 123,246:\${SomethingElse}"
        continue
      fi
      rest="${spec}"
      while [[ -n "${rest}" ]]; do
        entry="${rest%%,*}"
        if [[ "${entry}" == "${rest}" ]]; then rest=""; else rest="${rest#*,}"; fi
        entry=$(token_markers_trim "${entry}")
        if [[ -z "${entry}" ]]; then continue; fi
        if [[ "${entry}" == *:* ]]; then
          target=$(token_markers_trim "${entry%%:*}")
          token=$(token_markers_trim "${entry#*:}")
        else
          target="${entry}"
          token="*"
        fi
        case "${target}" in
          ''|*[!0-9]*)
            token_markers_error "${relative}:${i}: ${keyword}Lines entry '${entry}' does not begin with a line number"
            continue
            ;;
        esac
        # Force base 10 - a zero-padded entry like 08 is an arithmetic error.
        target=$((10#${target}))
        token_markers_record "${keyword}" "${relative}" "${i}" "${target}" "${token}"
      done
      continue
    fi

    case "${found}" in
      "${keyword}Above")
        if [[ "${i}" -eq 1 ]]; then
          token_markers_error "${relative}:${i}: ${keyword}Above on the first line has no line above it"
          continue
        fi
        target=$((i - 1))
        ;;
      "${keyword}Below")
        if [[ "${i}" -eq "${TOKEN_MARKERS_TOTAL}" ]]; then
          token_markers_error "${relative}:${i}: ${keyword}Below on the last line has no line below it"
          continue
        fi
        target=$((i + 1))
        ;;
      *)
        target="${i}"
        ;;
    esac

    # A same-line marker is its own target, so the content checks look only at
    # the text before the keyword; anything else and they look at the whole
    # target line.
    marker_search=()
    if [[ "${found}" == "${keyword}" ]]; then
      marker_search=("${before}")
    fi

    if ! ${has_spec}; then
      token_markers_record "${keyword}" "${relative}" "${i}" "${target}" "*" "${marker_search[@]+"${marker_search[@]}"}"
      continue
    fi

    if [[ -z "${spec}" ]]; then
      token_markers_error "${relative}:${i}: ${found} has an empty specifier list; drop the ':' to cover every token on the line"
      continue
    fi

    rest="${spec}"
    while [[ -n "${rest}" ]]; do
      entry="${rest%%,*}"
      if [[ "${entry}" == "${rest}" ]]; then rest=""; else rest="${rest#*,}"; fi
      entry=$(token_markers_trim "${entry}")
      if [[ -z "${entry}" ]]; then continue; fi
      token_markers_record "${keyword}" "${relative}" "${i}" "${target}" "${entry}" "${marker_search[@]+"${marker_search[@]}"}"
    done
  done
}
