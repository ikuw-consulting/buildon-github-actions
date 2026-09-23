#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/layer-package-prepare
# Covers: project name detection (prefix/suffix), KaptainPM.yaml XOR between
# source_dir and context_dir, case-sensitive filename validation, layerset
# extras enforcement, copy behaviour.

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/layer-package-prepare"

setup() {
  TEST_DIR=$(create_test_dir "layer-package-prepare")
  REPO_DIR="${TEST_DIR}/repo"
  mkdir -p "${REPO_DIR}"
  cd "${REPO_DIR}"

  export VERSION="1.0.0"
  export REPOSITORY_OWNER="kube-kaptain"
  export REPOSITORY_NAME="layer-test"
  export OUTPUT_SUB_PATH="kaptain-out"
  export LAYER_PACKAGING_BASE_IMAGE="scratch"
  export BUILD_PLATFORM="test"
  export DOCKER_IMAGE_NAME="layer/layer-test"
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE="kube-kaptain"

  # Mock check-jsonschema (schema files themselves are real; we don't want to
  # validate against them in these tests, just exercise the script's own logic)
  mkdir -p "${MOCK_BIN_DIR}"
  cat > "${MOCK_BIN_DIR}/check-jsonschema" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${MOCK_BIN_DIR}/check-jsonschema"

  # Mocking check-jsonschema only works if the plugin routes there, so pin it
  export SCHEMA_VALIDATION_COMMAND="${PLUGINS_DIR}/schema-validation-providers/check-jsonschema"
  export PATH="${MOCK_BIN_DIR}:${PATH}"

  # Mock docker for the layerset verification loop (artifact-exists). Defaults
  # to "exists" so the happy-path tests don't need to opt in. Individual tests
  # can flip MOCK_DOCKER_MANIFEST_EXISTS=false to exercise the failure path.
  export IMAGE_BUILD_COMMAND="docker"
  export MOCK_DOCKER_MANIFEST_EXISTS=true
  setup_mock_docker

  if ! command -v yq &>/dev/null; then
    skip "yq not available"
  fi
}

# Read schema version once so fixtures always match the build system
SCHEMA_VERSION=$(cat "$PROJECT_ROOT/src/schemas/version")

# Helper: write a minimal valid layer KaptainPM.yaml to a given path
write_layer_pm() {
  local target="${1}"
  mkdir -p "$(dirname "${target}")"
  cat > "${target}" << EOF
apiVersion: kaptain.org/${SCHEMA_VERSION}
kind: kubernetes-app-docker-dockerfile
metadata:
  labels: {}
  annotations: {}
spec:
  main:
    quality:
      branches:
        blockSlashes: true
EOF
}

# Helper: write a minimal valid layerset KaptainPM.yaml to a given path
write_layerset_pm() {
  local target="${1}"
  mkdir -p "$(dirname "${target}")"
  cat > "${target}" << EOF
apiVersion: kaptain.org/${SCHEMA_VERSION}
kind: kubernetes-app-docker-dockerfile
metadata:
  labels: {}
  annotations: {}
spec:
  layers:
    - ghcr.io/kube-kaptain/quality/quality-strict:1.0.0
EOF
}

# Helper: write a layerset KaptainPM.yaml with a caller-supplied layers list.
# Args: target_path, then one ref per remaining argument.
write_layerset_pm_with_layers() {
  local target="${1}"
  shift
  mkdir -p "$(dirname "${target}")"
  {
    echo "apiVersion: kaptain.org/${SCHEMA_VERSION}"
    echo "kind: kubernetes-app-docker-dockerfile"
    echo "metadata:"
    echo "  labels: {}"
    echo "  annotations: {}"
    echo "spec:"
    echo "  layers:"
    local layer
    for layer in "$@"; do
      echo "    - ${layer}"
    done
  } > "${target}"
}

# =============================================================================
# PROJECT_NAME detection - prefix and suffix
# =============================================================================

@test "fails when PROJECT_NAME has no layer or layerset prefix or suffix" {
  export PROJECT_NAME="something-else"
  write_layer_pm "src/layer/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"must start or end with"* ]] || return 1
}

@test "detects layer from prefix (layer-foo)" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Layer type: layer"* ]] || return 1
}

@test "detects layer from suffix (foo-layer)" {
  export PROJECT_NAME="foo-layer"
  write_layer_pm "src/layer/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Layer type: layer"* ]] || return 1
}

@test "detects layerset from prefix (layerset-foo)" {
  export PROJECT_NAME="layerset-foo"
  write_layerset_pm "src/layerset/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Layer type: layerset"* ]] || return 1
}

