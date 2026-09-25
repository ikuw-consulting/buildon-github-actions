#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Token formatting library - name conversion and reference formatting
#
# Functions:
#   is_valid_token_name_style        - Check if name style is valid
#   is_valid_substitution_token_style - Check if substitution style is valid
#   convert_token_name               - Convert UPPER_SNAKE to target name style
#   canonicalize_token_name          - Inverse of convert_token_name (any style -> UPPER_SNAKE)
#   prefix_token_name                - Prepend a canonical prefix to an already-converted name
#   convert_kebab_name               - Convert lower-kebab to target name style
#   format_token_reference           - Wrap name with substitution delimiters
#   format_canonical_token           - Convenience combining both
#   format_project_suffixed_token    - Combine project name + suffix into delimited token
#   validate_token_styles            - Validate both styles and exit on error
#   unresolved_token_regex           - grep-E regex matching unresolved tokens for a given style pair
#   any_token_regex                  - grep-E regex matching token-shaped content in any supported style

# Internal: lowercase a string (bash 3.2 compatible)
lowercase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Internal: uppercase a string (bash 3.2 compatible)
uppercase() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Internal: uppercase first char, lowercase rest (bash 3.2 compatible)
capitalize() {
  local word="$1"
  local first rest
  first=$(echo "${word:0:1}" | tr '[:lower:]' '[:upper:]')
  rest=$(lowercase "${word:1}")
  echo "${first}${rest}"
}

# Check if a token name style is valid
# Usage: is_valid_token_name_style <style>
# Returns: 0 if valid, 1 if invalid
is_valid_token_name_style() {
  if [[ $# -ne 1 ]]; then
    log_error "is_valid_token_name_style requires exactly 1 argument, got $#"
    return 1
  fi
  case "${1:-}" in
    PascalCase|camelCase|UPPER_SNAKE|lower_snake|lower-kebab|UPPER-KEBAB|lower.dot|UPPER.DOT)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Check if a substitution token style is valid
# Usage: is_valid_substitution_token_style <style>
# Returns: 0 if valid, 1 if invalid
is_valid_substitution_token_style() {
  if [[ $# -ne 1 ]]; then
    log_error "is_valid_substitution_token_style requires exactly 1 argument, got $#"
    return 1
  fi
  case "${1:-}" in
    shell|mustache|helm|erb|github-actions|blade|stringtemplate|ognl|t4|swift)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Validate both token styles and exit on error
# Usage: validate_token_styles
# Reads from caller's scope: TOKEN_NAME_STYLE, TOKEN_DELIMITER_STYLE
# Exits: 2 for invalid name style, 3 for invalid delimiter style
validate_token_styles() {
  if ! is_valid_token_name_style "${TOKEN_NAME_STYLE:-}"; then
    log_error "Unknown token name style: ${TOKEN_NAME_STYLE:-}"
    exit 2
  fi

  if ! is_valid_substitution_token_style "${TOKEN_DELIMITER_STYLE:-}"; then
    log_error "Unknown substitution token style: ${TOKEN_DELIMITER_STYLE:-}"
    exit 3
  fi
}

# Return a grep-E regex that matches unresolved tokens for a given style pair
# Usage: unresolved_token_regex <delimiter-style> <name-style>
# Example: unresolved_token_regex "shell" "PascalCase" → '\$\{[A-Z][A-Za-z0-9]*\}'
unresolved_token_regex() {
  if [[ $# -ne 2 ]]; then
    log_error "unresolved_token_regex requires exactly 2 arguments, got $#"
    return 1
  fi

  local delim_style="${1:-}"
  local name_style="${2:-}"

  if [[ -z "${delim_style}" ]]; then
    log_error "delimiter style is required"
    return 1
  fi
  if [[ -z "${name_style}" ]]; then
    log_error "name style is required"
    return 1
  fi

  # Build name character class from name style. Each segment may start with a
  # digit, as the matching plugins/token-name-validators/<style> allows: a
  # name the validator accepts must be matchable here, or it is invisible to
  # the gate and to the unreferenced-value check.
  local name_regex
  local name_segment
  case "${name_style}" in
    PascalCase)      name_segment='[A-Z0-9][A-Za-z0-9]*' ;;
    camelCase)       name_segment='[a-z0-9][A-Za-z0-9]*' ;;
    UPPER_SNAKE)     name_segment='[A-Z0-9_][A-Z0-9_]*' ;;
    lower_snake)     name_segment='[a-z0-9_][a-z0-9_]*' ;;
    lower-kebab)     name_segment='[a-z0-9][a-z0-9-]*' ;;
    UPPER-KEBAB)     name_segment='[A-Z0-9][A-Z0-9-]*' ;;
    lower.dot)       name_segment='[a-z0-9][a-z0-9.]*' ;;
    UPPER.DOT)       name_segment='[A-Z0-9][A-Z0-9.]*' ;;
    *)
      log_error "Unknown name style: ${name_style}"
      return 1
      ;;
  esac

  local name_regex="${name_segment}(/${name_segment})*"

  # Wrap with delimiter regex
  case "${delim_style}" in
    shell)           echo "\\$\\{${name_regex}\\}" ;;
    mustache)        echo "\\{\\{ ${name_regex} \\}\\}" ;;
    helm)            echo "\\{\\{ \\.Values\\.${name_regex} \\}\\}" ;;
    erb)             echo '<%=.*%>' ;;
    github-actions)  echo "\\$\\{\\{ ${name_regex} \\}\\}" ;;
    blade)           echo '\{\{ \$'"${name_regex}"' \}\}' ;;
    stringtemplate)  echo '\$'"${name_regex}"'\$' ;;
    ognl)            echo "%\\{${name_regex}\\}" ;;
    t4)              echo '<#=.*#>' ;;
    swift)           printf '%s\n' "\\\\\\(${name_regex}\\)" ;;
    *)
      log_error "Unknown delimiter style: ${delim_style}"
      return 1
      ;;
  esac
}

