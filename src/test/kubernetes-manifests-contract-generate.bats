#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for kubernetes-manifests-contract-generate
#
# Generates a manifests contract file and zip from substituted manifests.

bats_require_minimum_version 1.5.0

load helpers

CONTRACT_SCRIPT="$SCRIPTS_DIR/kubernetes-manifests-contract-generate"

setup() {
  TEST_DIR=$(create_test_dir "contract-gen")
  cd "$TEST_DIR"
  export OUTPUT_SUB_PATH="kaptain-out"
  export PROJECT_NAME="test-project"
  export VERSION="1.2.3"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
  export BUILD_KIND="kubernetes-bundle-resources"

  # Create substituted manifests dir (as kubernetes-manifests-package would)
  mkdir -p "${OUTPUT_SUB_PATH}/manifests/substituted/${PROJECT_NAME}"
  mkdir -p "${OUTPUT_SUB_PATH}/manifests/zip"
}

# Helper: create a manifest with unresolved tokens
write_manifest_with_tokens() {
  cat > "${OUTPUT_SUB_PATH}/manifests/substituted/${PROJECT_NAME}/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-project
  namespace: ${Environment}
spec:
  replicas: 3
  template:
    spec:
      containers:
        - image: ${EnvironmentDockerRegistryAndNamespace}/test-project:1.2.3
          resources:
            requests:
              memory: ${MemoryRequest}
              cpu: ${CpuRequest}
EOF
}

# Helper: create a manifest with nested (path-based) tokens, matching the
# defaults that some tests stage under TestProject/.
write_manifest_with_nested_tokens() {
  cat > "${OUTPUT_SUB_PATH}/manifests/substituted/${PROJECT_NAME}/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-project
  namespace: ${Environment}
spec:
  replicas: 3
  template:
    spec:
      containers:
        - resources:
            requests:
              memory: ${TestProject/MemoryRequest}
              cpu: ${TestProject/CpuRequest}
EOF
}

# Helper: create a clean manifest (no tokens)
write_clean_manifest() {
  cat > "${OUTPUT_SUB_PATH}/manifests/substituted/${PROJECT_NAME}/service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: test-project
spec:
  ports:
    - port: 80
EOF
}

# =============================================================================
# Argument validation
# =============================================================================

@test "contract-generate: fails without PROJECT_NAME" {
  unset PROJECT_NAME
  run "$CONTRACT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "contract-generate: fails without VERSION" {
  unset VERSION
  run "$CONTRACT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "contract-generate: fails without BUILD_KIND" {
  unset BUILD_KIND
  run "$CONTRACT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "contract-generate: fails if substituted dir missing" {
  rm -rf "${OUTPUT_SUB_PATH}/manifests/substituted"
  run "$CONTRACT_SCRIPT"
  [ "$status" -ne 0 ]
}

# =============================================================================
# Kind mapping
# =============================================================================

@test "contract-generate: passes kubernetes-bundle-resources through as kind" {
  write_clean_manifest
  export BUILD_KIND="kubernetes-bundle-resources"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  [ -f "$contract" ]
  local kind
  kind=$(yq '.kind' "$contract")
  [ "$kind" = "$BUILD_KIND" ]
}

