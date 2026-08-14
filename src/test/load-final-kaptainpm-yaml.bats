#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/load-final-kaptainpm-yaml"

setup() {
  local base_dir
  base_dir=$(create_test_dir "load-final-kaptainpm-yaml")
  export TEST_DIR="${base_dir}"

  # Script expects kaptainpm/final/KaptainPM.yaml relative to cwd
  mkdir -p "${TEST_DIR}/kaptainpm/final"

  # Capture outputs via GITHUB_OUTPUT
  export GITHUB_OUTPUT="${TEST_DIR}/github-output"
  touch "${GITHUB_OUTPUT}"

  export BUILD_KIND="test-build"
  unset REFERENCE_SCRIPT_OUTPUT 2>/dev/null || true

  # Platform registry/namespace defaults - always present in reality (GH:
  # registry-defaults step, local: detect-build-context). Individual tests
  # unset these to exercise the no-default platform paths.
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE="kube-kaptain"
}

# Write a minimal valid KaptainPM.yaml with the given kind
write_pm() {
  local kind="${1:-test-build}"
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << EOF
apiVersion: kaptain.org/1.10
kind: ${kind}
EOF
}

run_script() {
  run bash -c "cd '${TEST_DIR}' && GITHUB_OUTPUT='${GITHUB_OUTPUT}' '${SCRIPT}'"
}

# Read a value from GITHUB_OUTPUT
github_output_value() {
  grep "^${1}=" "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-
}

# Assert a value in GITHUB_OUTPUT
assert_github_output() {
  local name="${1}"
  local expected="${2}"
  local actual
  actual=$(github_output_value "${name}")
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Expected ${name}=${expected}"
    echo "Actual ${name}=${actual}"
    return 1
  fi
}

# =============================================================================
# Kind validation
# =============================================================================

@test "fails when BUILD_KIND not set" {
  write_pm
  unset BUILD_KIND
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "BUILD_KIND is required"
}

@test "fails when KaptainPM.yaml is missing" {
  rm -rf "${TEST_DIR}/kaptainpm"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Project manifest not found"
}

@test "fails when kind is missing from yaml" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
EOF
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "does not declare a kind"
}

@test "fails when kind does not match BUILD_KIND" {
  write_pm "wrong-kind"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Kind mismatch"
}

@test "succeeds when kind matches BUILD_KIND" {
  write_pm "test-build"
  run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Kind matched: test-build"
}

# =============================================================================
# Default-when-absent fields
# =============================================================================

@test "OUTPUT_SUB_PATH defaults to kaptain-out when absent" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "OUTPUT_SUB_PATH" "kaptain-out"
}

@test "OUTPUT_SUB_PATH uses value from yaml when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    outputSubPath: custom-out
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "OUTPUT_SUB_PATH" "custom-out"
}

# The fallback comes from defaults/output-sub-path.bash, which is env
# overridable by design, so a wrapper supplied value is honoured when the yaml
# is silent - but never over an explicit yaml value.
@test "OUTPUT_SUB_PATH honours incoming env when yaml absent" {
  write_pm
  export OUTPUT_SUB_PATH="wrapper-out"
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "OUTPUT_SUB_PATH" "wrapper-out"
}

@test "OUTPUT_SUB_PATH from yaml wins over incoming env" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    outputSubPath: custom-out
EOF
  export OUTPUT_SUB_PATH="wrapper-out"
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "OUTPUT_SUB_PATH" "custom-out"
}

@test "GITHUB_RELEASE_ENABLED honours incoming env when yaml absent" {
  write_pm
  export GITHUB_RELEASE_ENABLED="false"
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "GITHUB_RELEASE_ENABLED" "false"
}

@test "GITHUB_RELEASE_ENABLED defaults to true when absent" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "GITHUB_RELEASE_ENABLED" "true"
}

@test "GITHUB_RELEASE_ENABLED uses string value from yaml when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  platform:
    githubActions:
      release:
        enabled: "false"
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "GITHUB_RELEASE_ENABLED" "false"
}

# NOTE: yq's // operator treats bare boolean false as falsy, so the script
# falls back to the default "true". This is a known quirk - use the string
# "false" in KaptainPM.yaml to disable releases.
@test "GITHUB_RELEASE_ENABLED bare boolean false falls back to default true" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  platform:
    githubActions:
      release:
        enabled: false
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "GITHUB_RELEASE_ENABLED" "true"
}

@test "CHANGE_SOURCE_NOTE_ENABLED defaults to true when absent" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "CHANGE_SOURCE_NOTE_ENABLED" "true"
}

@test "CHANGE_SOURCE_NOTE_ENABLED uses string value from yaml when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    changeSource:
      noteEnabled: "false"
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "CHANGE_SOURCE_NOTE_ENABLED" "false"
}

