#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

bats_require_minimum_version 1.5.0

load helpers

setup() {
  export TEST_WORK_DIR=$(create_test_dir "manifests-prep")
  export GITHUB_OUTPUT="$TEST_WORK_DIR/output"
  cd "$TEST_WORK_DIR"
  # Use relative paths from within the temp dir
  export TEST_MANIFESTS="manifests"
  export OUTPUT_SUB_PATH="target"
  export CONFIG_DIR="config"
  mkdir -p "$TEST_MANIFESTS" "$OUTPUT_SUB_PATH" "$CONFIG_DIR"
}

teardown() {
  dump_bats_result
  :
}

# Create sample manifest file
create_manifest() {
  local filename="$1"
  local content="${2:-apiVersion: v1}"
  mkdir -p "$(dirname "$TEST_MANIFESTS/$filename")"
  echo "$content" > "$TEST_MANIFESTS/$filename"
}

# Create user config token
create_config_token() {
  local name="$1"
  local value="$2"
  mkdir -p "$(dirname "$CONFIG_DIR/$name")"
  printf '%s' "$value" > "$CONFIG_DIR/$name"
}

# Required env vars for most tests
set_required_env() {
  export PROJECT_NAME="my-project"
  export VERSION="1.2.3"
  export VERSION_MAJOR="1"
  export VERSION_MINOR="2"
  export VERSION_PATCH="3"
  export VERSION_2_PART="1.2"
  export VERSION_3_PART="1.2.3"
  export VERSION_4_PART="1.2.3.0"
  export VERSION_DNS_SAFE="1-2-3"
  export VERSION_2_PART_DNS_SAFE="1-2"
  export VERSION_3_PART_DNS_SAFE="1-2-3"
  export VERSION_4_PART_DNS_SAFE="1-2-3-0"
  export GIT_TAG="v1.2.3"
  export IS_RELEASE="true"
  export DOCKER_TAG="1.2.3"
  export DOCKER_IMAGE_NAME="my-project"
  export MANIFESTS_SUB_PATH="$TEST_MANIFESTS"
  export CONFIG_SUB_PATH="$CONFIG_DIR"
}

@test "creates target directory structure" {
  set_required_env
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ -d "$OUTPUT_SUB_PATH/manifests/combined" ]
  [ -d "$OUTPUT_SUB_PATH/manifests/config" ]
  [ -d "$OUTPUT_SUB_PATH/manifests/zip" ]
  [ -d "$OUTPUT_SUB_PATH/manifests/defaults" ]
}

@test "writes built-in tokens as files" {
  set_required_env
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  # Default style is PascalCase
  [ -f "$OUTPUT_SUB_PATH/manifests/config/ProjectName" ]
  [ -f "$OUTPUT_SUB_PATH/manifests/config/Version" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/ProjectName")" = "my-project" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/Version")" = "1.2.3" ]
}

@test "copies user config tokens" {
  set_required_env
  create_manifest "deployment.yaml"
  create_config_token "CustomVar" "custom-value"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/manifests/config/CustomVar" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/CustomVar")" = "custom-value" ]
}

@test "validates user config names match token-name-style" {
  set_required_env
  export TOKEN_NAME_STYLE="PascalCase"
  export TOKEN_NAME_VALIDATION="MATCH"
  create_manifest "deployment.yaml"
  create_config_token "invalid_name" "value"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Invalid"
}

@test "allows any name style when validation is ALL" {
  set_required_env
  export TOKEN_NAME_STYLE="PascalCase"
  export TOKEN_NAME_VALIDATION="ALL"
  create_manifest "deployment.yaml"
  create_config_token "my_custom_var" "value"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/manifests/config/my_custom_var" ]
}

@test "blocks builtin override by default" {
  set_required_env
  create_manifest "deployment.yaml"
  create_config_token "ProjectName" "overridden"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "override"
  assert_output_contains "ProjectName"
}

@test "fails when manifests directory not found and combined is empty" {
  set_required_env
  export MANIFESTS_SUB_PATH="/nonexistent/path"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Source directory not found"
  assert_output_contains "No manifests to package"
}

@test "fails when manifests directory is empty and combined is empty" {
  set_required_env

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Source directory empty"
  assert_output_contains "No manifests to package"
}

@test "fails when PROJECT_NAME missing" {
  export VERSION="1.0.0"
  export DOCKER_TAG="1.0.0"
  export DOCKER_IMAGE_NAME="test"
  export MANIFESTS_SUB_PATH="$TEST_MANIFESTS"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "PROJECT_NAME"
}

