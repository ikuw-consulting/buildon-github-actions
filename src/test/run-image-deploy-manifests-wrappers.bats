#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for the six thin kubernetes-run-image-deploy-manifests-* wrapper
# entrypoints. Each wrapper pins the stock manifest-pipeline inputs at
# the deploy-manifests block's dirs (lib/run-image-deploy-manifests-
# context.bash) inside its own process only, then execs the stock stage.
#
# Approach: each wrapper is copied into a scaffold scripts tree whose
# defaults/ and lib/ are symlinks to the real ones, and the stock script
# it execs is replaced with a stub that captures its environment. The
# assertions check the pinned dirs, the exec handoff, and that the
# inbound env landscape is otherwise passed through untouched.

bats_require_minimum_version 1.5.0

load helpers

setup() {
  TEST_DIR=$(create_test_dir "run-image-deploy-manifests-wrappers")
  SCAFFOLD="${TEST_DIR}/scripts"
  mkdir -p "${SCAFFOLD}/main"
  ln -s "${PROJECT_ROOT}/src/scripts/defaults" "${SCAFFOLD}/defaults"
  ln -s "${PROJECT_ROOT}/src/scripts/lib" "${SCAFFOLD}/lib"
  CAPTURED_ENV="${TEST_DIR}/captured-env"
}

# Stage <wrapper-name> in the scaffold with a stub in place of the stock
# script it execs, then run it from TEST_DIR with a minimal env.
run_wrapper() {
  local wrapper="$1"
  local stock="$2"

  cp "${SCRIPTS_DIR}/${wrapper}" "${SCAFFOLD}/main/${wrapper}"
  cat > "${SCAFFOLD}/main/${stock}" << EOF
#!/usr/bin/env bash
env | LC_ALL=C sort > "${CAPTURED_ENV}"
echo "STOCK-CALLED: ${stock}"
EOF
  chmod +x "${SCAFFOLD}/main/${stock}" "${SCAFFOLD}/main/${wrapper}"

  run env \
    OUTPUT_SUB_PATH="kaptain-out" \
    ENV_ENVIRONMENT_DEPLOY_SOURCE_BASE_PATH="src/environment" \
    MANIFESTS_SUB_PATH="src/kubernetes" \
    DEFAULTS_SUB_PATH="src/defaults" \
    CONFIG_SUB_PATH="src/config" \
    LANDSCAPE_CANARY="untouched-value" \
    bash -c "cd '${TEST_DIR}' && '${SCAFFOLD}/main/${wrapper}'"
}

# The context lib's pinning contract: the three stock-pipeline inputs
# point INTO the deploy-manifests tree, regardless of what the inbound env said.
assert_pinned_context() {
  grep -qx "MANIFESTS_SUB_PATH=kaptain-out/run-image-deploy-manifests/manifests" "${CAPTURED_ENV}"
  grep -qx "DEFAULTS_SUB_PATH=kaptain-out/run-image-deploy-manifests/defaults" "${CAPTURED_ENV}"
  grep -qx "CONFIG_SUB_PATH=src/environment/config" "${CAPTURED_ENV}"
  # Everything else in the inbound landscape arrives untouched.
  grep -qx "LANDSCAPE_CANARY=untouched-value" "${CAPTURED_ENV}"
}

@test "package-prepare wrapper pins the deploy-manifests dirs and execs the stock stage" {
  run_wrapper kubernetes-run-image-deploy-manifests-package-prepare kubernetes-manifests-package-prepare
  [ "${status}" -eq 0 ]
  assert_output_contains "STOCK-CALLED: kubernetes-manifests-package-prepare"
  assert_pinned_context
}

@test "substitute wrapper pins the deploy-manifests dirs and execs the stock stage" {
  run_wrapper kubernetes-run-image-deploy-manifests-substitute kubernetes-manifests-substitute
  [ "${status}" -eq 0 ]
  assert_output_contains "STOCK-CALLED: kubernetes-manifests-substitute"
  assert_pinned_context
}

@test "contract-generate wrapper pins the deploy-manifests dirs and execs the stock stage" {
  run_wrapper kubernetes-run-image-deploy-manifests-contract-generate kubernetes-manifests-contract-generate
  [ "${status}" -eq 0 ]
  assert_output_contains "STOCK-CALLED: kubernetes-manifests-contract-generate"
  assert_pinned_context
}

@test "lineage wrapper pins the deploy-manifests dirs, sets the app section, and execs the stock stage" {
  run_wrapper kubernetes-run-image-deploy-manifests-lineage-data-generate kubernetes-lineage-data-generate
  [ "${status}" -eq 0 ]
  assert_output_contains "STOCK-CALLED: kubernetes-lineage-data-generate"
  assert_pinned_context
  # The deploy-manifests set is the run's inner app: the record section
  # belongs to the later bespoke block.
  grep -qx "ENV_BUILD_SECTION=app" "${CAPTURED_ENV}"
}

@test "package wrapper pins the deploy-manifests dirs and execs the stock stage" {
  run_wrapper kubernetes-run-image-deploy-manifests-package kubernetes-manifests-package
  [ "${status}" -eq 0 ]
  assert_output_contains "STOCK-CALLED: kubernetes-manifests-package"
  assert_pinned_context
}

@test "repo-provider-package wrapper pins the deploy-manifests dirs and execs the stock stage" {
  run_wrapper kubernetes-run-image-deploy-manifests-repo-provider-package kubernetes-manifests-repo-provider-package
  [ "${status}" -eq 0 ]
  assert_output_contains "STOCK-CALLED: kubernetes-manifests-repo-provider-package"
  assert_pinned_context
}

teardown() {
  dump_bats_result
  :
}
