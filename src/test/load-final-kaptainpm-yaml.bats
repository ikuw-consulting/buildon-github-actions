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
  # Always present in reality: validate-tooling runs first and sets it
  export IMAGE_BUILD_COMMAND="docker"
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

@test "publishes the checked kind as BUILD_KIND" {
  write_pm "test-build"
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "BUILD_KIND" "test-build"
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

# Read via kaptainpm_bool, not yq's // operator, so an explicit bare boolean
# false survives instead of being clobbered by the default.
@test "GITHUB_RELEASE_ENABLED bare boolean false is preserved" {
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
  assert_github_output "GITHUB_RELEASE_ENABLED" "false"
}

# Booleans read through the generic field mappings are lowercased, so an
# uppercase YAML boolean reaches the generators as true/false.
@test "uppercase YAML boolean through the field mappings is exported lowercase" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    generators:
      service:
        enabled: TRUE
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "KUBERNETES_SERVICE_GENERATION_ENABLED" "true"
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

@test "ENV_IMAGE_PULL_SECRETS uses spec.main.environment.imagePullSecrets" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    environment:
      imagePullSecrets: DISABLED
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "ENV_IMAGE_PULL_SECRETS" "DISABLED"
}

@test "ENV_JOB_POST_DEPLOY_SLEEP_* use the spec.main.environment job sleeps" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    environment:
      deployMode: job
      jobPostDeploySleepAfterSuccess: 5m
      jobPostDeploySleepAfterFailure: 2d
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "ENV_JOB_POST_DEPLOY_SLEEP_AFTER_SUCCESS" "5m"
  assert_github_output "ENV_JOB_POST_DEPLOY_SLEEP_AFTER_FAILURE" "2d"
}

@test "ENV_JOB_POST_DEPLOY_SLEEP_AFTER_SUCCESS takes bare integer seconds" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    environment:
      deployMode: job
      jobPostDeploySleepAfterSuccess: 600
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "ENV_JOB_POST_DEPLOY_SLEEP_AFTER_SUCCESS" "600"
}

@test "ENV_AUTO_GENERATE_IMAGE_PULL_SECRETS takes a bare boolean false" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    environment:
      autoGenerateImagePullSecrets: false
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "ENV_AUTO_GENERATE_IMAGE_PULL_SECRETS" "false"
}

@test "ENV_NAMESPACE_ADDITIONAL_* use spec.main.environment.namespace" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    environment:
      namespace:
        additionalLabels: 'tier=platform'
        additionalAnnotations: 'owner=platform-team'
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "ENV_NAMESPACE_ADDITIONAL_LABELS" "tier=platform"
  assert_github_output "ENV_NAMESPACE_ADDITIONAL_ANNOTATIONS" "owner=platform-team"
}

@test "KUBERNETES_NAMESPACE_* use spec.main.generators.namespace, name kept as written" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    generators:
      namespace:
        enabled: true
        name: '${Environment}'
        combinedSubPath: extra
        additionalLabels: 'tier=tools'
        additionalAnnotations: 'owner=platform-team'
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "KUBERNETES_NAMESPACE_GENERATION_ENABLED" "true"
  assert_github_output "KUBERNETES_NAMESPACE_NAME" '${Environment}'
  assert_github_output "KUBERNETES_NAMESPACE_COMBINED_SUB_PATH" "extra"
  assert_github_output "KUBERNETES_NAMESPACE_ADDITIONAL_LABELS" "tier=tools"
  assert_github_output "KUBERNETES_NAMESPACE_ADDITIONAL_ANNOTATIONS" "owner=platform-team"
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

@test "exports GITHUB_RELEASE_RAW_FILES from yaml" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  platform:
    githubActions:
      release:
        rawFiles: dist/notes-VERSION.md,dist/sums-VERSION.txt
EOF
  run_script
  [ "${status}" -eq 0 ]
  assert_github_output "GITHUB_RELEASE_RAW_FILES" "dist/notes-VERSION.md,dist/sums-VERSION.txt"
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

# =============================================================================
# Deferred builtin token replay
# =============================================================================

# append_scalar <NAME> <VALUE> [output-sub-path]
append_scalar() {
  local out="${3:-kaptain-out}"
  mkdir -p "${TEST_DIR}/${out}"
  printf 'scalar\0%s\0%s\0' "$1" "$2" >> "${TEST_DIR}/${out}/builtin-tokens-pending"
}