@test "fails when VERSION missing" {
  export PROJECT_NAME="my-project"
  export DOCKER_TAG="1.0.0"
  export DOCKER_IMAGE_NAME="test"
  export MANIFESTS_SUB_PATH="$TEST_MANIFESTS"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "VERSION"
}

@test "defaults MANIFESTS_SUB_PATH to src/kubernetes" {
  export PROJECT_NAME="my-project"
  export VERSION="1.0.0"
  export VERSION_MAJOR="1"
  export VERSION_MINOR="0"
  export VERSION_PATCH="0"
  export VERSION_2_PART="1.0"
  export VERSION_3_PART="1.0.0"
  export VERSION_4_PART="1.0.0.0"
  export VERSION_DNS_SAFE="1-0-0"
  export VERSION_2_PART_DNS_SAFE="1-0"
  export VERSION_3_PART_DNS_SAFE="1-0-0"
  export VERSION_4_PART_DNS_SAFE="1-0-0-0"
  export GIT_TAG="v1.0.0"
  export DOCKER_TAG="1.0.0"
  export DOCKER_IMAGE_NAME="test"
  unset MANIFESTS_SUB_PATH

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Source directory not found: src/kubernetes"
  assert_output_contains "No manifests to package"
}

@test "defaults OUTPUT_SUB_PATH to kaptain-out" {
  set_required_env
  unset OUTPUT_SUB_PATH
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Output: kaptain-out"
}

@test "reports yaml file count" {
  set_required_env
  create_manifest "deployment.yaml"
  create_manifest "service.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Found 2 manifest file(s)"
}

@test "handles nested user config tokens" {
  set_required_env
  create_manifest "deployment.yaml"
  mkdir -p "$CONFIG_DIR/Category"
  printf '%s' "nested-value" > "$CONFIG_DIR/Category/SubVar"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  [ -f "$OUTPUT_SUB_PATH/manifests/config/Category/SubVar" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/Category/SubVar")" = "nested-value" ]
}

@test "succeeds with no user config directory" {
  set_required_env
  export CONFIG_SUB_PATH="/nonexistent/config"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
}

@test "succeeds with empty user config directory" {
  set_required_env
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
}

@test "lists all conflicting tokens" {
  set_required_env
  create_manifest "deployment.yaml"
  create_config_token "ProjectName" "override1"
  create_config_token "Version" "override2"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "ProjectName"
  assert_output_contains "Version"
}

@test "succeeds with pre-populated combined directory and no source" {
  set_required_env
  export MANIFESTS_SUB_PATH="/nonexistent/path"

  # Simulate hooks pre-populating combined/
  mkdir -p "$OUTPUT_SUB_PATH/manifests/combined"
  echo 'apiVersion: v1' > "$OUTPUT_SUB_PATH/manifests/combined/from-hook.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Source directory not found"
  assert_output_contains "Found 1 manifest file(s)"
}

@test "source files override pre-populated combined files" {
  set_required_env

  # Simulate hooks pre-populating combined/
  mkdir -p "$OUTPUT_SUB_PATH/manifests/combined"
  echo 'name: from-hook' > "$OUTPUT_SUB_PATH/manifests/combined/deployment.yaml"

  # Source has same file with different content
  create_manifest "deployment.yaml" 'name: from-source'

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  # Source should override hook content
  grep -q "name: from-source" "$OUTPUT_SUB_PATH/manifests/combined/deployment.yaml"
}

@test "outputs MANIFESTS_ZIP_FILE_NAME" {
  set_required_env
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_var_equals "MANIFESTS_ZIP_FILE_NAME" "my-project-1.2.3-manifests.zip"
}

@test "copies additional tokens from additional-tokens dir" {
  set_required_env
  create_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/additional-tokens"
  printf '%s' "1.0.0-gateway" > "$OUTPUT_SUB_PATH/manifests/additional-tokens/DockerTagGateway"
  printf '%s' "1.0.0-ratelimit" > "$OUTPUT_SUB_PATH/manifests/additional-tokens/DockerTagRatelimit"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Copying 2 additional token(s)"

  [ -f "$OUTPUT_SUB_PATH/manifests/config/DockerTagGateway" ]
  [ -f "$OUTPUT_SUB_PATH/manifests/config/DockerTagRatelimit" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/DockerTagGateway")" = "1.0.0-gateway" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/DockerTagRatelimit")" = "1.0.0-ratelimit" ]
}

@test "succeeds when additional-tokens dir does not exist" {
  set_required_env
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_not_contains "additional token"
}

