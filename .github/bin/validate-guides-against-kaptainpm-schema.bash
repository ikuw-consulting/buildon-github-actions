#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Validates every examples/guides/*/KaptainPM.yaml against the project-variant
# KaptainPM schema at the version pinned in src/schemas/version. All files are
# validated before exit so a single failure does not mask others.
set -euo pipefail

SCHEMAS_DIR="src/schemas"
VERSION_FILE="${SCHEMAS_DIR}/version"

# validate-tooling does the selecting in a real build; this harness runs on its
# own, so point at the in-repo plugin unless something upstream already chose.
SCHEMA_VALIDATION_COMMAND="${SCHEMA_VALIDATION_COMMAND:-src/scripts/plugins/schema-validation-providers/check-jsonschema}"

# Every kaptain script sources platform.bash, which requires this
export BUILD_PLATFORM="${BUILD_PLATFORM:-test}"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "ERROR: Schema version file not found: ${VERSION_FILE}" >&2
  exit 1
fi

SCHEMA_VERSION=$(cat "${VERSION_FILE}")
if [[ -z "${SCHEMA_VERSION}" ]]; then
  echo "ERROR: Schema version file is empty" >&2
  exit 1
fi

SCHEMA_FILE="${SCHEMAS_DIR}/spec-kaptainpm-schema.${SCHEMA_VERSION}.json"

if [[ ! -f "${SCHEMA_FILE}" ]]; then
  echo "ERROR: Schema file not found: ${SCHEMA_FILE}" >&2
  exit 1
fi

echo "Schema: ${SCHEMA_FILE}"
echo

passed=0
failed=0
total=0

shopt -s nullglob
for example in examples/guides/*/KaptainPM.yaml; do
  total=$((total + 1))
  if output=$("${SCHEMA_VALIDATION_COMMAND}" "${SCHEMA_FILE}" "${example}" 2>&1); then
    echo "PASS  ${example}"
    passed=$((passed + 1))
  else
    echo "FAIL  ${example}"
    printf '%s\n' "${output}" | sed 's/^/      /'
    failed=$((failed + 1))
  fi
done

echo
echo "Result: ${passed}/${total} passed"

if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