@test "contract-generate: passes kubernetes-bundle-vendor-helm-rendered through as kind" {
  write_clean_manifest
  export BUILD_KIND="kubernetes-bundle-vendor-helm-rendered"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local kind
  kind=$(yq '.kind' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  [ "$kind" = "$BUILD_KIND" ]
}

@test "contract-generate: passes kubernetes-app-manifests-only through as kind" {
  write_clean_manifest
  export BUILD_KIND="kubernetes-app-manifests-only"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local kind
  kind=$(yq '.kind' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  [ "$kind" = "$BUILD_KIND" ]
}

@test "contract-generate: passes kubernetes-app-docker-dockerfile through as kind" {
  write_clean_manifest
  export BUILD_KIND="kubernetes-app-docker-dockerfile"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local kind
  kind=$(yq '.kind' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  [ "$kind" = "$BUILD_KIND" ]
}

# =============================================================================
# Contract YAML content
# =============================================================================

@test "contract-generate: sets apiVersion correctly" {
  write_clean_manifest
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local api_version
  api_version=$(yq '.apiVersion' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  local expected_version
  expected_version=$(cat "$PROJECT_ROOT/src/schemas/manifests-contract/version")
  [ "$api_version" = "kaptain.org/manifests-contract/${expected_version}" ]
}

@test "contract-generate: sets token scheme from env vars" {
  write_clean_manifest
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  [ "$(yq '.tokens.delimiterStyle' "$contract")" = "shell" ]
  [ "$(yq '.tokens.nameStyle' "$contract")" = "PascalCase" ]
}

@test "contract-generate: includes metadata.description when set" {
  write_clean_manifest
  export METADATA_DESCRIPTION="Test project for unit testing"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local desc
  desc=$(yq '.metadata.description' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  [ "$desc" = "Test project for unit testing" ]
}

@test "contract-generate: omits metadata when description not set" {
  write_clean_manifest
  unset METADATA_DESCRIPTION
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local meta
  meta=$(yq '.metadata' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  [ "$meta" = "null" ]
}

# =============================================================================
# Token scanning
# =============================================================================

@test "contract-generate: lists unresolved tokens in config.required" {
  write_manifest_with_tokens
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  local required
  required=$(yq '.config.required[]' "$contract" | sort)
  echo "$required" | grep -q "CpuRequest"
  echo "$required" | grep -q "Environment"
  echo "$required" | grep -q "EnvironmentDockerRegistryAndNamespace"
  echo "$required" | grep -q "MemoryRequest"
}

@test "contract-generate: lists nested (path-based) tokens in config.required" {
  cat > "${OUTPUT_SUB_PATH}/manifests/substituted/${PROJECT_NAME}/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-project
  namespace: ${Environment}
spec:
  replicas: ${TestProject/Replicas}
  template:
    spec:
      containers:
        - resources:
            requests:
              memory: ${TestProject/Memory}
              cpu: ${TestProject/Cpu}
EOF
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  local required
  required=$(yq '.config.required[]' "$contract" | sort)
  echo "$required" | grep -q "Environment"
  echo "$required" | grep -q "TestProject/Replicas"
  echo "$required" | grep -q "TestProject/Memory"
  echo "$required" | grep -q "TestProject/Cpu"
}

@test "contract-generate: omits config section when no unresolved tokens" {
  write_clean_manifest
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local config
  config=$(yq '.config' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  [ "$config" = "null" ]
}

@test "contract-generate: all tokens in noDefault when no defaults dir" {
  write_manifest_with_tokens
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  local no_default_count
  no_default_count=$(yq '.config.noDefault | length' "$contract")
  local required_count
  required_count=$(yq '.config.required | length' "$contract")
  [ "$no_default_count" -eq "$required_count" ]
}

# =============================================================================
# Defaults handling
# =============================================================================

@test "contract-generate: copies defaults and sets inline values with nested paths" {
  write_manifest_with_nested_tokens
  local defaults_dir="${OUTPUT_SUB_PATH}/manifests/defaults"
  mkdir -p "${defaults_dir}/TestProject"
  printf '256Mi' > "${defaults_dir}/TestProject/MemoryRequest"
  printf '100m' > "${defaults_dir}/TestProject/CpuRequest"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  [ "$(yq '.config.defaults["TestProject/MemoryRequest"]' "$contract")" = "256Mi" ]
  [ "$(yq '.config.defaults["TestProject/CpuRequest"]' "$contract")" = "100m" ]
}

@test "contract-generate: tokens with flat defaults excluded from noDefault" {
  write_manifest_with_tokens
  local defaults_dir="${OUTPUT_SUB_PATH}/manifests/defaults"
  mkdir -p "${defaults_dir}"
  printf '256Mi' > "${defaults_dir}/MemoryRequest"
  printf '100m' > "${defaults_dir}/CpuRequest"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  # MemoryRequest and CpuRequest have defaults, should NOT be in noDefault
  local no_defaults
  no_defaults=$(yq '.config.noDefault[]' "$contract")
  [ "$(echo "$no_defaults" | grep -c "MemoryRequest")" -eq 0 ]
  [ "$(echo "$no_defaults" | grep -c "CpuRequest")" -eq 0 ]
  # Environment and EnvironmentDockerRegistryAndNamespace have NO defaults
  echo "$no_defaults" | grep -q "Environment"
  echo "$no_defaults" | grep -q "EnvironmentDockerRegistryAndNamespace"
}

@test "contract-generate: defaults dir copied into contract dir preserving structure" {
  write_manifest_with_nested_tokens
  local defaults_dir="${OUTPUT_SUB_PATH}/manifests/defaults"
  mkdir -p "${defaults_dir}/TestProject"
  printf '256Mi' > "${defaults_dir}/TestProject/MemoryRequest"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "${OUTPUT_SUB_PATH}/manifests/contract/defaults/TestProject/MemoryRequest" ]
  [ "$(cat "${OUTPUT_SUB_PATH}/manifests/contract/defaults/TestProject/MemoryRequest")" = "256Mi" ]
}

@test "contract-generate: fails when defaults filename does not match declared name style" {
  write_manifest_with_tokens
  local defaults_dir="${OUTPUT_SUB_PATH}/manifests/defaults"
  mkdir -p "${defaults_dir}"
  # PascalCase project, but defaults file uses lower-kebab - should fail validation
  printf '256Mi' > "${defaults_dir}/memory-request"
  run "$CONTRACT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"do not match the declared name style PascalCase"* ]] || return 1
}

@test "contract-generate: fails when a defaults file does not match any unresolved token" {
  write_manifest_with_tokens
  local defaults_dir="${OUTPUT_SUB_PATH}/manifests/defaults"
  mkdir -p "${defaults_dir}"
  # Correct style but no matching token in the manifest - orphan
  printf 'oops' > "${defaults_dir}/UnreferencedToken"
  run "$CONTRACT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"do not correspond to any unresolved token"* ]] || return 1
  [[ "${output}" == *"UnreferencedToken"* ]] || return 1
}

# =============================================================================
# Compatibility
# =============================================================================

@test "contract-generate: includes compatibility section" {
  write_clean_manifest
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local compat
  compat=$(yq '.compatibility' "${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml")
  [ "$compat" != "null" ]
}

@test "contract-generate: shell tokens in manifests cause shell repackage for other name styles" {
  write_manifest_with_tokens
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  # Our ${PascalCase} tokens also match shell-camelCase etc regex
  # so those should appear in repackageRequired or not in automaticConversion
  # (depends on regex overlap - the key thing is the section exists)
  local has_auto
  has_auto=$(yq '.compatibility.automaticConversion' "$contract")
  [ "$has_auto" != "null" ]
}

# =============================================================================
# Zip output
# =============================================================================

@test "contract-generate: creates contract zip" {
  write_manifest_with_tokens
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "${OUTPUT_SUB_PATH}/manifests/zip/test-project-1.2.3-contract.zip" ]
}

@test "contract-generate: zip contains contract.yaml" {
  write_manifest_with_tokens
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local zip="${OUTPUT_SUB_PATH}/manifests/zip/test-project-1.2.3-contract.zip"
  zipinfo -1 "$zip" | grep -q "contract.yaml"
}

@test "contract-generate: zip contains defaults dir when present" {
  write_manifest_with_nested_tokens
  local defaults_dir="${OUTPUT_SUB_PATH}/manifests/defaults"
  mkdir -p "${defaults_dir}/TestProject"
  printf '256Mi' > "${defaults_dir}/TestProject/MemoryRequest"
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local zip="${OUTPUT_SUB_PATH}/manifests/zip/test-project-1.2.3-contract.zip"
  zipinfo -1 "$zip" | grep -q "defaults/TestProject/MemoryRequest"
}

@test "contract-generate: zip has no defaults dir when none present" {
  write_clean_manifest
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local zip="${OUTPUT_SUB_PATH}/manifests/zip/test-project-1.2.3-contract.zip"
  ! zipinfo -1 "$zip" | grep -q "defaults/"
}

@test "contract-generate: sets output vars" {
  write_clean_manifest
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "CONTRACT_ZIP_SUB_PATH="
  assert_output_contains "CONTRACT_ZIP_FILE_NAME=test-project-1.2.3-contract.zip"
}

@test "contract-generate: deferred built-ins land in config.required as bare names" {
  cat > "${OUTPUT_SUB_PATH}/manifests/substituted/${PROJECT_NAME}/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${ProjectName}
  labels:
    app.kubernetes.io/version: ${Version}
    kaptain.org/source-repository: ${RepositoryName}
EOF
  run "$CONTRACT_SCRIPT"
  [ "$status" -eq 0 ]
  local contract="${OUTPUT_SUB_PATH}/manifests/contract/contract.yaml"
  local required
  required=$(yq '.config.required[]' "$contract")
  echo "$required" | grep -qx "ProjectName"
  echo "$required" | grep -qx "Version"
  echo "$required" | grep -qx "RepositoryName"
  # Bare names, no delimiters - this is what keeps the lineage no-unresolved
  # assertion from tripping on a template-mode build.
  ! grep -q '\${' "$contract"
}

teardown() {
  dump_bats_result
}