@test "layerset writes layers-list file with resolved member bullets" {
  export PROJECT_NAME="layerset-foo"
  write_layerset_pm_with_layers "src/layerset/KaptainPM.yaml" \
    "ghcr.io/kube-kaptain/quality/quality-strict:1.0.0" \
    "ghcr.io/kube-kaptain/quality/quality-lenient:2.1.0"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1

  [ -f "kaptain-out/layers-list" ]
  [ "$(sed -n '1p' kaptain-out/layers-list)" = "- ghcr.io/kube-kaptain/quality/quality-strict:1.0.0" ]
  [ "$(sed -n '2p' kaptain-out/layers-list)" = "- ghcr.io/kube-kaptain/quality/quality-lenient:2.1.0" ]
}

@test "plain layer writes no layers-list file" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [ ! -f "kaptain-out/layers-list" ]
}

@test "detects layerset from suffix (foo-layerset)" {
  export PROJECT_NAME="foo-layerset"
  write_layerset_pm "src/layerset/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Layer type: layerset"* ]] || return 1
}

@test "layerset suffix wins over layer suffix ambiguity (my-layerset)" {
  # my-layerset must be classified as layerset, not layer. The script checks
  # layerset first to avoid the ambiguity.
  export PROJECT_NAME="my-layerset"
  write_layerset_pm "src/layerset/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Layer type: layerset"* ]] || return 1
}

# =============================================================================
# XOR presence: neither / both
# =============================================================================

@test "fails when KaptainPM.yaml is in neither source_dir nor context_dir" {
  export PROJECT_NAME="layer-foo"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"not found in src/layer/"* ]] || return 1
}

@test "fails when KaptainPM.yaml is in both source_dir and context_dir" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  write_layer_pm "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"present in both"* ]] || return 1
  [[ "$output" == *"pick one"* ]] || return 1
}

# =============================================================================
# Case-sensitive validation
# =============================================================================

@test "fails on case mismatch in source_dir" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/kaptainpm.yaml"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"case mismatch"* ]] || return 1
  [[ "$output" == *"failed validation"* ]] || return 1
}

# =============================================================================
# Layerset extras check - source_dir and context_dir
# =============================================================================

@test "layerset fails when source_dir has extra files" {
  export PROJECT_NAME="layerset-foo"
  write_layerset_pm "src/layerset/KaptainPM.yaml"
  echo "extra" > "src/layerset/unexpected.txt"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Unexpected file in src/layerset/"* ]] || return 1
  [[ "$output" == *"unexpected.txt"* ]] || return 1
}

@test "layerset fails when context_dir has extra files alongside the manifest" {
  export PROJECT_NAME="layerset-foo"
  mkdir -p "${OUTPUT_SUB_PATH}/layer-build/context"
  write_layerset_pm "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml"
  echo "extra" > "${OUTPUT_SUB_PATH}/layer-build/context/unexpected.txt"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Unexpected file in"* ]] || return 1
  [[ "$output" == *"unexpected.txt"* ]] || return 1
}

# =============================================================================
# Layerset from pre-populated context_dir (no source_dir)
# =============================================================================

@test "layerset accepts KaptainPM.yaml pre-populated in context_dir" {
  export PROJECT_NAME="layerset-foo"
  mkdir -p "${OUTPUT_SUB_PATH}/layer-build/context"
  write_layerset_pm "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml" ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/Dockerfile" ]] || return 1
}

# =============================================================================
# Layer copy: all source files flow through
# =============================================================================

@test "layer copies all source files including non-KaptainPM ones" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  echo "static content" > "src/layer/extra-static.txt"
  mkdir -p "src/layer/subdir"
  echo "nested" > "src/layer/subdir/nested.txt"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml" ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/extra-static.txt" ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/subdir/nested.txt" ]] || return 1
}

# =============================================================================
# Layer from pre-populated context_dir (no source_dir)
# =============================================================================

@test "layer accepts KaptainPM.yaml pre-populated in context_dir (no source_dir)" {
  export PROJECT_NAME="layer-foo"
  mkdir -p "${OUTPUT_SUB_PATH}/layer-build/context"
  write_layer_pm "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml" ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/Dockerfile" ]] || return 1
}

# =============================================================================
# Metadata injection (kaptain.org/* labels and annotations)
# =============================================================================