# Return a grep -E regex matching token-shaped content in ANY supported
# delimiter style, with a permissive name segment spanning every supported name
# style at once.
#
# This answers "is there a token here at all", not "is there a token in the
# configured scheme". A child project may ship a token defensively in a foreign
# format precisely so it survives to be converted later, and that is still
# token-shaped content. Callers validating human-written markers against file
# content want this; callers scanning for work to do want unresolved_token_regex.
#
# Usage: any_token_regex
any_token_regex() {
  local segment='[A-Za-z0-9_][A-Za-z0-9_.-]*'
  local name="${segment}(/${segment})*"

  local parts
  parts="\\$\\{${name}\\}"                            # shell
  parts="${parts}|\\{\\{ ${name} \\}\\}"              # mustache
  parts="${parts}|\\{\\{ \\.Values\\.${name} \\}\\}"  # helm
  parts="${parts}|<%=.*%>"                            # erb
  parts="${parts}|\\$\\{\\{ ${name} \\}\\}"           # github-actions
  parts="${parts}|\\{\\{ \\\$${name} \\}\\}"          # blade
  parts="${parts}|\\\$${name}\\$"                     # stringtemplate
  parts="${parts}|%\\{${name}\\}"                     # ognl
  parts="${parts}|<#=.*#>"                            # t4
  parts="${parts}|\\\\\\(${name}\\)"                  # swift
  printf '%s\n' "${parts}"
}

