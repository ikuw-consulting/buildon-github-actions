# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# helpers.bash - Shared test helper functions

# Get project root
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Build platform for tests (scripts source platform.bash which requires this)
export BUILD_PLATFORM="${BUILD_PLATFORM:-test}"

# Source platform defaults then log functions (platform must come first)
source "$PROJECT_ROOT/src/scripts/defaults/platform.bash"
source "$PROJECT_ROOT/src/scripts/lib/log.bash"

# Path to scripts, utilities, libraries, repo providers, and fixtures
SCRIPTS_DIR="$PROJECT_ROOT/src/scripts/main"
GENERATORS_DIR="$PROJECT_ROOT/src/scripts/generators"
UTIL_DIR="$PROJECT_ROOT/src/scripts/util"
LIB_DIR="$PROJECT_ROOT/src/scripts/lib"
PLUGINS_DIR="$PROJECT_ROOT/src/scripts/plugins"
REPO_PROVIDERS_DIR="$PLUGINS_DIR/kubernetes-manifests-repo-providers"
FIXTURES_DIR="$PROJECT_ROOT/src/test/fixtures"

# validate-tooling selects the provider in a real build; tests have no
# validate-tooling step, so select the same way it does - jv first, then
# check-jsonschema - and the suite runs against whatever the host has.
# Tests that mock a specific validator override this with the plugin they mock.
if command -v jv &>/dev/null; then
  HOST_SCHEMA_VALIDATION_COMMAND="$PLUGINS_DIR/schema-validation-providers/jv"
else
  HOST_SCHEMA_VALIDATION_COMMAND="$PLUGINS_DIR/schema-validation-providers/check-jsonschema"
fi
export HOST_SCHEMA_VALIDATION_COMMAND
export SCHEMA_VALIDATION_COMMAND="${HOST_SCHEMA_VALIDATION_COMMAND}"

# Test output directory - all test artifacts go here for diagnostics
OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"
TEST_TARGET_DIR="$PROJECT_ROOT/${OUTPUT_SUB_PATH}/test"
MOCK_BIN_DIR="${TEST_TARGET_DIR}/$(basename "${BATS_TEST_FILENAME:-unknown}" .bats)/mock-bin"

# Counter for unique directory names within a test file
_TEST_DIR_COUNTER=0

# Create a unique test directory under ${OUTPUT_SUB_PATH}/test
# Usage: dir=$(create_test_dir "prefix")
create_test_dir() {
  local prefix="${1:-test}"
  local bats_file_base
  bats_file_base=$(basename "${BATS_TEST_FILENAME}" .bats)
  local test_base_dir="${TEST_TARGET_DIR}/${bats_file_base}/${BATS_TEST_NAME:-unknown}"

  _TEST_DIR_COUNTER=$((_TEST_DIR_COUNTER + 1))
  local dir="${test_base_dir}/${prefix}-${_TEST_DIR_COUNTER}"

  # Clean stale artifacts from previous runs
  rm -rf "${dir}"
  mkdir -p "$dir"
  echo "$dir"
}

# Dump the most recent `run` invocation's status and output to disk under the
# per-test directory used by create_test_dir. Call from teardown() in every
# bats file so flaky failures leave evidence behind for inspection.
dump_bats_result() {
  local file_base test_dir
  file_base=$(basename "${BATS_TEST_FILENAME:-unknown.bats}" .bats)
  test_dir="${TEST_TARGET_DIR}/${file_base}/${BATS_TEST_NAME:-unknown}"
  mkdir -p "${test_dir}"
  {
    echo "test: ${BATS_TEST_NAME:-unknown}"
    echo "status: ${status:-N/A}"
    echo "--- output ---"
    echo "${output:-}"
  } > "${test_dir}/bats-result.log"
}

# Set up mock git that filters push
setup_mock_git() {
  mkdir -p "$MOCK_BIN_DIR"
  cat > "$MOCK_BIN_DIR/git" << 'MOCKGIT'
#!/usr/bin/env bash
if [[ "$1" == "push" ]]; then
  exit 0
fi
exec /usr/bin/git "$@"
MOCKGIT
  chmod +x "$MOCK_BIN_DIR/git"
  export PATH="$MOCK_BIN_DIR:$PATH"
  # Default BUILD_MODE for tests (simulates CI environment)
  export BUILD_MODE="${BUILD_MODE:-build_server}"
  # Default RELEASE_BRANCH for tests
  export RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
}