@test "layer injects kaptain.org labels (version, project-name, owner)" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1

  pm_yaml=$(cat "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml")
  [[ "$pm_yaml" == *'kaptain.org/version: "1.0.0"'* ]] || return 1
  [[ "$pm_yaml" == *"kaptain.org/project-name: layer-foo"* ]] || return 1
  [[ "$pm_yaml" == *"kaptain.org/owner: kube-kaptain"* ]] || return 1
}

@test "layer injects kaptain.org annotations including build-timestamp" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1

  pm_yaml=$(cat "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml")
  # project-name and version live on labels only, not annotations
  annotation_keys=$(yq eval '.metadata.annotations | keys | .[]' "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml")
  [[ "$annotation_keys" != *'kaptain.org/project-name'* ]] || return 1
  [[ "$annotation_keys" != *'kaptain.org/version'* ]] || return 1
  # Build traceability annotations
  [[ "$pm_yaml" == *"kaptain.org/build-timestamp:"* ]] || return 1
  [[ "$pm_yaml" == *"kaptain.org/built-by: test"* ]] || return 1
  [[ "$pm_yaml" == *"kaptain.org/source-repository: kube-kaptain/layer-test"* ]] || return 1
  [[ "$pm_yaml" == *"kaptain.org/image-uri: ghcr.io/kube-kaptain/layer/layer-test:1.0.0"* ]] || return 1
}

# =============================================================================
# context_dir is not wiped at script start
# =============================================================================

# =============================================================================
# Layerset remote-existence verification loop
# =============================================================================

@test "layerset verifies all spec.layers exist at remote" {
  export PROJECT_NAME="layerset-foo"
  export MOCK_DOCKER_MANIFEST_EXISTS=true
  write_layerset_pm "src/layerset/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Verifying remote existence"* ]] || return 1
  [[ "$output" == *"Remote existence verification complete"* ]] || return 1
}

@test "layerset fails when a spec.layers entry does not exist at remote" {
  export PROJECT_NAME="layerset-foo"
  export MOCK_DOCKER_MANIFEST_EXISTS=false
  export MOCK_DOCKER_PULL_FAILS=true
  write_layerset_pm "src/layerset/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Layer dependency does not exist at remote"* ]] || return 1
}

@test "layer path does not run remote-existence verification" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" != *"Verifying remote existence"* ]] || return 1
}

# =============================================================================
# Layerset spec.layers reference expansion (short/prefixed -> full URI)
# =============================================================================

@test "layerset expands short-form spec.layers ref to full URI" {
  export PROJECT_NAME="layerset-foo"
  write_layerset_pm_with_layers "src/layerset/KaptainPM.yaml" \
    "quality-strict:1.0.0"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1

  local resolved
  resolved=$(yq -r '.spec.layers[0]' "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml")
  [[ "${resolved}" == "ghcr.io/kube-kaptain/quality/quality-strict:1.0.0" ]] || return 1
}

@test "layerset expands prefixed-form spec.layers ref to full URI" {
  export PROJECT_NAME="layerset-foo"
  write_layerset_pm_with_layers "src/layerset/KaptainPM.yaml" \
    "quality/quality-strict:1.0.0"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1

  local resolved
  resolved=$(yq -r '.spec.layers[0]' "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml")
  [[ "${resolved}" == "ghcr.io/kube-kaptain/quality/quality-strict:1.0.0" ]] || return 1
}

@test "layerset preserves already-full-form spec.layers ref unchanged" {
  export PROJECT_NAME="layerset-foo"
  write_layerset_pm_with_layers "src/layerset/KaptainPM.yaml" \
    "ghcr.io/kube-kaptain/quality/quality-strict:1.0.0"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1

  local resolved
  resolved=$(yq -r '.spec.layers[0]' "${OUTPUT_SUB_PATH}/layer-build/context/KaptainPM.yaml")
  [[ "${resolved}" == "ghcr.io/kube-kaptain/quality/quality-strict:1.0.0" ]] || return 1
}

@test "does not remove pre-existing files in context_dir (no rm-rf)" {
  export PROJECT_NAME="layer-foo"
  write_layer_pm "src/layer/KaptainPM.yaml"
  mkdir -p "${OUTPUT_SUB_PATH}/layer-build/context"
  echo "pre-existing" > "${OUTPUT_SUB_PATH}/layer-build/context/hook-generated.txt"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ -f "${OUTPUT_SUB_PATH}/layer-build/context/hook-generated.txt" ]] || return 1
  run cat "${OUTPUT_SUB_PATH}/layer-build/context/hook-generated.txt"
  [[ "$output" == "pre-existing" ]] || return 1
}

teardown() {
  dump_bats_result
}
