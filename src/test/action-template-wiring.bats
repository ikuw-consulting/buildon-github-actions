#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for action template wiring
# Verifies that action templates have env mappings for all variables
# that the corresponding hook scripts export

bats_require_minimum_version 1.5.0

load helpers

ACTION_TEMPLATES_DIR="$PROJECT_ROOT/src/action-templates"

setup() {
  :
}

teardown() {
  dump_bats_result
  :
}

@test "hook-post-docker-tests action template wires all hook exports" {
  run verify_action_template_env_mappings \
    "$ACTION_TEMPLATES_DIR/hook-post-docker-tests.yaml" \
    "$SCRIPTS_DIR/hook-post-docker-tests"
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "hook-pre-docker-prepare action template wires all hook exports" {
  run verify_action_template_env_mappings \
    "$ACTION_TEMPLATES_DIR/hook-pre-docker-prepare.yaml" \
    "$SCRIPTS_DIR/hook-pre-docker-prepare"
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "hook-pre-tagging-tests action template wires all hook exports" {
  run verify_action_template_env_mappings \
    "$ACTION_TEMPLATES_DIR/hook-pre-tagging-tests.yaml" \
    "$SCRIPTS_DIR/hook-pre-tagging-tests"
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "hook-pre-package-prepare action template wires all hook exports" {
  run verify_action_template_env_mappings \
    "$ACTION_TEMPLATES_DIR/hook-pre-package-prepare.yaml" \
    "$SCRIPTS_DIR/hook-pre-package-prepare"
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "hook-post-package-tests action template wires all hook exports" {
  run verify_action_template_env_mappings \
    "$ACTION_TEMPLATES_DIR/hook-post-package-tests.yaml" \
    "$SCRIPTS_DIR/hook-post-package-tests"
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "hook-pre-publish action template wires all hook exports" {
  run verify_action_template_env_mappings \
    "$ACTION_TEMPLATES_DIR/hook-pre-publish.yaml" \
    "$SCRIPTS_DIR/hook-pre-publish"
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

# =============================================================================
# Env steps: what a script requires must reach it on a runner
# =============================================================================
# Locally every step's outputs land in the environment; on a runner a step gets
# only what its action maps and its steps-common passes.

# Asserts <template> maps each VAR from an input and <steps-common> passes that
# input. Prints every gap.
# Usage: verify_step_wires <template> <steps-common> <VAR>...
verify_step_wires() {
  local template="$1" step="$2"
  shift 2
  local var input missing=0
  for var in "$@"; do
    input=$(sed -n -E "s/^[[:space:]]+${var}: \\$\\{\\{ inputs\\.([a-z0-9-]+) \\}\\}\$/\\1/p" "${template}")
    if [[ -z "${input}" ]]; then
      echo "${template##*/}: ${var} is not mapped from an input"
      missing=$((missing + 1))
      continue
    fi
    if ! grep -qE "^[[:space:]]+${input}: " "${step}"; then
      echo "${step##*/}: does not pass ${input} (for ${var})"
      missing=$((missing + 1))
    fi
  done
  [[ "${missing}" -eq 0 ]]
}

@test "kubernetes-run-substitute wires everything prepare-substitution-tokens requires" {
  local required
  required=$(sed -n -E 's/^([A-Z0-9_]+)="\$\{[A-Z0-9_]+:\?.*/\1/p' "$UTIL_DIR/prepare-substitution-tokens" \
    | grep -vx 'TOKENS_OUTPUT_SUB_PATH')
  [ "$(printf '%s\n' "${required}" | grep -c .)" -ge 16 ]
  # shellcheck disable=SC2086 # one VAR per word
  run verify_step_wires \
    "$ACTION_TEMPLATES_DIR/kubernetes-run-substitute.yaml" \
    "$PROJECT_ROOT/src/steps-common/run-substitute.yaml" \
    ${required} TOKEN_NAME_VALIDATION
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "kaptain-init wires the container runtime, schema validator and registry defaults" {
  run verify_step_wires \
    "$ACTION_TEMPLATES_DIR/kaptain-init.yaml" \
    "$PROJECT_ROOT/src/steps-common/kaptain-init.yaml" \
    IMAGE_BUILD_COMMAND SCHEMA_VALIDATION_COMMAND DOCKER_TARGET_REGISTRY DOCKER_TARGET_NAMESPACE
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "kubernetes-run-aggregate wires the schema validator" {
  run verify_step_wires \
    "$ACTION_TEMPLATES_DIR/kubernetes-run-aggregate.yaml" \
    "$PROJECT_ROOT/src/steps-common/run-aggregate.yaml" \
    SCHEMA_VALIDATION_COMMAND
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "kubernetes-run-image-deploy-manifests-contract-generate wires the schema validator" {
  run verify_step_wires \
    "$ACTION_TEMPLATES_DIR/kubernetes-run-image-deploy-manifests-contract-generate.yaml" \
    "$PROJECT_ROOT/src/steps-common/run-image-deploy-manifests-contract-generate.yaml" \
    SCHEMA_VALIDATION_COMMAND
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "every run step wires BUILD_KIND from load-final" {
  local step failures=0
  for step in aggregate substitute finalise consumption-report package; do
    run verify_step_wires \
      "$ACTION_TEMPLATES_DIR/kubernetes-run-${step}.yaml" \
      "$PROJECT_ROOT/src/steps-common/run-${step}.yaml" \
      BUILD_KIND
    if [[ "$status" -ne 0 ]]; then
      echo "$output" >&3
      failures=$((failures + 1))
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

@test "kubernetes-run-image-deploy-manifests wires the job post-deploy sleeps" {
  run verify_step_wires \
    "$ACTION_TEMPLATES_DIR/kubernetes-run-image-deploy-manifests.yaml" \
    "$PROJECT_ROOT/src/steps-common/run-image-deploy-manifests.yaml" \
    ENV_JOB_POST_DEPLOY_SLEEP_AFTER_SUCCESS ENV_JOB_POST_DEPLOY_SLEEP_AFTER_FAILURE
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

# Locally every step's outputs are exported, so a step reading the outputs of a
# step its workflow lacks only shows on a runner, as an empty input.
@test "every workflow injecting a step that reads manifest-package has a step with that id" {
  local readers reader workflow step ids failures=0
  readers=$(grep -l 'steps\.manifest-package\.outputs\.' "$PROJECT_ROOT"/src/steps-common/*.yaml)
  [ -n "${readers}" ]
  for reader in ${readers}; do
    reader=$(basename "${reader}" .yaml)
    for workflow in "$PROJECT_ROOT"/src/workflow-templates/*.yaml; do
      grep -q "INJECT: ${reader}\$" "${workflow}" || continue
      # The id, not the step file, is what a runner resolves.
      ids=""
      for step in $(sed -n -E 's/^[[:space:]]*# INJECT: ([a-z0-9-]+)$/\1/p' "${workflow}"); do
        [[ -f "$PROJECT_ROOT/src/steps-common/${step}.yaml" ]] || continue
        ids="${ids} $(sed -n -E 's/^  id: ([a-z0-9-]+)$/\1/p' "$PROJECT_ROOT/src/steps-common/${step}.yaml")"
      done
      if [[ " ${ids} " != *" manifest-package "* ]]; then
        echo "${workflow##*/}: injects ${reader} but no step with id manifest-package" >&3
        failures=$((failures + 1))
      fi
    done
  done
  [[ "${failures}" -eq 0 ]]
}