# Clean up mock git
cleanup_mock_git() {
  rm -rf "$MOCK_BIN_DIR"
}

# Clone a test repo from a fixture bundle
clone_fixture() {
  local fixture_name="$1"
  local bundle_path="$FIXTURES_DIR/${fixture_name}.bundle"
  local repo_dir

  if [[ ! -f "$bundle_path" ]]; then
    echo "Fixture not found: $bundle_path" >&2
    return 1
  fi

  repo_dir=$(create_test_dir "fixture-${fixture_name}")
  git clone --quiet "$bundle_path" "$repo_dir" 2>/dev/null
  cd "$repo_dir"
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Set up local main branch if it exists on remote
  if git rev-parse --verify origin/main &>/dev/null; then
    git branch main origin/main &>/dev/null || true
  fi

  echo "$repo_dir"
}

# Create a temporary git repository for testing (legacy, prefer clone_fixture)
create_test_repo() {
  local repo_dir
  repo_dir=$(create_test_dir "repo")

  cd "$repo_dir"
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Create initial commit
  echo "initial" > README.md
  git add README.md
  git commit --quiet -m "Initial commit"

  echo "$repo_dir"
}

# Cleanup test repository - NO-OP, files left for diagnostics
cleanup_test_repo() {
  # Intentionally empty - test artifacts left in target/ for diagnostics
  :
}

# Create a branch with specific commits
create_branch_with_commits() {
  local branch_name="$1"
  shift
  local commit_messages=("$@")

  git checkout -b "$branch_name" --quiet

  for msg in "${commit_messages[@]}"; do
    echo "$msg" >> content.txt
    git add content.txt
    git commit --quiet -m "$msg"
  done
}

# Create a tag
create_tag() {
  local tag="$1"
  git tag "$tag"
}

# Get current branch
get_current_branch() {
  git rev-parse --abbrev-ref HEAD
}

# Create merge commit (for testing merge detection)
create_merge_commit() {
  local branch_to_merge="$1"
  git merge --no-ff --quiet -m "Merge $branch_to_merge" "$branch_to_merge"
}