# Read via kaptainpm_bool, not yq's // operator, so an explicit bare boolean
# false survives instead of being clobbered by the default.
@test "CHANGE_SOURCE_NOTE_ENABLED bare boolean false is preserved" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    changeSource:
      noteEnabled: false
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "CHANGE_SOURCE_NOTE_ENABLED" "false"
}

@test "KUBERNETES_WORKLOAD_TYPE defaults to deployment when absent" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "KUBERNETES_WORKLOAD_TYPE" "deployment"
}

@test "KUBERNETES_WORKLOAD_TYPE uses value from yaml when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    generators:
      workload:
        type: statefulset
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "KUBERNETES_WORKLOAD_TYPE" "statefulset"
}

@test "KUBERNETES_CONFIGMAP_SUB_PATH defaults to src/configmap when absent" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "KUBERNETES_CONFIGMAP_SUB_PATH" "src/configmap"
}

@test "KUBERNETES_SECRET_TEMPLATE_SUB_PATH defaults to src/secret.template when absent" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "KUBERNETES_SECRET_TEMPLATE_SUB_PATH" "src/secret.template"
}

# =============================================================================
# JSON extraction fields
# =============================================================================

@test "DOCKER_REGISTRY_LOGINS exported as JSON when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    docker:
      logins:
        - registry: ghcr.io
          username: user
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "DOCKER_REGISTRY_LOGINS"
  local value
  value=$(github_output_value "DOCKER_REGISTRY_LOGINS")
  [[ -n "${value}" ]] || return 1
  [[ "${value}" == *"ghcr.io"* ]] || return 1
}

@test "DOCKER_REGISTRY_LOGINS not exported when absent" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_output_not_contains "DOCKER_REGISTRY_LOGINS"
}

@test "VENDOR_HELM_RENDERED_MOVE_FILES exported as JSON when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    vendorHelmRendered:
      moveFiles:
        - from: a.yaml
          to: b.yaml
EOF
  run_script
  [ "${status}" -eq 0 ]
  local value
  value=$(github_output_value "VENDOR_HELM_RENDERED_MOVE_FILES")
  [[ -n "${value}" ]] || return 1
  [[ "${value}" == *"a.yaml"* ]] || return 1
}

@test "VENDOR_HELM_RENDERED_SED_REPLACE exported as JSON when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    vendorHelmRendered:
      sedReplace:
        - pattern: foo
          replacement: bar
          file: test.yaml
EOF
  run_script
  [ "${status}" -eq 0 ]
  local value
  value=$(github_output_value "VENDOR_HELM_RENDERED_SED_REPLACE")
  [[ -n "${value}" ]] || return 1
  [[ "${value}" == *"foo"* ]] || return 1
}

@test "VENDOR_HELM_RENDERED_YQ_TRANSFORM exported as JSON when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    vendorHelmRendered:
      yqTransform:
        - expression: ".foo = \"bar\""
          file: test.yaml
EOF
  run_script
  [ "${status}" -eq 0 ]
  local value
  value=$(github_output_value "VENDOR_HELM_RENDERED_YQ_TRANSFORM")
  [[ -n "${value}" ]] || return 1
}

@test "VENDOR_HELM_RENDERED_IMAGE_RETAGS exported as JSON when present" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    vendorHelmRendered:
      imageRetags:
        - sourceImage: foo:1.0
          targetImage: bar:1.0
EOF
  run_script
  [ "${status}" -eq 0 ]
  local value
  value=$(github_output_value "VENDOR_HELM_RENDERED_IMAGE_RETAGS")
  [[ -n "${value}" ]] || return 1
  [[ "${value}" == *"foo:1.0"* ]] || return 1
}

# =============================================================================
# Mapping loop - spot check a few fields
# =============================================================================

@test "exports TOKEN_DELIMITER_STYLE from yaml" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    tokens:
      delimiterStyle: "@@"
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "TOKEN_DELIMITER_STYLE" "@@"
}

@test "exports DOCKER_PLATFORM from yaml" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    docker:
      platform: linux/amd64,linux/arm64
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "DOCKER_PLATFORM" "linux/amd64,linux/arm64"
}

@test "exports LAYER_TOKEN_SUBSTITUTION string false from yaml" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    layer:
      tokenSubstitution: "false"
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "LAYER_TOKEN_SUBSTITUTION" "false"
}

@test "exports LAYER_TOKEN_SUBSTITUTION bare boolean false from yaml" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    layer:
      tokenSubstitution: false
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "LAYER_TOKEN_SUBSTITUTION" "false"
}

@test "exports LAYER_PACKAGING_BASE_IMAGE from yaml" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    layer:
      packagingBaseImage: alpine:3.19
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "LAYER_PACKAGING_BASE_IMAGE" "alpine:3.19"
}

# =============================================================================
# Target registry/namespace resolution (authoritative - no later resolve step)
# =============================================================================

