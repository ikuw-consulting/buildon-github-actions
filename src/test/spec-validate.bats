#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/spec-validate"

setup() {
  local base_dir
  base_dir=$(create_test_dir "spec-validate")
  export OUTPUT_SUB_PATH="${base_dir}"
  export SPEC_DIR="${base_dir}/docker/substituted/json"
  mkdir -p "${SPEC_DIR}"

  # Required by docker-common.bash
  export IMAGE_BUILD_COMMAND="docker"

  # Mock jq: exit 0 for syntax checks, return schema URL for ."$schema" query
  mkdir -p "${MOCK_BIN_DIR}"
  cat > "${MOCK_BIN_DIR}/jq" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'."$schema"'* ]]; then
  echo "https://example.com/schema.json"
else
  exit 0
fi
MOCK
  chmod +x "${MOCK_BIN_DIR}/jq"
  export PATH="${MOCK_BIN_DIR}:${PATH}"

  # Mock check-jsonschema: always succeeds
  cat > "${MOCK_BIN_DIR}/check-jsonschema" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${MOCK_BIN_DIR}/check-jsonschema"

  # Mocking check-jsonschema only works if the plugin routes there, so pin it
  export SCHEMA_VALIDATION_COMMAND="${PLUGINS_DIR}/schema-validation-providers/check-jsonschema"

  export SPEC_TYPE="schema"
}

teardown() {
  dump_bats_result
  :
}

# =============================================================================
# Missing required variables
# =============================================================================

@test "fails when SPEC_TYPE not set" {
  echo '{}' > "${SPEC_DIR}/my-spec-1.0.0.json"
  unset SPEC_TYPE
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
}

@test "fails when OUTPUT_SUB_PATH not set" {
  unset OUTPUT_SUB_PATH
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
}

@test "fails when SPEC_TYPE is invalid" {
  echo '{}' > "${SPEC_DIR}/my-spec-1.0.0.json"
  export SPEC_TYPE="invalid"
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  assert_output_contains "SPEC_TYPE must be"
}

# =============================================================================
# File discovery
# =============================================================================

@test "fails when no json files found" {
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  assert_output_contains "No JSON spec files found"
}

@test "succeeds with one json file" {
  echo '{}' > "${SPEC_DIR}/my-spec-1.0.0.json"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "validates all json files in directory" {
  echo '{}' > "${SPEC_DIR}/my-spec-1.0.0.json"
  echo '{}' > "${SPEC_DIR}/my-spec-layer-1.0.0.json"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_output_contains "my-spec-1.0.0.json"
  assert_output_contains "my-spec-layer-1.0.0.json"
}

# =============================================================================
# Basic validation (always run)
# =============================================================================

@test "runs jq syntax check on each file" {
  echo '{}' > "${SPEC_DIR}/my-spec-1.0.0.json"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_output_contains "JSON syntax valid"
}

@test "fails when jq reports invalid syntax" {
  cat > "${MOCK_BIN_DIR}/jq" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'."$schema"'* ]]; then
  echo "https://example.com/schema.json"
else
  exit 1
fi
MOCK
  chmod +x "${MOCK_BIN_DIR}/jq"
  echo 'not valid json' > "${SPEC_DIR}/my-spec-1.0.0.json"
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  assert_output_contains "Invalid JSON syntax"
}

@test "logs validation passed for each file" {
  echo '{}' > "${SPEC_DIR}/my-spec-1.0.0.json"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  assert_output_contains "Validation passed"
}

# =============================================================================
# API spec type
# =============================================================================

@test "succeeds with api spec type" {
  echo '{"$schema":"https://example.com/schema.json"}' > "${SPEC_DIR}/my-api-1.0.0.json"
  export SPEC_TYPE="api"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "fails for api spec without schema field" {
  cat > "${MOCK_BIN_DIR}/jq" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'."$schema"'* ]]; then
  echo ""
else
  exit 0
fi
MOCK
  chmod +x "${MOCK_BIN_DIR}/jq"
  echo '{}' > "${SPEC_DIR}/my-api-1.0.0.json"
  export SPEC_TYPE="api"
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  assert_output_contains "must declare"
}