# Convert UPPER_SNAKE_CASE name to target style
# Usage: convert_token_name <style> <UPPER_SNAKE_NAME>
# Styles: PascalCase, camelCase, UPPER_SNAKE, lower_snake, lower-kebab, UPPER-KEBAB, lower.dot, UPPER.DOT
convert_token_name() {
  if [[ $# -ne 2 ]]; then
    log_error "convert_token_name requires exactly 2 arguments, got $#"
    return 1
  fi

  local style="${1:-}"
  local name="${2:-}"

  # Validate inputs
  if [[ -z "${style}" ]]; then
    log_error "name style is required"
    return 1
  fi
  if [[ -z "${name}" || "${name}" =~ ^[[:space:]]+$ ]]; then
    log_error "canonical name is required and cannot be whitespace-only"
    return 1
  fi

  case "${style}" in
    PascalCase)
      to_pascal_case "${name}"
      ;;
    camelCase)
      to_camel_case "${name}"
      ;;
    UPPER_SNAKE)
      echo "${name}"
      ;;
    lower_snake)
      lowercase "${name}"
      ;;
    lower-kebab)
      lowercase "${name}" | tr '_' '-'
      ;;
    UPPER-KEBAB)
      echo "${name}" | tr '_' '-'
      ;;
    lower.dot)
      lowercase "${name}" | tr '_' '.'
      ;;
    UPPER.DOT)
      echo "${name}" | tr '_' '.'
      ;;
    *)
      log_error "Unknown name style: ${style}"
      return 1
      ;;
  esac
}

# Inverse of convert_token_name: convert a name from any supported style back
# to the canonical UPPER_SNAKE form. Preserves nested-path separators ('/').
#
# convert_token_name builds PascalCase by capitalising each segment, so a
# capital marks a segment boundary and the inverse splits at every one of them.
# An acronym run is therefore several segments, not one word: OmgWTF is four
# segments and comes back as OmgWTF. Anyone wanting two writes OmgWtf, or
# OMG_WTF in a snake style knowing it renders as OmgWtf.
#
# Usage: canonicalize_token_name <style> <name>
# Example: canonicalize_token_name PascalCase MyToken         -> MY_TOKEN
#          canonicalize_token_name camelCase  version2Part    -> VERSION_2_PART
#          canonicalize_token_name lower-kebab my-token       -> MY_TOKEN
#          canonicalize_token_name PascalCase Vendor/EnvoyCpu -> VENDOR/ENVOY_CPU
#          canonicalize_token_name PascalCase HTTPPort        -> H_T_T_P_PORT
#          canonicalize_token_name camelCase  myID            -> MY_I_D
canonicalize_token_name() {
  if [[ $# -ne 2 ]]; then
    log_error "canonicalize_token_name requires exactly 2 arguments, got $#"
    return 1
  fi

  local style="${1:-}"
  local name="${2:-}"

  if [[ -z "${style}" ]]; then
    log_error "name style is required"
    return 1
  fi
  if [[ -z "${name}" || "${name}" =~ ^[[:space:]]+$ ]]; then
    log_error "name is required and cannot be whitespace-only"
    return 1
  fi

  case "${style}" in
    PascalCase|camelCase)
      # Insert _ before every capital and every digit run, tidy up the
      # separators that produces, then UC. The final expression keeps the /
      # path separator clean - without it Vendor/EnvoyCpu would canonicalise
      # to VENDOR/_ENVOY_CPU.
      echo "${name}" \
        | sed -E 's/([A-Z])/_\1/g; s/([0-9]+)/_\1/g; s/_+/_/g; s/^_//; s|_?/_?|/|g; s/_$//' \
        | tr '[:lower:]' '[:upper:]'
      ;;
    UPPER_SNAKE)
      echo "${name}"
      ;;
    lower_snake)
      uppercase "${name}"
      ;;
    lower-kebab)
      uppercase "${name}" | tr '-' '_'
      ;;
    UPPER-KEBAB)
      echo "${name}" | tr '-' '_'
      ;;
    lower.dot)
      uppercase "${name}" | tr '.' '_'
      ;;
    UPPER.DOT)
      echo "${name}" | tr '.' '_'
      ;;
    *)
      log_error "Unknown name style: ${style}"
      return 1
      ;;
  esac
}