# Assert output contains string
assert_output_contains() {
  local expected="$1"
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected output to contain: $expected"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert output does not contain string
assert_output_not_contains() {
  local unexpected="$1"
  if [[ "$output" == *"$unexpected"* ]]; then
    echo "Expected output NOT to contain: $unexpected"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert variable equals value
assert_var_equals() {
  local var_name="$1"
  local expected="$2"
  local actual

  actual=$(echo "$output" | grep "^${var_name}=" | cut -d= -f2-)

  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $var_name=$expected"
    echo "Actual $var_name=$actual"
    return 1
  fi
}

# Set up mock docker/podman that logs calls
# Control behavior with environment variables:
#   MOCK_DOCKER_MANIFEST_EXISTS=true        - manifest inspect returns success
#   MOCK_DOCKER_PULL_FAILS=true             - pull returns failure (default: succeeds)
#   MOCK_DOCKER_IMAGE_INSPECT_EXISTS=false  - image inspect returns failure (default: succeeds)
#   MOCK_DOCKER_IMAGE_EXISTS=false          - image exists returns failure (default: succeeds)
#   MOCK_DOCKER_LOCAL_MANIFEST_EXISTS=true  - manifest exists returns success (default: fails)
setup_mock_docker() {
  export MOCK_DOCKER_CALLS=$(create_test_dir "mock-docker")/calls.log
  mkdir -p "$MOCK_BIN_DIR"
  cat > "$MOCK_BIN_DIR/docker" << 'MOCKDOCKER'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_DOCKER_CALLS"
if [[ "$1" == "manifest" && "$2" == "inspect" ]]; then
  if [[ "${MOCK_DOCKER_MANIFEST_EXISTS:-false}" == "true" ]]; then
    exit 0
  else
    exit 1
  fi
fi
if [[ "$1" == "manifest" && "$2" == "exists" ]]; then
  if [[ "${MOCK_DOCKER_LOCAL_MANIFEST_EXISTS:-false}" == "true" ]]; then
    exit 0
  else
    exit 1
  fi
fi
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  if [[ "${MOCK_DOCKER_IMAGE_INSPECT_EXISTS:-true}" == "true" ]]; then
    exit 0
  else
    exit 1
  fi
fi
if [[ "$1" == "image" && "$2" == "exists" ]]; then
  if [[ "${MOCK_DOCKER_IMAGE_EXISTS:-true}" == "true" ]]; then
    exit 0
  else
    exit 1
  fi
fi
if [[ "$1" == "pull" ]]; then
  if [[ "${MOCK_DOCKER_PULL_FAILS:-false}" == "true" ]]; then
    exit 1
  fi
  exit 0
fi
exit 0
MOCKDOCKER
  chmod +x "$MOCK_BIN_DIR/docker"
  # Also create podman mock (same behavior) for IMAGE_BUILD_COMMAND=podman tests
  cp "$MOCK_BIN_DIR/docker" "$MOCK_BIN_DIR/podman"
  chmod +x "$MOCK_BIN_DIR/podman"
  export PATH="$MOCK_BIN_DIR:$PATH"
}

# Clean up mock docker - NO-OP, files left for diagnostics
cleanup_mock_docker() {
  rm -f "$MOCK_BIN_DIR/docker"
  # Leave MOCK_DOCKER_CALLS log file for diagnostics
}

# Assert docker was called with specific args
assert_docker_called() {
  local expected="$1"
  # Use -- to prevent patterns starting with - from being interpreted as grep options
  if ! grep -q -- "$expected" "$MOCK_DOCKER_CALLS" 2>/dev/null; then
    echo "Expected docker to be called with: $expected"
    echo "Actual calls:"
    cat "$MOCK_DOCKER_CALLS" 2>/dev/null || echo "(none)"
    return 1
  fi
}

# Assert docker was NOT called with specific command
assert_docker_not_called() {
  local unexpected="$1"
  if grep -q "^$unexpected" "$MOCK_DOCKER_CALLS" 2>/dev/null; then
    echo "Expected docker NOT to be called with: $unexpected"
    echo "Actual calls:"
    cat "$MOCK_DOCKER_CALLS"
    return 1
  fi
}

# Assert content contains pattern (shows actual content on failure)
assert_contains() {
  local content="$1"
  local pattern="$2"
  local label="${3:-manifest}"
  if [[ "$content" != *"$pattern"* ]]; then
    echo "EXPECTED PATTERN: $pattern" >&3
    echo "ACTUAL ${label}:" >&3
    echo "$content" >&3
    return 1
  fi
}

# Extract all exported variable names from a hook script
# Usage: vars=$(extract_hook_exports "$SCRIPTS_DIR/hook-post-docker-tests")
extract_hook_exports() {
  local script_path="$1"
  grep "^export " "$script_path" \
    | sed 's/^export //' \
    | tr ' ' '\n' \
    | grep -v '^$' \
    | sort -u
}

# Extract all defaults files sourced by a script
# Usage: files=$(extract_sourced_defaults "$SCRIPTS_DIR/hook-post-docker-tests")
extract_sourced_defaults() {
  local script_path="$1"
  local script_dir
  script_dir=$(dirname "$script_path")

  grep 'source.*defaults/' "$script_path" \
    | sed -E 's|.*source[[:space:]]+"?\$\{?[^}]*\}?/\.\./(defaults/[^"]+)"?|\1|' \
    | sed -E 's|.*source[[:space:]]+"?\$\([^)]+\)/\.\./(defaults/[^"]+)"?|\1|' \
    | while read -r rel_path; do
        echo "${script_dir}/../${rel_path}"
      done
}

# Extract all input variables defined in defaults files (long-form with known prefixes)
# Only catches variables that should be exported: KUBERNETES_*, DOCKER_*, TOKEN_*, etc.
# Excludes convenience aliases like *_INPUT which are internal to defaults files
# Usage: vars=$(extract_defaults_inputs "$SCRIPTS_DIR/../defaults/docker-build.bash")
extract_defaults_inputs() {
  local defaults_file="$1"
  # Match: VAR_NAME="${VAR_NAME:-...}" pattern for known input prefixes
  # These are the workflow input variables that hooks should export
  local prefixes="KUBERNETES_|DOCKER_|MANIFESTS_|TOKEN_|TAG_VERSION_|GITHUB_RELEASE_|QC_|BLOCK_|OUTPUT_|CONFIG_|ADDITIONAL_RELEASE_BRANCHES|DEFAULT_BRANCH|CURRENT_BRANCH|RELEASE_BRANCH|BUILD_MODE|IMAGE_BUILD_COMMAND|SCHEMA_VALIDATION_COMMAND"
  grep -E "^(${prefixes})[A-Z0-9_]*=\"\\\$\\{" "$defaults_file" 2>/dev/null \
    | sed -E 's/^([A-Z][A-Z0-9_]*)=.*/\1/' \
    | grep -v '_INPUT$' \
    | sort -u
}

# Extract all input variables from all defaults files sourced by a hook
# Usage: vars=$(extract_all_hook_inputs "$SCRIPTS_DIR/hook-post-docker-tests")
extract_all_hook_inputs() {
  local hook_script="$1"
  local script_dir
  script_dir=$(dirname "$hook_script")

  # Find all sourced defaults files and extract their inputs
  grep 'source.*defaults/' "$hook_script" \
    | sed -E 's|.*"([^"]+)".*|\1|' \
    | sed 's|\${BASH_SOURCE\[0\]}|'"$hook_script"'|g' \
    | sed "s|\$(dirname[^)]*)|${script_dir}|g" \
    | while read -r path; do
        # Resolve the path
        local resolved
        resolved=$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")
        if [[ -f "$resolved" ]]; then
          extract_defaults_inputs "$resolved"
        fi
      done \
    | sort -u
}

# Verify hook exports all inputs from its sourced defaults files
# Usage: verify_hook_exports_all_inputs "$SCRIPTS_DIR/hook-post-docker-tests"
verify_hook_exports_all_inputs() {
  local hook_script="$1"
  local script_dir
  script_dir=$(dirname "$hook_script")
  local defaults_dir="${script_dir}/../defaults"

  # Get all exports from the hook
  local hook_exports
  hook_exports=$(extract_hook_exports "$hook_script")

  # Get all inputs from sourced defaults files
  local all_inputs=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Extract the defaults file path from the source line
    local defaults_file
    defaults_file=$(echo "$line" | sed -E 's|.*/(defaults/[^"]+)"?|\1|')
    if [[ -f "${script_dir}/../${defaults_file}" ]]; then
      local inputs
      inputs=$(extract_defaults_inputs "${script_dir}/../${defaults_file}")
      all_inputs="${all_inputs}${inputs}"$'\n'
    fi
  done < <(grep 'source.*defaults/' "$hook_script")

  # Find inputs not in exports
  local missing=""
  while IFS= read -r input; do
    [[ -z "$input" ]] && continue
    if ! echo "$hook_exports" | grep -q "^${input}$"; then
      missing="${missing} ${input}"
    fi
  done < <(echo "$all_inputs" | sort -u)

  if [[ -n "$missing" ]]; then
    echo "Hook script missing exports for inputs from defaults:${missing}" >&3
    return 1
  fi
}

# Generate a hook script that dumps all specified variables
# Usage: generate_export_dump_hook "$hook_script_path" "$output_file" VAR1 VAR2 ...
generate_export_dump_hook() {
  local hook_script="$1"
  local output_file="$2"
  shift 2

  cat > "$hook_script" << 'HEADER'
#!/usr/bin/env bash
set -uo pipefail
{
HEADER

  # Use ${VAR+__SET__} to check if variable is set (even if empty)
  # Then output either the value or __UNSET__
  for var in "$@"; do
    echo "  if [[ \"\${${var}+__SET__}\" == \"__SET__\" ]]; then echo \"${var}=\${${var}}\"; else echo \"${var}=__UNSET__\"; fi" >> "$hook_script"
  done

  cat >> "$hook_script" << FOOTER
} > "$output_file"
FOOTER

  chmod +x "$hook_script"
}

# Extract all env variable names from an action template's env section
# Usage: vars=$(extract_action_template_env_vars "$ACTION_TEMPLATES_DIR/hook-post-docker-tests.yaml")
extract_action_template_env_vars() {
  local action_template="$1"
  # Match lines like:         KUBERNETES_FOO: ${{ inputs.kubernetes-foo }}
  # Extract the variable name (before the colon)
  grep -E '^[[:space:]]+[A-Z][A-Z0-9_]+:' "$action_template" 2>/dev/null \
    | sed 's/^[[:space:]]*//' \
    | cut -d: -f1 \
    | sort -u
}

# Extract all input names from an action template (from inputs: section)
# Usage: inputs=$(extract_action_template_inputs "$ACTION_TEMPLATES_DIR/hook-post-docker-tests.yaml")
extract_action_template_inputs() {
  local action_template="$1"
  # Match lines in inputs section like: kubernetes-foo-bar:
  # This is a simplified extraction - just gets kebab-case input names
  sed -n '/^inputs:/,/^runs:/p' "$action_template" 2>/dev/null \
    | grep -E '^  [a-z][a-z0-9-]+:' \
    | sed -E 's/^\s+([a-z][a-z0-9-]+):.*/\1/' \
    | sort -u
}

# Verify action template has env mappings for all exports in the corresponding hook script
# Usage: verify_action_template_env_mappings "$ACTION_TEMPLATES_DIR/hook-post-docker-tests.yaml" "$SCRIPTS_DIR/hook-post-docker-tests"
verify_action_template_env_mappings() {
  local action_template="$1"
  local hook_script="$2"

  # Get all exports from the hook script
  local hook_exports
  hook_exports=$(extract_hook_exports "$hook_script")

  # Get all env mappings from the action template
  local action_env_vars
  action_env_vars=$(extract_action_template_env_vars "$action_template")

  # Find exports not in action env (excluding step outputs which come from inputs)
  # Step outputs like VERSION, DOCKER_TAG, etc. are passed via action inputs, not defaults
  local step_outputs="VERSION VERSION_MAJOR VERSION_MINOR VERSION_PATCH VERSION_2_PART VERSION_3_PART VERSION_4_PART"
  step_outputs="$step_outputs VERSION_DNS_SAFE VERSION_2_PART_DNS_SAFE VERSION_3_PART_DNS_SAFE VERSION_4_PART_DNS_SAFE"
  step_outputs="$step_outputs DOCKER_TAG DOCKER_IMAGE_NAME GIT_TAG PROJECT_NAME IS_RELEASE"
  step_outputs="$step_outputs TARGET_IMAGE_FULL_URI DOCKER_IMAGE_FULL_URI"
  step_outputs="$step_outputs MANIFESTS_ZIP_FILE_NAME"

  # Computed vars from defaults files - not wired via action inputs
  local computed_vars="DOCKER_CONTEXT_SUB_PATH DOCKER_CONTEXT_SUB_PATH_LINUX_AMD64 DOCKER_CONTEXT_SUB_PATH_LINUX_ARM64"
  computed_vars="$computed_vars MANIFESTS_COMBINED_SUB_PATH MANIFESTS_CONFIG_SUB_PATH MANIFESTS_SUBSTITUTED_SUB_PATH MANIFESTS_ZIP_SUB_PATH"
  computed_vars="$computed_vars MANIFESTS_DEFAULTS_SUB_PATH MANIFESTS_ADDITIONAL_DEFAULTS_SUB_PATH MANIFESTS_ADDITIONAL_SUB_PATH"
  computed_vars="$computed_vars MANIFESTS_ADDITIONAL_TOKENS_SUB_PATH"

  local missing=""
  while IFS= read -r export_var; do
    [[ -z "$export_var" ]] && continue
    # Skip step outputs - they're wired differently
    if echo "$step_outputs" | grep -qw "$export_var"; then
      continue
    fi
    # Skip computed vars - set by defaults files, not action inputs
    if echo "$computed_vars" | grep -qw "$export_var"; then
      continue
    fi
    if ! echo "$action_env_vars" | grep -q "^${export_var}$"; then
      missing="${missing} ${export_var}"
    fi
  done < <(echo "$hook_exports")

  if [[ -n "$missing" ]]; then
    echo "Action template missing env mappings for hook exports:${missing}" >&3
    return 1
  fi
}

# Verify all exported variables are accessible in hook output
# Usage: verify_all_exports_accessible "$output_file" VAR1 VAR2 ...
verify_all_exports_accessible() {
  local output_file="$1"
  shift
  local failed=0
  local missing_vars=""

  for var in "$@"; do
    if grep -q "^${var}=__UNSET__$" "$output_file"; then
      missing_vars="${missing_vars} ${var}"
      failed=1
    elif ! grep -q "^${var}=" "$output_file"; then
      missing_vars="${missing_vars} ${var}(not-in-output)"
      failed=1
    fi
  done

  if [[ $failed -eq 1 ]]; then
    echo "Missing or unset exports:${missing_vars}" >&3
    echo "Output file contents:" >&3
    cat "$output_file" >&3
    return 1
  fi
}