@test "fails when additional token collides with existing token" {
  set_required_env
  create_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/additional-tokens"
  printf '%s' "collision" > "$OUTPUT_SUB_PATH/manifests/additional-tokens/ProjectName"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "collide"
  assert_output_contains "ProjectName"
}

@test "fails when additional token collides with user config token" {
  set_required_env
  create_manifest "deployment.yaml"
  create_config_token "CustomVar" "user-value"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/additional-tokens"
  printf '%s' "additional-value" > "$OUTPUT_SUB_PATH/manifests/additional-tokens/CustomVar"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "collide"
  assert_output_contains "CustomVar"
}

@test "succeeds when additional-tokens dir is empty" {
  set_required_env
  create_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/additional-tokens"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_not_contains "additional token"
}

# =============================================================================
# Defaults merge — source defaults + additional-defaults → manifests/defaults/
# =============================================================================

# Stage a file under the local defaults source dir
stage_local_default() {
  local name="$1"
  local value="$2"
  mkdir -p "$(dirname "$LOCAL_DEFAULTS_DIR/$name")"
  printf '%s' "$value" > "$LOCAL_DEFAULTS_DIR/$name"
}

# Stage a file under the additional-defaults staging dir (foreign contributor)
stage_additional_default() {
  local name="$1"
  local value="$2"
  mkdir -p "$(dirname "$OUTPUT_SUB_PATH/manifests/additional-defaults/$name")"
  printf '%s' "$value" > "$OUTPUT_SUB_PATH/manifests/additional-defaults/$name"
}

@test "defaults: copies DEFAULTS_SUB_PATH into manifests/defaults/" {
  set_required_env
  create_manifest "deployment.yaml"
  export LOCAL_DEFAULTS_DIR="defaults-src"
  export DEFAULTS_SUB_PATH="$LOCAL_DEFAULTS_DIR"
  stage_local_default "MemoryRequest" "256Mi"
  stage_local_default "TestProject/CpuRequest" "100m"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/defaults/MemoryRequest")" = "256Mi" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/defaults/TestProject/CpuRequest")" = "100m" ]
}

@test "defaults: copies additional-defaults entries when no local collision" {
  set_required_env
  create_manifest "deployment.yaml"
  stage_additional_default "ForeignToken" "from-foreign"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/defaults/ForeignToken")" = "from-foreign" ]
}

@test "defaults: byte-identical local + additional merge is a no-op" {
  set_required_env
  create_manifest "deployment.yaml"
  export LOCAL_DEFAULTS_DIR="defaults-src"
  export DEFAULTS_SUB_PATH="$LOCAL_DEFAULTS_DIR"
  stage_local_default "SharedToken" "same-value"
  stage_additional_default "SharedToken" "same-value"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/defaults/SharedToken")" = "same-value" ]
}

@test "defaults: differing local + additional fails when override flag unset" {
  set_required_env
  create_manifest "deployment.yaml"
  export LOCAL_DEFAULTS_DIR="defaults-src"
  export DEFAULTS_SUB_PATH="$LOCAL_DEFAULTS_DIR"
  stage_local_default "Conflicting" "local-value"
  stage_additional_default "Conflicting" "additional-value"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Default value collisions"
  assert_output_contains "Conflicting"
  assert_output_contains "local-value"
  assert_output_contains "additional-value"
}

@test "defaults: differing local + additional WARNs and keeps local when override=true" {
  set_required_env
  create_manifest "deployment.yaml"
  export LOCAL_DEFAULTS_DIR="defaults-src"
  export DEFAULTS_SUB_PATH="$LOCAL_DEFAULTS_DIR"
  export ALLOW_LOCAL_DEFAULTS_OVERRIDE="true"
  stage_local_default "Conflicting" "local-value"
  stage_additional_default "Conflicting" "additional-value"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "WARNING: local default 'Conflicting' overrides"
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/defaults/Conflicting")" = "local-value" ]
}

@test "defaults: succeeds with no DEFAULTS_SUB_PATH dir and no additional-defaults" {
  set_required_env
  create_manifest "deployment.yaml"
  export DEFAULTS_SUB_PATH="nonexistent-defaults"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "No source defaults found"
  [ -d "$OUTPUT_SUB_PATH/manifests/defaults" ]
}

@test "defaults: succeeds with empty additional-defaults dir" {
  set_required_env
  create_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/additional-defaults"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_not_contains "additional default"
}