# append_entry <entry> <version> <subdir> <manifests-docker-tag> [digest]
append_entry() {
  mkdir -p "${TEST_DIR}/kaptain-out"
  printf 'entry\0%s\0%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4" "${5:-}" \
    >> "${TEST_DIR}/kaptain-out/builtin-tokens-pending"
}

# token_file <subdir/name> [output-sub-path]
token_file() {
  echo "${TEST_DIR}/${2:-kaptain-out}/builtin-resolved-tokens/${1}"
}

@test "deferred scalars replay in UPPER_SNAKE when the style resolves to it" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    tokens:
      nameStyle: UPPER_SNAKE
EOF
  append_scalar BUILD_TIMESTAMP "2026-06-17T14:32:15Z"
  append_scalar GIT_BRANCH      "main"

  run_script
  [ "${status}" -eq 0 ]
  [ "$(cat "$(token_file build/BUILD_TIMESTAMP)")" = "2026-06-17T14:32:15Z" ]
  [ "$(cat "$(token_file git/GIT_BRANCH)")" = "main" ]
}

@test "deferred scalars replay in PascalCase when the style is defaulted" {
  write_pm
  append_scalar BUILD_TIMESTAMP     "2026-06-17T14:32:15Z"
  append_scalar IMAGE_BUILD_COMMAND "docker"

  run_script
  [ "${status}" -eq 0 ]
  [ "$(cat "$(token_file build/BuildTimestamp)")" = "2026-06-17T14:32:15Z" ]
  [ "$(cat "$(token_file image/ImageBuildCommand)")" = "docker" ]
  [ ! -f "$(token_file build/BUILD_TIMESTAMP)" ]
}

@test "pending file is removed once replayed" {
  write_pm
  append_scalar BUILD_MODE "build_server"

  run_script
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_DIR}/kaptain-out/builtin-tokens-pending" ]
}

@test "replay preserves values verbatim, including multi-line and no trailing newline" {
  write_pm
  append_scalar KAPTAINPM_METADATA_DESCRIPTION "first line
second line"
  append_scalar BUILD_MODE "local"

  run_script
  [ "${status}" -eq 0 ]
  [ "$(cat "$(token_file kaptainpm/KaptainpmMetadataDescription)")" = "first line
second line" ]
  [ "$(wc -c < "$(token_file build/BuildMode)" | tr -d ' ')" = "5" ]
}

@test "deferred layer entry replays into the full four-file set" {
  write_pm
  append_entry "ghcr.io/kube-kaptain/layer-github-flow-strict:1.2.3" "1.2.3" layers "1.2.3"

  run_script
  [ "${status}" -eq 0 ]
  local base="layers/LayerGhcrIoKubeKaptainLayerGithubFlowStrict"
  [ "$(cat "$(token_file "${base}Ref")")" = "ghcr.io/kube-kaptain/layer-github-flow-strict:1.2.3" ]
  [ "$(cat "$(token_file "${base}VersionSpec")")" = "1.2.3" ]
  [ "$(cat "$(token_file "${base}Version")")" = "1.2.3" ]
  [ "$(cat "$(token_file "${base}ManifestsDockerTag")")" = "1.2.3" ]
}

@test "deferred layer entry honours the resolved name style" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    tokens:
      nameStyle: UPPER_SNAKE
EOF
  append_entry "layer-github-flow-strict:1.2.3" "1.2.3" layers "1.2.3"

  run_script
  [ "${status}" -eq 0 ]
  [ "$(cat "$(token_file layers/LAYER_LAYER_GITHUB_FLOW_STRICT_REF)")" = "layer-github-flow-strict:1.2.3" ]
}

@test "replay merges into an existing builtin-resolved-tokens dir" {
  write_pm
  mkdir -p "${TEST_DIR}/kaptain-out/builtin-resolved-tokens/repository"
  printf '%s' "my-repo" > "${TEST_DIR}/kaptain-out/builtin-resolved-tokens/repository/RepositoryName"
  append_scalar BUILD_MODE "build_server"

  run_script
  [ "${status}" -eq 0 ]
  [ "$(cat "$(token_file repository/RepositoryName)")" = "my-repo" ]
  [ "$(cat "$(token_file build/BuildMode)")" = "build_server" ]
}

