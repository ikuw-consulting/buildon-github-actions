#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/kubernetes-run-image-deploy-manifests - staging and
# fill-the-gaps generation of the env deploy-manifests set: the Secret with
# the environmentPassphrase key, the deploy workload settings, the
# ClusterRoleBinding name, and the Environment-token guard.

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/kubernetes-run-image-deploy-manifests"

setup() {
  TEST_DIR=$(create_test_dir "kubernetes-run-image-deploy-manifests")
  mkdir -p "${TEST_DIR}/kaptainpm/final"
  printf 'apiVersion: kaptain.org/1.2\nkind: kubernetes-run-environment\n' \
    > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml"
  export GITHUB_OUTPUT="${TEST_DIR}/github-output"
  : > "${GITHUB_OUTPUT}"
  export BUILD_PLATFORM="local"
  export PROJECT_NAME="run-foo"
  export VERSION="1.0.0"
  export OUTPUT_SUB_PATH="kaptain-out"
  cd "${TEST_DIR}"
}

teardown() {
  dump_bats_result
}

MANIFESTS="kaptain-out/run-image-deploy-manifests/manifests"
DEFAULTS="kaptain-out/run-image-deploy-manifests/defaults"

# =============================================================================
# Secret
# =============================================================================

@test "secret: generated with a project-prefixed environmentPassphrase token" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq '.stringData.environmentPassphrase' "${MANIFESTS}/secret.template.yaml")" = '${RunFoo/EnvironmentPassphrase}' ]
}

@test "secret: the token follows the configured name style" {
  TOKEN_NAME_STYLE=UPPER_SNAKE run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq '.stringData.environmentPassphrase' "${MANIFESTS}/secret.template.yaml")" = '${RUN_FOO/ENVIRONMENT_PASSPHRASE}' ]
}

@test "secret: user secret.template entries are kept alongside the passphrase" {
  mkdir -p src/environment/secret.template
  printf '%s' 'x' > src/environment/secret.template/apiKey
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq '.stringData.apiKey' "${MANIFESTS}/secret.template.yaml")" = "x" ]
  [ "$(yq '.stringData.environmentPassphrase' "${MANIFESTS}/secret.template.yaml")" = '${RunFoo/EnvironmentPassphrase}' ]
}

@test "secret: a user-supplied environmentPassphrase entry is not overwritten" {
  mkdir -p src/environment/secret.template
  printf '%s' 'mine' > src/environment/secret.template/environmentPassphrase
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq '.stringData.environmentPassphrase' "${MANIFESTS}/secret.template.yaml")" = "mine" ]
}

@test "secret: a supplied Secret manifest without environmentPassphrase fails" {
  mkdir -p src/environment/kubernetes
  cat > src/environment/kubernetes/secret.template.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: run-foo-secret-checksum
stringData:
  other: x
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "has no stringData.environmentPassphrase key"
}

@test "secret: a supplied Secret manifest with environmentPassphrase passes" {
  mkdir -p src/environment/kubernetes
  cat > src/environment/kubernetes/secret.template.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: run-foo-secret-checksum
stringData:
  environmentPassphrase: x
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# =============================================================================
# Deploy workload
# =============================================================================

@test "deployment: runs /kd/bin/deploy with the deploy pod settings" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local spec='.spec.template.spec'
  local d="${MANIFESTS}/deployment.yaml"
  [ "$(yq "${spec}.containers[0].command[0]" "$d")" = "/kd/bin/deploy" ]
  [ "$(yq "${spec}.automountServiceAccountToken" "$d")" = "true" ]
  [ "$(yq "${spec}.terminationGracePeriodSeconds" "$d")" = "86400" ]
  [ "$(yq "${spec}.containers[0].securityContext.readOnlyRootFilesystem" "$d")" = "false" ]
  [ "$(yq "${spec}.containers[0] | has(\"ports\")" "$d")" = "false" ]
}

@test "deployment: memory and cpu request are project-prefixed tokens, no cpu limit" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local r='.spec.template.spec.containers[0].resources'
  local d="${MANIFESTS}/deployment.yaml"
  [ "$(yq "${r}.requests.memory" "$d")" = '${RunFoo/Memory}' ]
  [ "$(yq "${r}.limits.memory" "$d")" = '${RunFoo/Memory}' ]
  [ "$(yq "${r}.requests.cpu" "$d")" = '${RunFoo/CpuRequest}' ]
  [ "$(yq "${r}.limits | has(\"cpu\")" "$d")" = "false" ]
}

@test "defaults: Memory 100Mi and CpuRequest 10m are written" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "${DEFAULTS}/RunFoo/Memory")" = "100Mi" ]
  [ "$(cat "${DEFAULTS}/RunFoo/CpuRequest")" = "10m" ]
}