@test "defaults: drops imported default when token is baked by user config" {
  set_required_env
  create_manifest "deployment.yaml"
  create_config_token "ForeignToken" "baked-value"
  stage_additional_default "ForeignToken" "from-foreign"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Dropping imported default 'ForeignToken'"
  [ ! -e "$OUTPUT_SUB_PATH/manifests/defaults/ForeignToken" ]
}

@test "defaults: drops imported default when token is baked by a built-in" {
  set_required_env
  create_manifest "deployment.yaml"
  stage_additional_default "ProjectName" "from-foreign"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Dropping imported default 'ProjectName'"
  [ ! -e "$OUTPUT_SUB_PATH/manifests/defaults/ProjectName" ]
}

@test "defaults: in-tree default with matching config token still ships" {
  set_required_env
  create_manifest "deployment.yaml"
  export LOCAL_DEFAULTS_DIR="defaults-src"
  export DEFAULTS_SUB_PATH="$LOCAL_DEFAULTS_DIR"
  create_config_token "MyToken" "baked-value"
  stage_local_default "MyToken" "dead-default"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_not_contains "Dropping imported default"
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/defaults/MyToken")" = "dead-default" ]
}

@test "defaults: baked imported default skips collision check against local" {
  set_required_env
  create_manifest "deployment.yaml"
  export LOCAL_DEFAULTS_DIR="defaults-src"
  export DEFAULTS_SUB_PATH="$LOCAL_DEFAULTS_DIR"
  create_config_token "Conflicting" "baked-value"
  stage_local_default "Conflicting" "local-value"
  stage_additional_default "Conflicting" "additional-value"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Dropping imported default 'Conflicting'"
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/defaults/Conflicting")" = "local-value" ]
}

@test "defaults: drops nested imported default when nested config token baked" {
  set_required_env
  create_manifest "deployment.yaml"
  mkdir -p "$CONFIG_DIR/Alpha"
  printf '%s' "baked" > "$CONFIG_DIR/Alpha/Nested"
  stage_additional_default "Alpha/Nested" "from-foreign"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Dropping imported default 'Alpha/Nested'"
  [ ! -e "$OUTPUT_SUB_PATH/manifests/defaults/Alpha/Nested" ]
}

@test "defaults: reports counts when both sources contribute" {
  set_required_env
  create_manifest "deployment.yaml"
  export LOCAL_DEFAULTS_DIR="defaults-src"
  export DEFAULTS_SUB_PATH="$LOCAL_DEFAULTS_DIR"
  stage_local_default "LocalA" "a"
  stage_local_default "LocalB" "b"
  stage_additional_default "ForeignC" "c"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "Copying 2 default(s) from $LOCAL_DEFAULTS_DIR"
  assert_output_contains "Merging 1 additional default(s)"
}

# =============================================================================
# Manifests merge — source manifests + additional-manifests → manifests/combined/
# =============================================================================

# Stage a file under the additional-manifests staging dir (foreign contributor)
stage_additional_manifest() {
  local rel="$1"
  local content="$2"
  mkdir -p "$(dirname "$OUTPUT_SUB_PATH/manifests/additional-manifests/$rel")"
  printf '%s' "$content" > "$OUTPUT_SUB_PATH/manifests/additional-manifests/$rel"
}

@test "manifests: copies additional-manifests entries when no local collision" {
  set_required_env
  create_manifest "deployment.yaml"
  stage_additional_manifest "alpha/foreign.yaml" $'apiVersion: v1\nkind: ConfigMap\n'

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_SUB_PATH/manifests/combined/alpha/foreign.yaml" ]
  [ -f "$OUTPUT_SUB_PATH/manifests/combined/deployment.yaml" ]
}

@test "manifests: byte-identical local + additional collision fails when override unset" {
  set_required_env
  create_manifest "shared.yaml" $'apiVersion: v1\nkind: ConfigMap\n'
  stage_additional_manifest "shared.yaml" $'apiVersion: v1\nkind: ConfigMap\n'

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Manifest path collisions"
  assert_output_contains "shared.yaml"
}

@test "manifests: differing local + additional collision fails when override unset" {
  set_required_env
  create_manifest "alpha/deployment.yaml" $'name: from-local\n'
  stage_additional_manifest "alpha/deployment.yaml" $'name: from-foreign\n'

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Manifest path collisions"
  assert_output_contains "alpha/deployment.yaml"
  assert_output_contains "allowLocalOverride: true"
}

@test "manifests: differing local + additional WARNs and keeps local when override=true" {
  set_required_env
  export ALLOW_LOCAL_MANIFESTS_OVERRIDE="true"
  create_manifest "alpha/deployment.yaml" $'name: from-local\n'
  stage_additional_manifest "alpha/deployment.yaml" $'name: from-foreign\n'

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_contains "WARNING: local manifest 'alpha/deployment.yaml' overrides"
  grep -q "name: from-local" "$OUTPUT_SUB_PATH/manifests/combined/alpha/deployment.yaml"
}

