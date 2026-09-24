#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for lib/env-deploy-base-image-compose.bash.

load helpers

# shellcheck source=src/scripts/lib/env-deploy-base-image-compose.bash
source "${LIB_DIR}/env-deploy-base-image-compose.bash"

teardown() {
  dump_bats_result
}

# =============================================================================
# Happy path: full args with namespace
# =============================================================================

@test "composes full reference with namespace" {
  run env_deploy_base_image_compose ghcr.io kube-kaptain alpine 1.0.14.1.34.1
  [ "${status}" -eq 0 ]
  [ "${output}" = "ghcr.io/kube-kaptain/image/image-environment-deploy-alpine:1.0.14.1.34.1" ]
}

@test "composes reference without namespace (empty namespace omits segment)" {
  run env_deploy_base_image_compose docker.io "" trixie-slim 2.0.0
  [ "${status}" -eq 0 ]
  [ "${output}" = "docker.io/image/image-environment-deploy-trixie-slim:2.0.0" ]
}

@test "alternate registry with namespace" {
  run env_deploy_base_image_compose quay.io my-org bookworm-slim 9.9.9
  [ "${status}" -eq 0 ]
  [ "${output}" = "quay.io/my-org/image/image-environment-deploy-bookworm-slim:9.9.9" ]
}

# =============================================================================
# Required-arg validation
# =============================================================================

@test "rejects missing registry" {
  run env_deploy_base_image_compose "" kube-kaptain trixie-slim 1.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"registry is required"* ]]
}

@test "rejects missing family" {
  run env_deploy_base_image_compose ghcr.io kube-kaptain "" 1.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"family is required"* ]]
}

@test "rejects missing version" {
  run env_deploy_base_image_compose ghcr.io kube-kaptain trixie-slim ""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"version is required"* ]]
}

# =============================================================================
# Format validation
# =============================================================================

@test "rejects registry containing slash" {
  run env_deploy_base_image_compose ghcr.io/extra kube-kaptain trixie-slim 1.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"registry must not contain"* ]]
}

@test "rejects namespace containing slash" {
  run env_deploy_base_image_compose ghcr.io kube/kaptain trixie-slim 1.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"namespace must not contain"* ]]
}

@test "rejects family containing slash" {
  run env_deploy_base_image_compose ghcr.io kube-kaptain trixie/slim 1.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"family must not contain"* ]]
}

@test "rejects family containing colon" {
  run env_deploy_base_image_compose ghcr.io kube-kaptain trixie:slim 1.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"family must not contain"* ]]
}

@test "rejects version containing slash" {
  run env_deploy_base_image_compose ghcr.io kube-kaptain trixie-slim 1.0/0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"version must not contain"* ]]
}

@test "rejects version containing colon" {
  run env_deploy_base_image_compose ghcr.io kube-kaptain trixie-slim 1.0:0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"version must not contain"* ]]
}