@test "replay finds tokens kaptain-init deferred before a custom outputSubPath was known" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    outputSubPath: custom-out
EOF
  # kaptain-init runs before the configured dir is known, so it records into
  # the dir the build started with
  append_scalar BUILD_MODE "build_server"

  run_script
  [[ "${status}" -eq 0 ]] || return 1
  [[ "$(cat "$(token_file build/BuildMode custom-out)")" == "build_server" ]] || return 1
}

@test "no pending file is a silent no-op" {
  write_pm

  run_script
  [ "${status}" -eq 0 ]
  [ ! -d "${TEST_DIR}/kaptain-out/builtin-resolved-tokens" ]
}

@test "unknown record type fails the build" {
  write_pm
  mkdir -p "${TEST_DIR}/kaptain-out"
  printf 'bogus\0X\0Y\0' > "${TEST_DIR}/kaptain-out/builtin-tokens-pending"

  run_script
  [ "${status}" -ne 0 ]
  [[ "$output" == *"Unknown deferred builtin token record type"* ]]
}

teardown() {
  dump_bats_result
}

# =============================================================================
# Ambiguous numbers: only plain decimal integers are accepted
# =============================================================================

@test "a leading-zero number fails with its path and the ambiguity message" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF2'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    generators:
      deployment:
        replicas: 017
EOF2
  run_script
  [[ "$status" -eq 1 ]] || return 1
  [[ "$output" == *"spec.main.generators.deployment.replicas: 017 is ambiguous depending on the YAML specification version and could mean more than one value depending on the context. Use decimal."* ]] || return 1
}

@test "every non-decimal number form is reported, including inside lists" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF2'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  forms:
    octal: 0o17
    hex: 0x10
    binary: 0b101
    underscore: 1_000
    plus: +5
    fraction: 3.0
    exponent: 1e2
    nonOctal: 08
    ports:
      - port: 080
EOF2
  run_script
  [[ "$status" -eq 1 ]] || return 1
  local form
  for form in "octal: 0o17" "hex: 0x10" "binary: 0b101" "underscore: 1_000" "plus: +5" \
      "fraction: 3.0" "exponent: 1e2" "nonOctal: 08" "ports.0.port: 080"; do
    [[ "$output" == *"spec.forms.${form} is ambiguous"* ]] || return 1
  done
}

@test "plain decimal numbers and quoted strings are not ambiguous" {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF2'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  forms:
    zero: 0
    plain: 17
    negative: -3
    quoted: "017"
    version: "1.0"
EOF2
  run_script
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" != *"is ambiguous"* ]] || return 1
}

# =============================================================================
# docker.runtime: applied on local builds only, and only if installed
# =============================================================================