@test "defaults: a user-supplied Memory default is not overwritten" {
  mkdir -p src/environment/defaults/RunFoo
  printf '%s' '256Mi' > src/environment/defaults/RunFoo/Memory
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "${DEFAULTS}/RunFoo/Memory")" = "256Mi" ]
}

@test "cronjob: job mode runs /kd/bin/deploy with the deploy pod settings" {
  ENV_DEPLOY_MODE=job ENV_IMAGE_AUTO_UPDATE_PROVIDER=keelson run "$SCRIPT"
  [ "$status" -eq 0 ]
  local spec='.spec.jobTemplate.spec.template.spec'
  local c="${MANIFESTS}/cronjob.yaml"
  [ "$(yq "${spec}.containers[0].command[0]" "$c")" = "/kd/bin/deploy" ]
  [ "$(yq "${spec}.automountServiceAccountToken" "$c")" = "true" ]
  [ "$(yq "${spec}.terminationGracePeriodSeconds" "$c")" = "86400" ]
  [ "$(yq "${spec}.containers[0].securityContext.readOnlyRootFilesystem" "$c")" = "false" ]
  [ "$(yq "${spec}.containers[0] | has(\"ports\")" "$c")" = "false" ]
  [ "$(yq "${spec}.containers[0].resources.requests.memory" "$c")" = '${RunFoo/Memory}' ]
}

# =============================================================================
# RBAC
# =============================================================================

@test "rbac: ClusterRoleBinding name leads with the Environment token" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq '.metadata.name' "${MANIFESTS}/clusterrolebinding.yaml")" = '${Environment}.${ProjectName}-cluster-admin' ]
}

@test "rbac: ClusterRoleBinding subject is the ServiceAccount in the Environment namespace" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq '.subjects[0].namespace' "${MANIFESTS}/clusterrolebinding.yaml")" = '${Environment}' ]
  [ "$(yq '.metadata.namespace' "${MANIFESTS}/serviceaccount.yaml")" = '${Environment}' ]
}

@test "rbac: parent delegation RoleBinding lives in and binds the Environment namespace" {
  ENV_CLUSTER_SCOPED_DELEGATION=parent run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq '.metadata.namespace' "${MANIFESTS}/rolebinding.yaml")" = '${Environment}' ]
  [ "$(yq '.subjects[0].namespace' "${MANIFESTS}/rolebinding.yaml")" = '${Environment}' ]
}

# =============================================================================
# Not part of a product
# =============================================================================

@test "product: no product labels or ProductName token in deployment mode" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -rlE 'part-of|kaptain.org/product|ProductName' "${MANIFESTS}" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "product: no product labels or ProductName token in job mode" {
  ENV_DEPLOY_MODE=job ENV_IMAGE_AUTO_UPDATE_PROVIDER=keelson run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -rlE 'part-of|kaptain.org/product|ProductName' "${MANIFESTS}" | wc -l | tr -d ' ')" -eq 0 ]
}

# =============================================================================
# Job mode zero-scale Deployment
# =============================================================================

@test "job mode: zero-scale Deployment shares base name, ServiceAccount and Secret, sleeps" {
  ENV_DEPLOY_MODE=job ENV_IMAGE_AUTO_UPDATE_PROVIDER=keelson run "$SCRIPT"
  [ "$status" -eq 0 ]
  local d="${MANIFESTS}/deployment.yaml"
  local spec='.spec.template.spec'
  [ ! -f "${MANIFESTS}/deployment-debug.yaml" ]
  [ "$(yq '.metadata.name' "$d")" = "$(yq '.metadata.name' "${MANIFESTS}/cronjob.yaml")" ]
  [ "$(yq '.spec.replicas' "$d")" = "0" ]
  [ "$(yq "${spec}.containers[0].command | join(\" \")" "$d")" = "sleep infinity" ]
  [ "$(yq "${spec}.serviceAccountName" "$d")" = '${ProjectName}' ]
  [ "$(yq "${spec}.volumes[] | select(.name == \"secret\") | .secret.secretName" "$d")" = \
    "$(yq '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "secret") | .secret.secretName' "${MANIFESTS}/cronjob.yaml")" ]
}

# =============================================================================
# Environment token guard
# =============================================================================

@test "guard: an Environment value in the deploy-image config fails" {
  mkdir -p src/environment/config
  printf '%s' 'prod' > src/environment/config/Environment
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "the Environment token is supplied by whatever applies this set"
}

@test "guard: an EnvironmentShortName value in the deploy-image defaults fails" {
  mkdir -p src/environment/defaults
  printf '%s' 'prod' > src/environment/defaults/EnvironmentShortName
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "the EnvironmentShortName token is supplied by whatever applies this set"
}