# Prepend a canonical prefix segment to a name that is already in the target
# style, by canonicalising, joining and converting back. The prefix is given in
# UPPER_SNAKE with no trailing separator; the style decides how it joins.
#
# Usage: prefix_token_name <style> <UPPER_SNAKE_PREFIX> <name>
# Example: prefix_token_name PascalCase ORIGINAL ContentFooVersion -> OriginalContentFooVersion
#          prefix_token_name camelCase  ORIGINAL contentFooVersion -> originalContentFooVersion
#          prefix_token_name lower.dot  ORIGINAL content.foo       -> original.content.foo
prefix_token_name() {
  if [[ $# -ne 3 ]]; then
    log_error "prefix_token_name requires exactly 3 arguments, got $#"
    return 1
  fi

  local style="${1:-}"
  local prefix="${2:-}"
  local name="${3:-}"

  if [[ -z "${prefix}" || "${prefix}" =~ ^[[:space:]]+$ ]]; then
    log_error "prefix is required and cannot be whitespace-only"
    return 1
  fi

  local canonical
  canonical=$(canonicalize_token_name "${style}" "${name}") || return 1
  convert_token_name "${style}" "${prefix}_${canonical}"
}

# Format a name with substitution delimiters
# Usage: format_token_reference <style> <name>
# Styles: shell, mustache, helm, erb, github-actions, blade, stringtemplate, ognl, t4, swift
format_token_reference() {
  if [[ $# -ne 2 ]]; then
    log_error "format_token_reference requires exactly 2 arguments, got $#"
    return 1
  fi

  local style="${1:-}"
  local name="${2:-}"

  # Validate inputs
  if [[ -z "${style}" ]]; then
    log_error "substitution style is required"
    return 1
  fi
  if [[ -z "${name}" ]]; then
    log_error "name is required"
    return 1
  fi

  case "${style}" in
    shell)
      echo "\${${name}}"
      ;;
    mustache)
      echo "{{ ${name} }}"
      ;;
    helm)
      echo "{{ .Values.${name} }}"
      ;;
    erb)
      echo "<%= ${name} %>"
      ;;
    github-actions)
      echo "\${{ ${name} }}"
      ;;
    blade)
      echo "{{ \$${name} }}"
      ;;
    stringtemplate)
      echo "\$${name}\$"
      ;;
    ognl)
      echo "%{${name}}"
      ;;
    t4)
      echo "<#= ${name} #>"
      ;;
    swift)
      echo "\\(${name})"
      ;;
    *)
      log_error "Unknown substitution style: ${style}"
      return 1
      ;;
  esac
}

