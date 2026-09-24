#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for lib/manifest-patch-apply.bash - specifically that the expression
# patch types cannot read files or environment variables from the build host.
#
# yq accepts whitespace between an operator and its parenthesis, and its file
# readers are a family, so an exact-spelling ban list let `load_str ("f")` and
# `load_props("f")` through: both inlined a host file into a manifest that was
# then packaged and pushed.

bats_require_minimum_version 1.5.0

load helpers

setup() {
  TEST_DIR=$(create_test_dir "manifest-patch-apply")
  source "$LIB_DIR/log.bash"
  source "$LIB_DIR/manifest-file-kinds.bash"
  source "$LIB_DIR/manifest-patch-apply.bash"
  SECRET_FILE="${TEST_DIR}/host-secret.env"
  printf 'SECRET=hunter2\n' > "${SECRET_FILE}"
  MANIFEST="${TEST_DIR}/app.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: app\ndata:\n  a: "1"\n' > "${MANIFEST}"
  SANDBOX="${TEST_DIR}/sandbox"
  mkdir -p "${SANDBOX}"
}

# Apply one expression-list patch holding the given single line.
apply_expression() {
  printf '%s\n' "$1" > "${TEST_DIR}/app.yaml.yq-expression-list-test"
  run manifest_patch_apply_one "${MANIFEST}" "${TEST_DIR}/app.yaml.yq-expression-list-test" \
    expression-list "app.yaml.yq-expression-list-test" "${SANDBOX}" 1
}

refute_secret_inlined() {
  ! grep -q hunter2 "${MANIFEST}"
}

@test "patch: rejects load_str with whitespace before the parenthesis" {
  apply_expression ".data.x = load_str (\"${SECRET_FILE}\")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uses 'load_str'"* ]] || return 1
  refute_secret_inlined
}

@test "patch: rejects the other load readers (load_props, load_xml, load_base64)" {
  local op
  for op in load_props load_xml load_base64; do
    apply_expression ".data.x = ${op}(\"${SECRET_FILE}\")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"uses '${op}'"* ]] || return 1
  done
  refute_secret_inlined
}

@test "patch: rejects envsubst, which reads the environment with no argument" {
  apply_expression '.data.x = "${HOME}" | .data.x |= envsubst'
  [ "$status" -ne 0 ]
  [[ "$output" == *"uses 'envsubst'"* ]]
}

@test "patch: still rejects the forms the old list caught" {
  apply_expression ".data.x = load_str(\"${SECRET_FILE}\")"
  [ "$status" -ne 0 ]
  apply_expression '.data.x = strenv(HOME)'
  [ "$status" -ne 0 ]
  apply_expression '.data.x = $ENV.HOME'
  [ "$status" -ne 0 ]
  refute_secret_inlined
}

@test "patch: a key named env or load is data, not an operator" {
  apply_expression '.metadata.labels.env = "production" | .data.load = "x"'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.metadata.labels.env' "${MANIFEST}")" = "production" ]
  [ "$(yq -r '.data.load' "${MANIFEST}")" = "x" ]
}

@test "patch: merge-yaml still merges data mentioning env and load" {
  printf 'data:\n  env: production\n  load: heavy\n' > "${TEST_DIR}/app.yaml.yq-merge-yaml-test"
  run manifest_patch_apply_one "${MANIFEST}" "${TEST_DIR}/app.yaml.yq-merge-yaml-test" \
    merge-yaml "app.yaml.yq-merge-yaml-test" "${SANDBOX}" 1
  [ "$status" -eq 0 ]
  [ "$(yq -r '.data.env' "${MANIFEST}")" = "production" ]
}

@test "patch: with yq's security flags, an expression cannot read a file even past the pattern" {
  [[ ${#MANIFEST_PATCH_YQ_SANDBOX_FLAGS[@]} -gt 0 ]] || skip "installed yq has no --security-disable-file-ops"
  # Straight to the step, bypassing the pattern, to prove the second layer alone.
  run manifest_patch_step "${MANIFEST}" "direct" "${SANDBOX}" 1 "" ".data.x = load_str(\"${SECRET_FILE}\")" sandboxed
  [ "$status" -ne 0 ]
  refute_secret_inlined
}
