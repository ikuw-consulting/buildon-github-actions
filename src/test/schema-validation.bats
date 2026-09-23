#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

bats_require_minimum_version 1.5.0

load helpers

PLUGIN="$PLUGINS_DIR/schema-validation-providers/check-jsonschema"
DEFAULTS="$PROJECT_ROOT/src/scripts/defaults/schema-validation.bash"

setup() {
  BASE_DIR=$(create_test_dir "schema-validation")
  export BASE_DIR

  SCHEMA_FILE="${BASE_DIR}/schema.json"
  TARGET_FILE="${BASE_DIR}/target.yaml"
  export SCHEMA_FILE TARGET_FILE

  cat > "${SCHEMA_FILE}" << 'SCHEMA'
{"type": "object", "required": ["name"]}
SCHEMA
  echo "name: test" > "${TARGET_FILE}"

  # Mock check-jsonschema: records its arguments, passes unless told otherwise
  mkdir -p "${MOCK_BIN_DIR}"
  export MOCK_ARGS_FILE="${BASE_DIR}/check-jsonschema-args"
  cat > "${MOCK_BIN_DIR}/check-jsonschema" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_ARGS_FILE}"
if [[ "${MOCK_CHECK_JSONSCHEMA_FAILS:-false}" == "true" ]]; then
  echo "schema validation failed" >&2
  exit 1
fi
exit 0
MOCK
  chmod +x "${MOCK_BIN_DIR}/check-jsonschema"
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  dump_bats_result
  :
}

# =============================================================================
# Plugin
# =============================================================================

@test "plugin: passes schema and target through to check-jsonschema" {
  run "${PLUGIN}" "${SCHEMA_FILE}" "${TARGET_FILE}"
  [ "$status" -eq 0 ]
  run cat "${MOCK_ARGS_FILE}"
  assert_output_contains "--schemafile ${SCHEMA_FILE} ${TARGET_FILE}"
}

@test "plugin: propagates validation failure" {
  export MOCK_CHECK_JSONSCHEMA_FAILS=true
  run "${PLUGIN}" "${SCHEMA_FILE}" "${TARGET_FILE}"
  [ "$status" -ne 0 ]
  assert_output_contains "schema validation failed"
}

@test "plugin: fails with usage when given too few arguments" {
  run "${PLUGIN}" "${SCHEMA_FILE}"
  [ "$status" -eq 1 ]
  assert_output_contains "Usage: check-jsonschema <schema-file> <target-file>"
}

@test "plugin: fails with usage when given too many arguments" {
  run "${PLUGIN}" "${SCHEMA_FILE}" "${TARGET_FILE}" extra
  [ "$status" -eq 1 ]
  assert_output_contains "Usage: check-jsonschema <schema-file> <target-file>"
}

# =============================================================================
# Defaults guard
# =============================================================================

@test "defaults: accepts the value supplied by validate-tooling" {
  run bash -c "SCHEMA_VALIDATION_COMMAND='${PLUGIN}' source '${DEFAULTS}' && echo \"\${SCHEMA_VALIDATION_COMMAND}\""
  [ "$status" -eq 0 ]
  assert_output_contains "${PLUGIN}"
}

@test "defaults: fails when SCHEMA_VALIDATION_COMMAND is unset" {
  # 127 is what bash 3.2 and 5.x both exit with on a ${var:?message} failure
  run -127 bash -c "unset SCHEMA_VALIDATION_COMMAND; source '${DEFAULTS}'"
  assert_output_contains "SCHEMA_VALIDATION_COMMAND is required - run validate-tooling first"
}