@test "registry/namespace: spec values win over platform defaults" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    docker:
      targetRegistry: quay.io
      targetNamespace: my-ns
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "DOCKER_TARGET_REGISTRY" "quay.io"
  assert_github_output "DOCKER_TARGET_NAMESPACE" "my-ns"
}

@test "registry/namespace: platform defaults used when spec absent, always emitted" {
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "DOCKER_TARGET_REGISTRY" "ghcr.io"
  assert_github_output "DOCKER_TARGET_NAMESPACE" "kube-kaptain"
}

@test "targetIncludeNamespace=false: namespace emitted empty despite platform default" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    docker:
      targetIncludeNamespace: false
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "DOCKER_TARGET_NAMESPACE" ""
  [[ "$output" == *"targetIncludeNamespace=false"* ]] || return 1
}

@test "no registry anywhere: fails for normal build kinds" {
  unset DOCKER_TARGET_REGISTRY
  write_pm
  run_script
  [ "${status}" -ne 0 ]
  [[ "$output" == *"No target registry configured and the platform provides no default"* ]] || return 1
}

@test "no registry anywhere: allowed for basic-quality-checks" {
  unset DOCKER_TARGET_REGISTRY
  export BUILD_KIND="basic-quality-checks"
  write_pm "basic-quality-checks"
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "DOCKER_TARGET_REGISTRY" ""
  [[ "$output" == *"not required for basic-quality-checks"* ]] || return 1
}

@test "no registry anywhere: allowed when targetAllowNoRegistry is true" {
  unset DOCKER_TARGET_REGISTRY
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    docker:
      targetAllowNoRegistry: true
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "DOCKER_TARGET_REGISTRY" ""
  [[ "$output" == *"exempted by targetAllowNoRegistry"* ]] || return 1
}

# =============================================================================
# Release branch set: incoming presence wins over file config
# =============================================================================

@test "incoming RELEASE_BRANCH trusted, file release config ignored, additional cleared" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'YAML'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    release:
      branch: trunk
      additionalBranches: main-1.34,main-1.35
YAML
  export RELEASE_BRANCH="origin/main"
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "RELEASE_BRANCH" "origin/main"
  assert_github_output "ADDITIONAL_RELEASE_BRANCHES" ""
  [[ "$output" == *"file release config ignored"* ]] || return 1
}

@test "no incoming RELEASE_BRANCH: file config applies including additional branches" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'YAML'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    release:
      branch: trunk
      additionalBranches: main-1.34
YAML
  unset RELEASE_BRANCH 2>/dev/null || true
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "RELEASE_BRANCH" "trunk"
  assert_github_output "ADDITIONAL_RELEASE_BRANCHES" "main-1.34"
}

@test "no incoming RELEASE_BRANCH and no file config: defaults to main" {
  write_pm
  unset RELEASE_BRANCH 2>/dev/null || true
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "RELEASE_BRANCH" "main"
}

# =============================================================================
# Kaptain knob guards
# =============================================================================

@test "KAPTAIN_LOCAL_RELEASE with BUILD_MODE!=local is a hard error" {
  write_pm
  export KAPTAIN_LOCAL_RELEASE=true
  export BUILD_MODE=build_server
  run_script
  [ "${status}" -ne 0 ]
  [[ "$output" == *"requires BUILD_MODE=local"* ]] || return 1
}

@test "KAPTAIN_LOCAL_RELEASE with KAPTAIN_BRANCH_OVERRIDE is a hard error" {
  write_pm
  export KAPTAIN_LOCAL_RELEASE=true
  export BUILD_MODE=local
  export KAPTAIN_BRANCH_OVERRIDE=main-1.34
  run_script
  [ "${status}" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]] || return 1
}

@test "exports TOKEN_BUILTIN_MODE from yaml on a permitted kind" {
  export BUILD_KIND="kubernetes-bundle-resources"
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: kubernetes-bundle-resources
spec:
  global:
    tokens:
      builtinMode: template
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "TOKEN_BUILTIN_MODE" "template"
}

@test "TOKEN_BUILTIN_MODE template is rejected on a kind outside the whitelist" {
  export BUILD_KIND="kubernetes-app-docker-dockerfile"
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: kubernetes-app-docker-dockerfile
spec:
  global:
    tokens:
      builtinMode: template
EOF
  run_script
  [ "${status}" -ne 0 ]
  [[ "$output" == *"builtinMode: template is not valid for kind"* ]] || return 1
}

@test "TOKEN_BUILTIN_MODE standard is accepted on any kind" {
  export BUILD_KIND="kubernetes-app-docker-dockerfile"
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: kubernetes-app-docker-dockerfile
spec:
  global:
    tokens:
      builtinMode: standard
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "TOKEN_BUILTIN_MODE" "standard"
}

teardown() {
  dump_bats_result
}