# Export a PATH with every tool except podman and docker, then mocks of only
# the named runtimes, so a test decides what is installed whatever the host has.
# Usage: path_with_runtimes [runtime...]
path_with_runtimes() {
  local farm="${TEST_DIR}/path-farm" mocks="${TEST_DIR}/path-mocks" dirs i runtime
  mkdir -p "${farm}" "${mocks}"
  IFS=: read -ra dirs <<< "${PATH}"
  # Later dirs first, so earlier ones win as they do in a PATH lookup
  for ((i = ${#dirs[@]} - 1; i >= 0; i--)); do
    [[ -d "${dirs[i]}" ]] && ln -sf "${dirs[i]}"/* "${farm}/" 2> /dev/null
  done
  rm -f "${farm}/podman" "${farm}/docker"
  for runtime in "$@"; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${mocks}/${runtime}"
    chmod +x "${mocks}/${runtime}"
  done
  export PATH="${mocks}:${farm}"
}

write_pm_runtime() {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << EOF2
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    docker:
      runtime: ${1}
EOF2
}

@test "runtime: locally an installed runtime becomes IMAGE_BUILD_COMMAND" {
  export BUILD_MODE="local"
  write_pm_runtime docker
  path_with_runtimes podman docker

  run_script
  [[ "$status" -eq 0 ]] || return 1
  assert_github_output "IMAGE_BUILD_COMMAND" "docker"
}

@test "runtime: locally podman is honoured too" {
  export BUILD_MODE="local"
  write_pm_runtime podman
  path_with_runtimes podman

  run_script
  [[ "$status" -eq 0 ]] || return 1
  assert_github_output "IMAGE_BUILD_COMMAND" "podman"
}

@test "runtime: locally a runtime that is not installed fails" {
  export BUILD_MODE="local"
  write_pm_runtime docker
  path_with_runtimes podman

  run_script
  [[ "$status" -eq 1 ]] || return 1
  [[ "$output" == *"spec.main.docker.runtime is docker but docker is not installed"* ]] || return 1
  [[ -z "$(github_output_value IMAGE_BUILD_COMMAND)" ]] || return 1
}

@test "runtime: locally a value other than podman or docker fails" {
  export BUILD_MODE="local"
  write_pm_runtime rm

  run_script
  [[ "$status" -eq 1 ]] || return 1
  [[ "$output" == *"spec.main.docker.runtime must be podman or docker, got: rm"* ]] || return 1
}

@test "runtime: on a build server it is ignored and logged, even if not installed" {
  export BUILD_MODE="build_server"
  write_pm_runtime docker
  path_with_runtimes podman

  run_script
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *'Field .spec.main.docker.runtime = "docker" ignored: a build server always uses podman'* ]] || return 1
  [[ -z "$(github_output_value IMAGE_BUILD_COMMAND)" ]] || return 1
}

@test "runtime: unset leaves IMAGE_BUILD_COMMAND to validate-tooling" {
  export BUILD_MODE="local"
  write_pm

  run_script
  [[ "$status" -eq 0 ]] || return 1
  [[ -z "$(github_output_value IMAGE_BUILD_COMMAND)" ]] || return 1
}

# =============================================================================
# A configured outputSubPath takes over the build's output dir
# =============================================================================

write_pm_output_sub_path() {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << EOF2
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    outputSubPath: '${1}'
EOF2
}

@test "output dir: earlier steps' output moves into the configured dir" {
  write_pm_output_sub_path custom-out
  mkdir -p "${TEST_DIR}/kaptain-out/earlier-step"
  printf 'x' > "${TEST_DIR}/kaptain-out/earlier-step/file"
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  [[ -f "${TEST_DIR}/custom-out/earlier-step/file" ]] || return 1
  [[ ! -e "${TEST_DIR}/kaptain-out" ]] || return 1
  assert_github_output "OUTPUT_SUB_PATH" "custom-out"
}

@test "output dir: a stale configured dir from an earlier run is replaced" {
  write_pm_output_sub_path custom-out
  mkdir -p "${TEST_DIR}/custom-out" "${TEST_DIR}/kaptain-out"
  printf 'old' > "${TEST_DIR}/custom-out/stale"
  printf 'new' > "${TEST_DIR}/kaptain-out/fresh"
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  [[ ! -e "${TEST_DIR}/custom-out/stale" ]] || return 1
  [[ -f "${TEST_DIR}/custom-out/fresh" ]] || return 1
}

@test "output dir: a nested configured path is created under its parent" {
  write_pm_output_sub_path build/out
  mkdir -p "${TEST_DIR}/kaptain-out"
  printf 'x' > "${TEST_DIR}/kaptain-out/file"
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  [[ -f "${TEST_DIR}/build/out/file" ]] || return 1
}

@test "output dir: with no starting dir the configured one is just created" {
  write_pm_output_sub_path custom-out
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  [[ -d "${TEST_DIR}/custom-out" ]] || return 1
}

@test "output dir: the same value as the starting dir touches nothing" {
  write_pm_output_sub_path kaptain-out
  mkdir -p "${TEST_DIR}/kaptain-out"
  printf 'keep' > "${TEST_DIR}/kaptain-out/sentinel"
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  [[ -f "${TEST_DIR}/kaptain-out/sentinel" ]] || return 1
  [[ "$output" != *"Moving the build's output dir"* ]] || return 1
}

@test "output dir: the push list path follows the move" {
  write_pm_output_sub_path custom-out
  mkdir -p "${TEST_DIR}/kaptain-out/docker-push-all"
  : > "${TEST_DIR}/kaptain-out/docker-push-all/image-uris"
  export DOCKER_PUSH_IMAGE_LIST_FILE="kaptain-out/docker-push-all/image-uris"
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  assert_github_output "DOCKER_PUSH_IMAGE_LIST_FILE" "custom-out/docker-push-all/image-uris"
  [[ -f "${TEST_DIR}/custom-out/docker-push-all/image-uris" ]] || return 1
}

@test "output dir: unsafe configured paths fail before anything is touched" {
  local value
  for value in /tmp/out out/ './out' 'a/../b' '..' '.' 'a//b' '.git/out' kaptainpm src src/out kaptain-out/inner; do
    write_pm_output_sub_path "${value}"
    mkdir -p "${TEST_DIR}/kaptain-out"
    printf 'keep' > "${TEST_DIR}/kaptain-out/sentinel"
    run_script
    [[ "${status}" -eq 1 ]] || { echo "accepted: ${value}"; return 1; }
    [[ "$output" == *"spec.global.outputSubPath"* ]] || { echo "wrong error for: ${value}"; return 1; }
    [[ -f "${TEST_DIR}/kaptain-out/sentinel" ]] || { echo "touched for: ${value}"; return 1; }
  done
}

@test "output dir: a starting dir nested in the configured one fails" {
  write_pm_output_sub_path out
  export OUTPUT_SUB_PATH="out/inner"
  mkdir -p "${TEST_DIR}/out/inner"
  run_script
  [[ "${status}" -eq 1 ]] || return 1
  assert_output_contains "must not be nested in each other"
  [[ -d "${TEST_DIR}/out/inner" ]] || return 1
}

@test "output dir: a configured dir with git-tracked files fails" {
  local repo="${TEST_DIR}/repo"
  mkdir -p "${repo}/kaptainpm/final" "${repo}/docs"
  cat > "${repo}/kaptainpm/final/KaptainPM.yaml" << 'EOF2'
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  global:
    outputSubPath: docs
EOF2
  printf 'mine' > "${repo}/docs/README.md"
  git -C "${repo}" init -q
  git -C "${repo}" add docs/README.md
  run bash -c "cd '${repo}' && GITHUB_OUTPUT='${GITHUB_OUTPUT}' '${SCRIPT}'"
  [[ "${status}" -eq 1 ]] || return 1
  assert_output_contains "holds files tracked by git"
  [[ -f "${repo}/docs/README.md" ]] || return 1
}

@test "deferred pinned layer entry replays with its Digest token" {
  write_pm
  append_entry "layer-github-flow-strict:1.2.3@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "1.2.3" layers "1.2.3" \
    "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  run_script
  [[ "${status}" -eq 0 ]] || return 1
  [[ "$(cat "$(token_file layers/LayerLayerGithubFlowStrictVersionSpec)")" == "1.2.3" ]] || return 1
  [[ "$(cat "$(token_file layers/LayerLayerGithubFlowStrictDigest)")" == "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]] || return 1
}

@test "output dir: a configured path through a symlinked parent fails and nothing outside is touched" {
  local outside
  outside=$(create_test_dir "outside")
  mkdir -p "${outside}/out" "${TEST_DIR}/kaptain-out"
  printf 'keep' > "${outside}/out/marker"
  printf 'keep' > "${TEST_DIR}/kaptain-out/sentinel"
  ln -s "${outside}" "${TEST_DIR}/linked"
  write_pm_output_sub_path linked/out
  run_script
  [[ "${status}" -eq 1 ]] || return 1
  assert_output_contains "spec.global.outputSubPath linked/out is or passes through a symbolic link (linked)"
  [[ -f "${outside}/out/marker" ]] || return 1
  [[ ! -e "${outside}/out/sentinel" ]] || return 1
  [[ -f "${TEST_DIR}/kaptain-out/sentinel" ]] || return 1
}

# =============================================================================
# docker.platform - checked on every build, and compared with this host so a
# wrapper can leave the platform setup step out when nothing needs emulation
# =============================================================================

# Usage: write_pm_platform <platforms>
write_pm_platform() {
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << PM
apiVersion: kaptain.org/1.10
kind: test-build
spec:
  main:
    docker:
      platform: ${1}
PM
}

# Usage: mock_host_arch <machine> - uname -m reports <machine>, anything else
# goes to the real uname
mock_host_arch() {
  local real_uname
  real_uname=$(command -v uname)
  mkdir -p "${TEST_DIR}/mock-bin"
  cat > "${TEST_DIR}/mock-bin/uname" << MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "-m" ]]; then echo "${1}"; else "${real_uname}" "\$@"; fi
MOCK
  chmod +x "${TEST_DIR}/mock-bin/uname"
  export PATH="${TEST_DIR}/mock-bin:${PATH}"
}

# Usage: assert_needs_emulation <host-machine> <platforms> <true|false>
assert_needs_emulation() {
  mock_host_arch "${1}"
  write_pm_platform "${2}"
  run_script
  [[ "${status}" -eq 0 ]] || { echo "status ${status} for ${2} on ${1}"; return 1; }
  assert_github_output "DOCKER_QEMU_SETUP_NEEDED" "${3}" || return 1
}

@test "docker.platform: a platform native to the host needs no emulation" {
  assert_needs_emulation x86_64 linux/amd64 false || return 1
  assert_needs_emulation x86_64 linux/386 false || return 1
  assert_needs_emulation aarch64 linux/arm64 false || return 1
  assert_needs_emulation arm64 linux/arm64 false || return 1
}

@test "docker.platform: a platform foreign to the host needs emulation" {
  assert_needs_emulation x86_64 linux/arm64 true || return 1
  assert_needs_emulation aarch64 linux/amd64 true || return 1
  assert_needs_emulation aarch64 linux/386 true || return 1
}

@test "docker.platform: a multi-platform build needs emulation on either host" {
  assert_needs_emulation x86_64 linux/amd64,linux/arm64 true || return 1
  assert_needs_emulation aarch64 linux/arm64,linux/amd64 true || return 1
}

@test "docker.platform: an unrecognised host arch needs emulation for everything" {
  assert_needs_emulation riscv64 linux/amd64 true || return 1
}

@test "docker.platform: the log names the arches that need emulation" {
  mock_host_arch x86_64
  write_pm_platform linux/amd64,linux/arm64
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  assert_output_contains "Docker platform linux/amd64,linux/arm64 on a x86_64 host: emulation needed for arm64"
}

@test "docker.platform: not set, the default decides" {
  unset DOCKER_PLATFORM
  mock_host_arch x86_64
  write_pm
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  assert_output_contains "Docker platform linux/amd64 on a x86_64 host: all native"
  assert_github_output "DOCKER_QEMU_SETUP_NEEDED" "false" || return 1
  # Still left for the later steps' own default, as before
  [[ -z "$(github_output_value DOCKER_PLATFORM)" ]] || return 1
}

@test "docker.platform: fails without IMAGE_BUILD_COMMAND" {
  unset IMAGE_BUILD_COMMAND
  write_pm
  run_script
  [[ "${status}" -ne 0 ]] || return 1
  assert_output_contains "IMAGE_BUILD_COMMAND is required"
}

@test "docker.platform: not set in the file, DOCKER_PLATFORM from the environment decides" {
  export DOCKER_PLATFORM="linux/arm64"
  mock_host_arch x86_64
  write_pm
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  assert_github_output "DOCKER_QEMU_SETUP_NEEDED" "true" || return 1
}

@test "docker.platform: the file wins over DOCKER_PLATFORM from the environment" {
  export DOCKER_PLATFORM="linux/arm64"
  mock_host_arch x86_64
  write_pm_platform linux/amd64
  run_script
  [[ "${status}" -eq 0 ]] || return 1
  assert_github_output "DOCKER_QEMU_SETUP_NEEDED" "false" || return 1
}

@test "docker.platform: an invalid value fails the load" {
  write_pm_platform windows/amd64
  run_script
  [[ "${status}" -eq 1 ]] || return 1
  assert_output_contains "Invalid DOCKER_PLATFORM value 'windows/amd64'"
  [[ -z "$(github_output_value DOCKER_QEMU_SETUP_NEEDED)" ]] || return 1
}

@test "docker.platform: linux/386 combined with another platform fails the load" {
  write_pm_platform linux/386,linux/amd64
  run_script
  [[ "${status}" -eq 1 ]] || return 1
  assert_output_contains "Invalid DOCKER_PLATFORM value 'linux/386,linux/amd64'"
}