# Convenience: convert name and wrap with delimiters
# Usage: format_canonical_token <substitution-style> <name-style> <UPPER_SNAKE_NAME>
format_canonical_token() {
  if [[ $# -ne 3 ]]; then
    log_error "format_canonical_token requires exactly 3 arguments, got $#"
    return 1
  fi

  local subst_style="${1:-}"
  local name_style="${2:-}"
  local canonical_name="${3:-}"

  # Validate inputs
  if [[ -z "${subst_style}" ]]; then
    log_error "substitution style is required"
    return 1
  fi
  if [[ -z "${name_style}" ]]; then
    log_error "name style is required"
    return 1
  fi
  if [[ -z "${canonical_name}" ]]; then
    log_error "canonical name is required"
    return 1
  fi

  local converted_name
  converted_name=$(convert_token_name "${name_style}" "${canonical_name}") || return 1
  format_token_reference "${subst_style}" "${converted_name}"
}

# Convert lower-kebab-case name to target style
# Usage: convert_kebab_name <style> <lower-kebab-name>
# Converts repo-style names (my-cool-project) to any supported style
# Example: convert_kebab_name "PascalCase" "my-cool-project" → "MyCoolProject"
convert_kebab_name() {
  if [[ $# -ne 2 ]]; then
    log_error "convert_kebab_name requires exactly 2 arguments, got $#"
    return 1
  fi

  local style="${1:-}"
  local kebab_name="${2:-}"

  # Validate inputs
  if [[ -z "${style}" ]]; then
    log_error "name style is required"
    return 1
  fi
  if [[ -z "${kebab_name}" || "${kebab_name}" =~ ^[[:space:]]+$ ]]; then
    log_error "kebab name is required and cannot be whitespace-only"
    return 1
  fi

  # Convert lower-kebab to UPPER_SNAKE, then use existing converter
  local upper_snake
  upper_snake=$(echo "${kebab_name}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  convert_token_name "${style}" "${upper_snake}"
}

# Combine project name with suffix into a formatted, delimited token
# Usage: format_project_suffixed_token <delimiter-style> <name-style> <project-name-kebab> <SUFFIX_UPPER_SNAKE>
# Useful for creating compound tokens like ${MyProject/AffinityColocateApp}
# Example: format_project_suffixed_token "shell" "PascalCase" "my-project" "AFFINITY_COLOCATE_APP"
#          Returns: ${MyProject/AffinityColocateApp}
format_project_suffixed_token() {
  if [[ $# -ne 4 ]]; then
    log_error "format_project_suffixed_token requires exactly 4 arguments, got $#"
    return 1
  fi

  local delim_style="${1:-}"
  local name_style="${2:-}"
  local project_kebab="${3:-}"
  local suffix_upper_snake="${4:-}"

  # Validate inputs
  if [[ -z "${delim_style}" ]]; then
    log_error "delimiter style is required"
    return 1
  fi
  if [[ -z "${name_style}" ]]; then
    log_error "name style is required"
    return 1
  fi
  if [[ -z "${project_kebab}" ]]; then
    log_error "project name (kebab) is required"
    return 1
  fi
  if [[ -z "${suffix_upper_snake}" ]]; then
    log_error "suffix (UPPER_SNAKE) is required"
    return 1
  fi

  local project_converted suffix_converted combined
  project_converted=$(convert_kebab_name "${name_style}" "${project_kebab}") || return 1
  # Suffix is always PascalCase when joining - ensures proper compound identifier
  # e.g., myProject + AffinityColocateApp = myProject/AffinityColocateApp
  suffix_converted=$(convert_token_name "PascalCase" "${suffix_upper_snake}") || return 1
  combined="${project_converted}/${suffix_converted}"

  format_token_reference "${delim_style}" "${combined}"
}

# Internal: PascalCase a single UPPER_SNAKE segment (no path separators)
pascal_case_segment() {
  local segment="$1"
  local result=""
  local IFS='_'
  local word
  for word in ${segment}; do
    if [[ -n "${word}" ]]; then
      result+=$(capitalize "${word}")
    fi
  done
  echo "${result}"
}

# Internal: camelCase a single UPPER_SNAKE segment (no path separators)
camel_case_segment() {
  local segment="$1"
  local result=""
  local IFS='_'
  local word
  local first=true
  for word in ${segment}; do
    if [[ -n "${word}" ]]; then
      if ${first}; then
        result+=$(lowercase "${word}")
        first=false
      else
        result+=$(capitalize "${word}")
      fi
    fi
  done
  echo "${result}"
}

# Internal: Convert UPPER_SNAKE to PascalCase, processing each /-separated
# path segment independently. e.g. VENDOR_ENVOY/REPLICAS -> VendorEnvoy/Replicas
to_pascal_case() {
  local input="$1"
  local result=""
  local IFS='/'
  local segment
  local first=true
  for segment in ${input}; do
    if ! ${first}; then
      result+="/"
    fi
    first=false
    result+=$(pascal_case_segment "${segment}")
  done
  echo "${result}"
}

# Internal: Convert UPPER_SNAKE to camelCase, processing each /-separated
# path segment independently. e.g. VENDOR_ENVOY/REPLICAS -> vendorEnvoy/replicas
to_camel_case() {
  local input="$1"
  local result=""
  local IFS='/'
  local segment
  local first=true
  for segment in ${input}; do
    if ! ${first}; then
      result+="/"
    fi
    first=false
    result+=$(camel_case_segment "${segment}")
  done
  echo "${result}"
}
