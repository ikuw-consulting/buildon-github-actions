#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for kubernetes-manifests-package (phase B: zip the substituted tree).
# Assumes kubernetes-manifests-substitute has already run.

bats_require_minimum_version 1.5.0

load helpers

setup() {
  export TEST_WORK_DIR=$(create_test_dir "manifests-pkg")
  export GITHUB_OUTPUT="$TEST_WORK_DIR/output"
  cd "$TEST_WORK_DIR"
  export OUTPUT_SUB_PATH="target"
  export PROJECT_NAME="my-project"
  export VERSION="1.2.3"

  # Simulate substitute has run - create the substituted/<project>/ tree
  mkdir -p "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME"
}

teardown() {
  dump_bats_result
  :
}

# Create manifest in substituted/<project>/ (simulating substitute has produced it)
create_substituted_manifest() {
  local filename="$1"
  local content="${2:-apiVersion: v1}"
  mkdir -p "$(dirname "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME/$filename")"
  echo "$content" > "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME/$filename"
}

@test "creates zip from substituted manifests" {
  create_substituted_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]
  assert_var_equals "MANIFESTS_ZIP_FILE_NAME" "my-project-1.2.3-manifests.zip"
  [ -f "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip" ]
}

@test "preserves directory structure in zip" {
  create_substituted_manifest "base/deployment.yaml"
  create_substituted_manifest "overlays/prod/patch.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]

  unzip -l "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip" | grep -q "my-project/base/deployment.yaml"
  unzip -l "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip" | grep -q "my-project/overlays/prod/patch.yaml"
}

@test "wraps contents in project-name directory" {
  create_substituted_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]

  unzip -l "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip" | grep -q "my-project/"
  unzip -l "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip" | grep -q "my-project/deployment.yaml"
}

@test "fails when substituted directory missing" {
  rm -rf "$OUTPUT_SUB_PATH/manifests/substituted"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -ne 0 ]
  assert_output_contains "Substituted manifests directory not found"
  assert_output_contains "kubernetes-manifests-substitute"
}

@test "fails when PROJECT_NAME missing" {
  unset PROJECT_NAME
  create_substituted_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -ne 0 ]
  assert_output_contains "PROJECT_NAME"
}

@test "fails when VERSION missing" {
  unset VERSION
  create_substituted_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -ne 0 ]
  assert_output_contains "VERSION"
}

@test "outputs zip path and filename" {
  create_substituted_manifest "deployment.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]
  assert_var_equals "MANIFESTS_ZIP_SUB_PATH" "target/manifests/zip"
  assert_var_equals "MANIFESTS_ZIP_FILE_NAME" "my-project-1.2.3-manifests.zip"
}

# =============================================================================
# Dotfiles are never captured; patch files are
# =============================================================================

@test "dotfiles are excluded from the zip" {
  create_substituted_manifest "deployment.yaml"
  create_substituted_manifest "sub/service.yaml"
  printf 'junk' > "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME/.DS_Store"
  printf 'junk' > "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME/sub/.DS_Store"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]
  local listing
  listing=$(unzip -Z1 "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip")
  [[ "$listing" == *"deployment.yaml"* ]] || return 1
  [[ "$listing" == *"sub/service.yaml"* ]] || return 1
  [[ "$listing" != *".DS_Store"* ]] || return 1
}

@test "a whole dot-directory is excluded from the zip" {
  create_substituted_manifest "deployment.yaml"
  mkdir -p "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME/.hidden"
  printf 'junk' > "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME/.hidden/thing.yaml"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]
  local listing
  listing=$(unzip -Z1 "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip")
  [[ "$listing" != *".hidden"* ]] || return 1
}

@test "yq patch files are packaged alongside their manifests" {
  create_substituted_manifest "deployment.yaml"
  create_substituted_manifest "deployment.yaml.yq-merge-yaml-annotations" "metadata:"
  create_substituted_manifest "deployment.yaml.yq-expression-list-scale" ".spec.replicas = 2"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]
  local listing
  listing=$(unzip -Z1 "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip")
  [[ "$listing" == *"deployment.yaml.yq-merge-yaml-annotations"* ]] || return 1
  [[ "$listing" == *"deployment.yaml.yq-expression-list-scale"* ]] || return 1
}

@test "only the four packageable shapes reach the zip" {
  # package-prepare fails the build on anything else, so this pins the zip's
  # own guarantee independently of that check.
  create_substituted_manifest "deployment.yaml"
  create_substituted_manifest "deployment.yaml.yq-from-file-big" ".a = 1"
  printf 'notes' > "$OUTPUT_SUB_PATH/manifests/substituted/$PROJECT_NAME/README.txt"

  run "$SCRIPTS_DIR/kubernetes-manifests-package"
  [ "$status" -eq 0 ]
  local listing
  listing=$(unzip -Z1 "$OUTPUT_SUB_PATH/manifests/zip/my-project-1.2.3-manifests.zip")
  [[ "$listing" == *"deployment.yaml"* ]] || return 1
  [[ "$listing" == *"deployment.yaml.yq-from-file-big"* ]] || return 1
  [[ "$listing" != *"README.txt"* ]] || return 1
}
