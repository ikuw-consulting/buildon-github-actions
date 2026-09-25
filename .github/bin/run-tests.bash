#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# run-tests.bash - Run all tests for buildon-github-actions
#
# Uses BATS (Bash Automated Testing System) either locally or via Docker
#
set -euo pipefail

# This script runs the FULL test suite (~10 minutes). For specific tests, use local bats.
if [[ $# -gt 0 ]]; then
  echo "ERROR: This script runs the full suite and takes 10 minutes."
  echo "Please run the suite you want with local bats instead:"
  echo "  bats $*"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/src/test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if BATS is available
has_bats() {
  command -v bats &>/dev/null
}

# Check if Docker is available
has_docker() {
  command -v docker &>/dev/null
}

# Detect available CPU cores for parallel test execution.
# Falls back to 4 on systems without nproc/sysctl.
detect_jobs() {
  nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

# Run tests with local BATS.
# --jobs N runs separate .bats files in parallel (requires GNU parallel).
# --no-parallelize-within-files keeps tests inside a file serial: fixtures
# (mock docker, _TEST_DIR_COUNTER, env vars) are shared within a file.
run_local() {
  local jobs
  jobs=$(detect_jobs)
  log_info "Running tests with local BATS (--jobs ${jobs})"
  cd "$TEST_DIR"
  bats --jobs "${jobs}" --no-parallelize-within-files *.bats
}

# Check all scripts are executable
check_executables() {
  log_info "Checking scripts are executable"
  local scripts=()
  local globs=(
    "$PROJECT_ROOT/src/scripts/main/*"
    "$PROJECT_ROOT/src/scripts/generators/*"
    "$PROJECT_ROOT/src/scripts/plugins/*/*"
    "$PROJECT_ROOT/src/scripts/util/*"
    "$PROJECT_ROOT/src/test/*.bash"
    "$PROJECT_ROOT/src/test/repo-gen/*.bash"
    "$PROJECT_ROOT/.github/bin/*.bash"
  )

  for glob in "${globs[@]}"; do
    for file in $glob; do
      # Skip markdown files - they're documentation, not scripts
      [[ "$file" == *.md ]] && continue
      # Skip the token-substitution-providers plugin dir - these are
      # sourced libs, not executable plugins. Checked by
      # check_sourced_not_executable instead.
      [[ "$file" == *"/plugins/token-substitution-providers/"* ]] && continue
      [[ -f "$file" ]] && scripts+=("$file")
    done
  done

  local failed=()
  local scanned=0

  for script in "${scripts[@]}"; do
    scanned=$((scanned + 1))
    if [[ ! -x "$script" ]]; then
      failed+=("$script")
    fi
  done

  log_info "Scanned $scanned scripts"

  if [[ ${#failed[@]} -gt 0 ]]; then
    log_error "${#failed[@]} script(s) missing executable permission:"
    for f in "${failed[@]}"; do
      log_error "  - ${f#$PROJECT_ROOT/}"
    done
    exit 1
  fi

  log_info "All scripts executable"
}

# Check sourced files are NOT executable (they should only be sourced, not run directly)
check_sourced_not_executable() {
  log_info "Checking sourced files are not executable"
  local sourced_files=()
  local globs=(
    "$PROJECT_ROOT/src/scripts/lib/*"
    "$PROJECT_ROOT/src/scripts/defaults/*"
    "$PROJECT_ROOT/src/scripts/plugins/token-substitution-providers/*"
  )

  for glob in "${globs[@]}"; do
    for file in $glob; do
      # Skip markdown docs
      [[ "$file" == *.md ]] && continue
      [[ -f "$file" ]] && sourced_files+=("$file")
    done
  done

  local wrongly_executable=()
  local scanned=0

  for script in "${sourced_files[@]}"; do
    scanned=$((scanned + 1))
    if [[ -x "$script" ]]; then
      wrongly_executable+=("$script")
    fi
  done

  log_info "Scanned $scanned sourced files"

  if [[ ${#wrongly_executable[@]} -gt 0 ]]; then
    log_error "${#wrongly_executable[@]} sourced file(s) should NOT be executable (they are sourced, not run directly):"
    for f in "${wrongly_executable[@]}"; do
      log_error "  - ${f#$PROJECT_ROOT/}"
    done
    log_error "Fix with: chmod -x <file>"
    exit 1
  fi

  log_info "All sourced files correctly not executable"
}

# Check generated files are up to date
check_generated_files() {
  log_info "Checking generated files are up to date"

  # Run the assemble script
  "$PROJECT_ROOT/src/bin/assemble-workflows.bash"

  # Check for modified files in generated locations
  local modified_generated
  modified_generated=$(git -C "$PROJECT_ROOT" diff --name-only .github/workflows/ src/actions/ docs/ README.md 2>/dev/null || true)

  if [[ -z "$modified_generated" ]]; then
    log_info "Generated files are up to date"
    return 0
  fi

  # Check for any dirty source files that affect generation (staged or unstaged)
  # Workflow templates, step fragments, action templates, and inputs all contribute to generated output
  local dirty_sources
  dirty_sources=$(git -C "$PROJECT_ROOT" status --porcelain \
    src/workflow-templates/ \
    src/steps-common/ \
    src/action-templates/ \
    src/inputs/ \
    2>/dev/null | grep -v '^?' || true)

  # If ANY source is dirty, generated file changes are local work in progress
  if [[ -n "$dirty_sources" ]]; then
    log_warn "Uncommitted local changes detected - generated files regenerated OK:"
    echo "$modified_generated" | while IFS= read -r file; do
      [[ -n "$file" ]] && log_warn "  - $file"
    done
    log_info "Generated files OK (stage/commit when ready)"
    return 0
  fi

  # No sources dirty but generated files changed - assemble already ran, just need to commit
  log_error "Generated files were regenerated but source files are already committed."
  log_error "This likely means you committed source changes without regenerating."
  log_error "The files below have been regenerated - stage and commit them:"
  echo "$modified_generated" | while IFS= read -r file; do
    [[ -n "$file" ]] && log_error "  - $file"
  done

  # Show the actual diff so CI logs reveal what's different
  log_error "Diff of generated files:"
  git -C "$PROJECT_ROOT" diff .github/workflows/ src/actions/ docs/ README.md || true
  if [[ "${WARN_ONLY_FRESHNESS:-}" == "true" ]]; then
    log_warn "Continuing despite stale files (WARN_ONLY_FRESHNESS=true)"
  else
    exit 1
  fi
}

# Run shellcheck on all scripts
run_shellcheck() {
  log_info "Running shellcheck on scripts"
  local scripts=()
  local globs=(
    "${PROJECT_ROOT}/src/scripts/main/*"
    "${PROJECT_ROOT}/src/scripts/generators/*"
    "${PROJECT_ROOT}/src/scripts/plugins/*/*"
    "${PROJECT_ROOT}/src/scripts/lib/*"
    "${PROJECT_ROOT}/src/scripts/util/*"
    "${PROJECT_ROOT}/src/scripts/defaults/*"
  )

  # Style checks to enable (in addition to defaults)
  local enables=(
    --external-sources
    --enable=require-variable-braces
    --enable=require-double-brackets
    --enable=avoid-nullary-conditions
    --enable=check-unassigned-uppercase
    --enable=deprecate-which
  )

  for glob in "${globs[@]}"; do
    for file in $glob; do
      # Skip markdown files - they're documentation, not scripts
      [[ "${file}" == *.md ]] && continue
      [[ -f "${file}" ]] && scripts+=("${file}")
    done
  done

  if [[ ${#scripts[@]} -eq 0 ]]; then
    log_warn "No scripts found to check"
    return 0
  fi

  log_info "Checking ${#scripts[@]} scripts"

  if command -v shellcheck &>/dev/null; then
    shellcheck "${enables[@]}" "${scripts[@]}"
  elif has_docker; then
    docker run --rm \
      -v "${PROJECT_ROOT}:/workspace" \
      koalaman/shellcheck:v0.10.0 \
      "${enables[@]}" "${scripts[@]/#${PROJECT_ROOT}//workspace}"
  else
    log_warn "shellcheck not available, skipping"
    return 0
  fi

  log_info "shellcheck passed"
}

# Check for Bash 4+ features (scripts must be Bash 3.2 compatible for macOS)
check_bash_portability() {
  log_info "Checking for Bash 4+ features (must be 3.2 compatible)"
  local scripts=()

  while IFS= read -r file; do
    # Skip markdown files - they're documentation, not scripts
    [[ "${file}" == *.md ]] && continue
    scripts+=("${file}")
  done < <(find "${PROJECT_ROOT}/src/scripts" -type f)

  local failed=()

  # Patterns that indicate Bash 4+ features
  # - declare -A: associative arrays
  # - mapfile/readarray: array reading builtin
  # - ${var,,} ${var^^}: case modification
  # - |&: pipe stderr shorthand
  # - coproc: coprocesses
  # - shopt -s globstar: recursive glob
  # - &>>: append stdout+stderr (distinct from &>/dev/null which is 3.2 compatible)
  local bash4_pattern='declare[[:space:]]+-A|mapfile|readarray|\$\{[^}]+,,\}|\$\{[^}]+\^\^\}|\|&|^[[:space:]]*coproc[[:space:]]|shopt[[:space:]]+-s[[:space:]]+globstar|&>>'

  for script in "${scripts[@]}"; do
    if grep -qE "${bash4_pattern}" "${script}" 2>/dev/null; then
      # Get matching lines for error output
      local matches
      matches=$(grep -nE "${bash4_pattern}" "${script}" 2>/dev/null || true)
      if [[ -n "${matches}" ]]; then
        failed+=("${script}")
        log_error "Bash 4+ feature in ${script#${PROJECT_ROOT}/}:"
        echo "${matches}" | while IFS= read -r line; do
          log_error "  ${line}"
        done
      fi
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    log_error "${#failed[@]} script(s) use Bash 4+ features (must be 3.2 compatible for macOS)"
    exit 1
  fi

  log_info "All scripts are Bash 3.2 compatible"
}

# Check for non-portable sed -i usage (must work on both macOS BSD sed and Linux GNU sed)
# Only sed -i.suffix is portable. sed -i '' is macOS-only, bare sed -i is GNU-only.
check_sed_portability() {
  log_info "Checking for non-portable sed -i usage (must use -i.suffix)"
  local scripts=()

  while IFS= read -r file; do
    [[ "${file}" == *.md ]] && continue
    scripts+=("${file}")
  done < <(find "${PROJECT_ROOT}/src/scripts" -type f)

  local failed=()

  for script in "${scripts[@]}"; do
    # Find all sed -i lines
    local sed_i_lines
    sed_i_lines=$(grep -nE 'sed[[:space:]]+-i' "${script}" 2>/dev/null || true)
    [[ -z "${sed_i_lines}" ]] && continue

    # Filter out portable form: sed -i.suffix (dot immediately after -i)
    local bad_lines
    bad_lines=$(echo "${sed_i_lines}" | grep -vE 'sed[[:space:]]+-i\.[[:alnum:]]' || true)
    if [[ -n "${bad_lines}" ]]; then
      failed+=("${script}")
      log_error "Non-portable sed -i in ${script#${PROJECT_ROOT}/}:"
      echo "${bad_lines}" | while IFS= read -r line; do
        log_error "  ${line}"
      done
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    log_error "${#failed[@]} script(s) use non-portable sed -i (use sed -i.bak with cleanup instead)"
    exit 1
  fi

  log_info "All sed -i usage is portable"
}

# Check every reusable workflow template has a matching example directory
# containing build.yaml, KaptainPM.yaml, and README.md. Any file missing is
# a hard failure.
check_example_coverage() {
  log_info "Checking every workflow template has matching examples/<name>/{build,KaptainPM}.yaml + README.md"

  local missing=()
  for template in "${PROJECT_ROOT}"/src/workflow-templates/*.yaml; do
    [[ -f "${template}" ]] || continue
    local name="${template##*/}"
    local stem="${name%.yaml}"
    local dir="${PROJECT_ROOT}/examples/${stem}"
    for f in build.yaml KaptainPM.yaml README.md; do
      if [[ ! -f "${dir}/${f}" ]]; then
        missing+=("${stem}/${f}")
      fi
    done
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "All workflow templates have example dir + 3 files"
    return 0
  fi

  log_error "Workflow templates without an examples/<name>/{build.yaml,KaptainPM.yaml,README.md}:"
  for path in "${missing[@]}"; do
    log_error "  - ${path}"
  done
  exit 1
}

# Check that examples weren't modified by regeneration (source is git tags, not template files)
check_example_freshness() {
  log_info "Checking example files are fresh"

  local modified_examples
  modified_examples=$(git -C "${PROJECT_ROOT}" diff --name-only examples/ 2>/dev/null || true)

  if [[ -z "${modified_examples}" ]]; then
    log_info "Example files are fresh"
    return 0
  fi

  log_error "Example files were modified by regeneration (version tags are stale):"
  echo "${modified_examples}" | while IFS= read -r file; do
    [[ -n "${file}" ]] && log_error "  - ${file}"
  done
  log_error "Run src/bin/assemble-workflows.bash and commit the updated examples"
  exit 1
}

# Download schemas from upstream OCI image and enforce no drift
check_schemas() {
  log_info "Downloading and enforcing KaptainPM.yaml schemas"
  "$SCRIPT_DIR/download-and-enforce-kaptainpm-schemas.bash"
  log_info "Schemas for KaptainPM.yaml match upstream"

  log_info "Downloading and enforcing contract.yaml schemas"
  "$SCRIPT_DIR/download-and-enforce-contract-schemas.bash"
  log_info "Schemas for contract.yaml match upstream"

  log_info "Downloading and enforcing env-report.yaml schema"
  "$SCRIPT_DIR/download-and-enforce-env-report-schema.bash"
  log_info "Schema for env-report.yaml matches upstream"
}

# Validate every examples/guides/*/KaptainPM.yaml against the pinned schema
# Check for BATS assertions that can never fail (negated commands anywhere,
# bare [[ ]] on bash 3.2) unless they are the last command in their body
check_bats_assertions() {
  log_info "Checking BATS assertions can fail their tests"
  "${SCRIPT_DIR}/check-bats-assertions.bash"
  log_info "All BATS assertions can fail their tests"
}

# Check token regexes and delimiter stripping come only from lib/token-format.bash
check_token_patterns() {
  log_info "Checking token patterns come only from lib/token-format.bash"
  "${SCRIPT_DIR}/check-token-patterns.bash"
  log_info "No hand-built token patterns"
}

validate_guide_examples() {
  log_info "Validating guide example KaptainPM.yaml files against schema"
  ( cd "${PROJECT_ROOT}" && "${SCRIPT_DIR}/validate-guides-against-kaptainpm-schema.bash" )
  log_info "Guide examples valid"
}

main() {
  log_info "Starting test suite"
  log_info "Project root: ${PROJECT_ROOT}"

  # Clear and recreate test artifact directory
  local output_sub_path="${OUTPUT_SUB_PATH:-kaptain-out}"
  rm -rf "${PROJECT_ROOT}/${output_sub_path}/test"
  mkdir -p "${PROJECT_ROOT}/${output_sub_path}/test"
  log_info "Cleared ${output_sub_path}/test/ for test artifacts"

  # === Fast checks first (fail fast before 10-minute BATS suite) ===

  # Check scripts are executable
  check_executables

  # Check sourced files are NOT executable
  check_sourced_not_executable

  # Check every reusable workflow template has a consumer example (pure file-existence, sub-second)
  check_example_coverage

  # Check for Bash 4+ features
  check_bash_portability

  # Check for non-portable sed -i
  check_sed_portability

  # Check BATS assertions are not silently ignored by set -e
  check_bats_assertions

  # Check nothing hand-builds token regexes or delimiter stripping
  check_token_patterns

  # Run shellcheck
  run_shellcheck

  # Download schemas and enforce no drift from upstream
  check_schemas

  # Validate guide example KaptainPM.yaml files against the pinned schema
  validate_guide_examples

  # Check generated files are up to date (regenerates working tree)
  check_generated_files

  # Check examples are fresh (after regeneration — source is git tags, not template files)
  check_example_freshness

  # === Sanitize environment before BATS tests ===
  # Prevent CI workflow inputs from bleeding into tests
  log_info "Sanitizing environment for BATS tests"
  while IFS='=' read -r name _; do
    case "$name" in
      PATH|HOME|TMPDIR|TERM|USER|LANG|LC_*|SHELL) ;;
      *) unset "$name" ;;
    esac
  done < <(env)

  # Run BATS tests
  if ! has_bats; then
    log_error "BATS not available. Install with: brew install bats-core (macOS) or apt-get install bats (Ubuntu)."
    exit 1
  fi
  run_local

  log_info "All tests passed!"
}

main "$@"