@test "manifests: succeeds with no additional-manifests dir" {
  set_required_env
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_not_contains "additional manifest"
}

@test "manifests: succeeds with empty additional-manifests dir" {
  set_required_env
  create_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/additional-manifests"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_not_contains "additional manifest"
}

# ============================================================================
# builtinMode: template - built-ins defer to the consuming build
# ============================================================================

@test "template mode writes built-ins under the Original prefix" {
  set_required_env
  export TOKEN_BUILTIN_MODE="template"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/OriginalProjectName")" = "my-project" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/OriginalVersion")" = "1.2.3" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/OriginalDockerTag")" = "1.2.3" ]
}

@test "template mode leaves the plain built-in names unwritten" {
  set_required_env
  export TOKEN_BUILTIN_MODE="template"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  [ ! -f "$OUTPUT_SUB_PATH/manifests/config/ProjectName" ]
  [ ! -f "$OUTPUT_SUB_PATH/manifests/config/Version" ]
  [ ! -f "$OUTPUT_SUB_PATH/manifests/config/DockerTag" ]
}

@test "template mode prefixes the disk-scanned context tokens too" {
  set_required_env
  export TOKEN_BUILTIN_MODE="template"
  create_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/builtin-resolved-tokens/repository"
  printf '%s' "some-repo" > "$OUTPUT_SUB_PATH/builtin-resolved-tokens/repository/RepositoryName"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]

  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/OriginalRepositoryName")" = "some-repo" ]
  [ ! -f "$OUTPUT_SUB_PATH/manifests/config/RepositoryName" ]
}

@test "template mode lets user config supply a deferred built-in" {
  set_required_env
  export TOKEN_BUILTIN_MODE="template"
  create_manifest "deployment.yaml"
  create_config_token "ProjectName" "consumer-supplied"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/ProjectName")" = "consumer-supplied" ]
}

@test "template mode lets additional-tokens supply a deferred built-in" {
  set_required_env
  export TOKEN_BUILTIN_MODE="template"
  create_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/additional-tokens"
  printf '%s' "hook-supplied" > "$OUTPUT_SUB_PATH/manifests/additional-tokens/Version"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/Version")" = "hook-supplied" ]
}

@test "standard mode still rejects a user token shadowing a built-in" {
  set_required_env
  export TOKEN_BUILTIN_MODE="standard"
  create_manifest "deployment.yaml"
  create_config_token "ProjectName" "overridden"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "override"
}

@test "fails on an unknown builtin mode" {
  set_required_env
  export TOKEN_BUILTIN_MODE="defer"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -ne 0 ]
  assert_output_contains "Unknown builtin token mode"
}

# ============================================================================
# DOCKER_TARGET_* is the single source for the TargetRegistry/TargetNamespace
# tokens. The short names are what prepare-substitution-tokens publishes, and
# the bridge lives in defaults/docker-build.bash so every platform and a local
# run reach them the same way - no CI wrapper renames them.
# ============================================================================

@test "TargetRegistry token resolves from DOCKER_TARGET_REGISTRY" {
  set_required_env
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/TargetRegistry")" = "ghcr.io" ]
}

@test "TargetNamespace token resolves from DOCKER_TARGET_NAMESPACE" {
  set_required_env
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE="kube-kaptain"
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/TargetNamespace")" = "kube-kaptain" ]
}

@test "TargetNamespace is written empty rather than left as a token" {
  set_required_env
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE=""
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_SUB_PATH/manifests/config/TargetNamespace" ]
  [ "$(cat "$OUTPUT_SUB_PATH/manifests/config/TargetNamespace")" = "" ]
}

@test "no registry means no TargetRegistry token rather than an empty one" {
  set_required_env
  unset DOCKER_TARGET_REGISTRY
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  [ ! -f "$OUTPUT_SUB_PATH/manifests/config/TargetRegistry" ]
}

@test "packaging does not require docker target validation" {
  # Sourcing docker-build.bash must not drag its DOCKER_IMAGE_NAME/DOCKER_TAG
  # validation into a flow that builds no image.
  set_required_env
  unset DOCKER_TARGET_REGISTRY
  unset DOCKER_TARGET_NAMESPACE
  create_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package-prepare"
  [ "$status" -eq 0 ]
  assert_output_not_contains "is required"
}
