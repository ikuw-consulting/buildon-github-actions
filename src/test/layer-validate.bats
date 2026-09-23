#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/layer-validate
# Focuses on the always-on layerset dependency validation loop: pull each
# dep, confirm /KaptainPM.yaml is present, validate against the build's layer
# schema. All failure modes are hard fails - there is no opt-out.
#
# To avoid clobbering the real util/extract-oci-image, the script is run
# from an isolated mirror under TEST_DIR with a stubbed util dir.

bats_require_minimum_version 1.5.0

load helpers

setup() {
  TEST_DIR=$(create_test_dir "layer-validate")

  # Mirror the on-disk layout the script expects, relative to SCRIPT_DIR.
  # The real layer-validate uses SCRIPT_DIR=$(dirname $0), then resolves
  # ../defaults, ../lib, ../util, and ../../schemas. Symlink the real ones
  # for everything except util/, which we stub.
  MIRROR_ROOT="${TEST_DIR}/mirror"
  mkdir -p "${MIRROR_ROOT}/scripts/main" "${MIRROR_ROOT}/scripts/util"
  cp "${PROJECT_ROOT}/src/scripts/main/layer-validate" "${MIRROR_ROOT}/scripts/main/layer-validate"
  ln -s "${PROJECT_ROOT}/src/scripts/defaults" "${MIRROR_ROOT}/scripts/defaults"
  ln -s "${PROJECT_ROOT}/src/scripts/lib" "${MIRROR_ROOT}/scripts/lib"
  ln -s "${PROJECT_ROOT}/src/schemas" "${MIRROR_ROOT}/schemas"
  SCRIPT="${MIRROR_ROOT}/scripts/main/layer-validate"

  # Stub extract-oci-image: behaviour controlled by MOCK_OCI_EXTRACT_MODE.
  # Kind in the written manifest is controlled per-call:
  #   MOCK_DEP_KIND_<safe_name> - per-ref override (safe_name is the trailing
  #     name segment with - replaced by _, e.g. ref ".../layer/quality-strict:1.0"
  #     -> MOCK_DEP_KIND_quality_strict). Set to "OMIT" to omit the kind line.
  #   MOCK_DEP_KIND - fallback when no per-ref var is set. Same OMIT semantics.
  #   default - "KubeAppDockerDockerfile"
  cat > "${MIRROR_ROOT}/scripts/util/extract-oci-image" << 'STUB'
#!/usr/bin/env bash
# Args: $1 = image_ref, $2 = staging_dir, $3 = path inside image
# Modes:
#   success (default) - exit 0 and write a minimal KaptainPM.yaml to staging
#   fail              - exit 1
#   empty             - exit 0 but write nothing (image lacks the file)
mode="${MOCK_OCI_EXTRACT_MODE:-success}"
case "${mode}" in
  fail)
    exit 1
    ;;
  empty)
    exit 0
    ;;
  success)
    image_ref="${1}"
    name="${image_ref##*/}"
    name="${name%%:*}"
    var="MOCK_DEP_KIND_${name//-/_}"
    kind="${!var:-${MOCK_DEP_KIND:-KubeAppDockerDockerfile}}"
    {
      echo "apiVersion: kaptain.org/1.7"
      if [[ "${kind}" != "OMIT" ]]; then
        echo "kind: ${kind}"
      fi
      echo "metadata:"
      echo "  labels: {}"
      echo "  annotations: {}"
      echo "spec:"
      echo "  main:"
      echo "    quality:"
      echo "      branches:"
      echo "        blockSlashes: true"
    } > "${2}/KaptainPM.yaml"
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "${MIRROR_ROOT}/scripts/util/extract-oci-image"

  REPO_DIR="${TEST_DIR}/repo"
  mkdir -p "${REPO_DIR}"
  cd "${REPO_DIR}"

  export OUTPUT_SUB_PATH="kaptain-out"
  export DOCKER_PLATFORM="linux/amd64"
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE="kube-kaptain"
  export BUILD_PLATFORM="test"
  export IMAGE_BUILD_COMMAND="docker"

  SUB_DIR="${OUTPUT_SUB_PATH}/docker/substituted"
  mkdir -p "${SUB_DIR}"
  JSON_FILE="${SUB_DIR}/KaptainPM.json"
  YAML_FILE="${SUB_DIR}/KaptainPM.yaml"

  # Mock check-jsonschema. Defaults to passing every call. Tests can flip
  # MOCK_JSONSCHEMA_FAIL_ON_DEPS=true to fail only for the per-dep validation
  # (detected by the path containing layer-validate/deps).
  mkdir -p "${MOCK_BIN_DIR}"
  cat > "${MOCK_BIN_DIR}/check-jsonschema" << 'MOCK'
#!/usr/bin/env bash
file_arg=""
for arg in "$@"; do
  case "${arg}" in
    --schemafile|--*) ;;
    *) file_arg="${arg}" ;;
  esac
done
if [[ "${MOCK_JSONSCHEMA_FAIL_ON_DEPS:-false}" == "true" && "${file_arg}" == *"layer-validate/deps"* ]]; then
  exit 1
fi
exit 0
MOCK
  chmod +x "${MOCK_BIN_DIR}/check-jsonschema"

  # Mocking check-jsonschema only works if the plugin routes there, so pin it
  export SCHEMA_VALIDATION_COMMAND="${PLUGINS_DIR}/schema-validation-providers/check-jsonschema"
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

# Helper: write substituted KaptainPM.{json,yaml} pair for a layerset with the
# given layer refs. The yaml is mirrored from the json via yq.
write_layerset_json() {
  local layers_json="${1}"
  cat > "${JSON_FILE}" << EOF
{
  "apiVersion": "kaptain.org/1.7",
  "kind": "KubeAppDockerDockerfile",
  "metadata": {"labels": {}, "annotations": {}},
  "spec": {
    "layers": ${layers_json}
  }
}
EOF
  yq -P '.' "${JSON_FILE}" > "${YAML_FILE}"
}

# Helper: write substituted KaptainPM.{json,yaml} pair for a layerset that
# omits the top-level kind field. Used for kind-matching tests.
write_layerset_json_no_kind() {
  local layers_json="${1}"
  cat > "${JSON_FILE}" << EOF
{
  "apiVersion": "kaptain.org/1.7",
  "metadata": {"labels": {}, "annotations": {}},
  "spec": {
    "layers": ${layers_json}
  }
}
EOF
  yq -P '.' "${JSON_FILE}" > "${YAML_FILE}"
}

# Helper: write substituted KaptainPM.{json,yaml} pair for a layer (not
# layerset). The yaml is mirrored from the json via yq.
write_layer_json() {
  cat > "${JSON_FILE}" << 'EOF'
{
  "apiVersion": "kaptain.org/1.7",
  "kind": "KubeAppDockerDockerfile",
  "metadata": {"labels": {}, "annotations": {}},
  "spec": {
    "main": {
      "quality": {
        "branches": {"blockSlashes": true}
      }
    }
  }
}
EOF
  yq -P '.' "${JSON_FILE}" > "${YAML_FILE}"
}

# Helper: write a layer with a single layer-payload entry having the given
# source and destination. Also creates the source file under SUB_DIR so the
# source-existence check passes (lets the destination validation actually run).
write_layer_with_payload() {
  local src="${1}" dest="${2}"
  cat > "${JSON_FILE}" << EOF
{
  "apiVersion": "kaptain.org/1.7",
  "kind": "KubeAppDockerDockerfile",
  "metadata": {"labels": {}, "annotations": {}},
  "layer-payload": [
    {"source": "${src}", "destination": "${dest}"}
  ],
  "spec": {
    "main": {
      "quality": {
        "branches": {"blockSlashes": true}
      }
    }
  }
}
EOF
  yq -P '.' "${JSON_FILE}" > "${YAML_FILE}"
  touch_context_file "${src}"
}

# Helper: write a layer with an arbitrary layer-payload array (JSON fragment).
# Does NOT create any context files - the caller is responsible for touching
# whatever sources it wants to exist in SUB_DIR via touch_context_file.
write_layer_with_payloads() {
  local payloads_json="${1}"
  cat > "${JSON_FILE}" << EOF
{
  "apiVersion": "kaptain.org/1.7",
  "kind": "KubeAppDockerDockerfile",
  "metadata": {"labels": {}, "annotations": {}},
  "layer-payload": ${payloads_json},
  "spec": {
    "main": {
      "quality": {
        "branches": {"blockSlashes": true}
      }
    }
  }
}
EOF
  yq -P '.' "${JSON_FILE}" > "${YAML_FILE}"
}

# Helper: create a zero-byte file inside SUB_DIR at the given image-absolute
# path. The leading / is stripped so /foo/bar.txt lands at ${SUB_DIR}/foo/bar.txt.
touch_context_file() {
  local src="${1}"
  local src_fs="${SUB_DIR}/${src#/}"
  mkdir -p "$(dirname "${src_fs}")"
  : > "${src_fs}"
}

# =============================================================================
# Layerset dependency validation - happy path
# =============================================================================

@test "layerset: all deps pull, contain manifest, pass schema" {
  export LAYER_TYPE="layerset"
  write_layerset_json '["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0", "ghcr.io/kube-kaptain/layer/java-base:2.0.0"]'
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Layerset dependency validation passed"* ]] || return 1
  [[ "$output" == *"ok: ghcr.io/kube-kaptain/layer/quality-strict:1.0.0"* ]] || return 1
  [[ "$output" == *"ok: ghcr.io/kube-kaptain/layer/java-base:2.0.0"* ]] || return 1
}

# =============================================================================
# Layerset dependency validation - failure modes
# =============================================================================

@test "layerset: fails when extract-oci-image fails on a dep" {
  export LAYER_TYPE="layerset"
  export MOCK_OCI_EXTRACT_MODE=fail
  write_layerset_json '["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Failed to pull dependency"* ]] || return 1
  [[ "$output" == *"Layerset dependency validation failed"* ]] || return 1
}

@test "layerset: fails when extract succeeds but writes no KaptainPM.yaml" {
  export LAYER_TYPE="layerset"
  export MOCK_OCI_EXTRACT_MODE=empty
  write_layerset_json '["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"does not contain /KaptainPM.yaml"* ]] || return 1
  [[ "$output" == *"Layerset dependency validation failed"* ]] || return 1
}

@test "layerset: fails when dep KaptainPM.yaml fails schema validation" {
  export LAYER_TYPE="layerset"
  export MOCK_JSONSCHEMA_FAIL_ON_DEPS=true
  write_layerset_json '["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"failed schema validation"* ]] || return 1
  [[ "$output" == *"Layerset dependency validation failed"* ]] || return 1
}

@test "layerset: fails when spec.layers is empty" {
  export LAYER_TYPE="layerset"
  write_layerset_json '[]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Layerset has no entries in spec.layers"* ]] || return 1
}

@test "layerset: fails when spec.layers contains duplicate refs" {
  export LAYER_TYPE="layerset"
  write_layerset_json '["ghcr.io/kube-kaptain/layer/a:1.0.0", "ghcr.io/kube-kaptain/layer/a:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  assert_contains "$output" "duplicate artifact references"
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/a"* ]] || return 1
}

@test "layerset: fails listing all duplicates when multiple pairs repeat" {
  export LAYER_TYPE="layerset"
  write_layerset_json '["ghcr.io/kube-kaptain/layer/a:1.0.0", "ghcr.io/kube-kaptain/layer/b:1.0.0", "ghcr.io/kube-kaptain/layer/a:1.0.0", "ghcr.io/kube-kaptain/layer/c:1.0.0", "ghcr.io/kube-kaptain/layer/b:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  assert_contains "$output" "duplicate artifact references"
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/a"* ]] || return 1
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/b"* ]] || return 1
}

@test "layerset: fails when same layer appears at two different versions" {
  export LAYER_TYPE="layerset"
  write_layerset_json '["ghcr.io/kube-kaptain/layer/a:1.0.0", "ghcr.io/kube-kaptain/layer/a:1.1.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  assert_contains "$output" "duplicate artifact references"
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/a"* ]] || return 1
}

@test "layerset: fails when same layer appears with and without docker| prefix" {
  export LAYER_TYPE="layerset"
  write_layerset_json '["docker|ghcr.io/kube-kaptain/layer/a:1.0.0", "ghcr.io/kube-kaptain/layer/a:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  assert_contains "$output" "duplicate artifact references"
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/a"* ]] || return 1
}

@test "layerset: passes when neither layerset nor deps declare kind" {
  export LAYER_TYPE="layerset"
  export MOCK_DEP_KIND="OMIT"
  write_layerset_json_no_kind '["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0", "ghcr.io/kube-kaptain/layer/java-base:2.0.0"]'
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Layerset dependency validation passed"* ]] || return 1
}

@test "layerset: fails when a dep declares a kind different from the layerset's kind" {
  export LAYER_TYPE="layerset"
  # Layerset's kind is KubeAppDockerDockerfile (default in write_layerset_json).
  # Mock writes a different kind for all deps.
  export MOCK_DEP_KIND="SomethingElse"
  write_layerset_json '["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"has kind 'SomethingElse', expected 'KubeAppDockerDockerfile'"* ]] || return 1
  [[ "$output" == *"Layerset dependency validation failed"* ]] || return 1
}

@test "layerset: fails when two deps declare conflicting kinds and layerset has none" {
  export LAYER_TYPE="layerset"
  # Layerset omits kind. Per-ref kinds: dep 'a' has KindOne, dep 'b' has KindTwo.
  # 'a' is processed first (no expected yet) -> sets expected to KindOne.
  # 'b' clashes -> failure naming KindTwo vs KindOne.
  export MOCK_DEP_KIND_a="KindOne"
  export MOCK_DEP_KIND_b="KindTwo"
  write_layerset_json_no_kind '["ghcr.io/kube-kaptain/layer/a:1.0.0", "ghcr.io/kube-kaptain/layer/b:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"has kind 'KindTwo', expected 'KindOne'"* ]] || return 1
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/b:1.0.0"* ]] || return 1
}

@test "layerset: continues checking remaining deps after a failure (collects all errors)" {
  export LAYER_TYPE="layerset"
  export MOCK_OCI_EXTRACT_MODE=fail
  write_layerset_json '["ghcr.io/kube-kaptain/layer/a:1.0.0", "ghcr.io/kube-kaptain/layer/b:1.0.0"]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  # Both refs should appear in output - script doesn't bail on first failure
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/a:1.0.0"* ]] || return 1
  [[ "$output" == *"ghcr.io/kube-kaptain/layer/b:1.0.0"* ]] || return 1
}

# =============================================================================
# Layer (not layerset) - skips dep loop entirely
# =============================================================================

@test "layer: does not run layerset dependency validation" {
  export LAYER_TYPE="layer"
  write_layer_json
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" != *"Layerset dependency validation"* ]] || return 1
}

# =============================================================================
# Type-shaped structural checks (redundant with schema, clearer error)
# =============================================================================

@test "layer: fails when spec.layers is declared" {
  export LAYER_TYPE="layer"
  cat > "${JSON_FILE}" << 'EOF'
{
  "apiVersion": "kaptain.org/1.7",
  "kind": "KubeAppDockerDockerfile",
  "metadata": {"labels": {}, "annotations": {}},
  "spec": {
    "layers": ["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0"]
  }
}
EOF
  yq -P '.' "${JSON_FILE}" > "${YAML_FILE}"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Layer must not declare spec.layers"* ]] || return 1
}

@test "layerset: fails when layer-payload is declared" {
  export LAYER_TYPE="layerset"
  cat > "${JSON_FILE}" << 'EOF'
{
  "apiVersion": "kaptain.org/1.7",
  "kind": "KubeAppDockerDockerfile",
  "metadata": {"labels": {}, "annotations": {}},
  "layer-payload": [
    {"source": "/thing.txt", "destination": "dest/"}
  ],
  "spec": {
    "layers": ["ghcr.io/kube-kaptain/layer/quality-strict:1.0.0"]
  }
}
EOF
  yq -P '.' "${JSON_FILE}" > "${YAML_FILE}"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Layerset must not declare layer-payload"* ]] || return 1
}

# =============================================================================
# Unresolved-token scan (KaptainPM.{yaml,json} only)
# =============================================================================

@test "unresolved-token scan: passes when KaptainPM.{yaml,json} have no remnants" {
  export LAYER_TYPE="layer"
  write_layer_json
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Unresolved-token scan: clean"* ]] || return 1
}

@test "unresolved-token scan: fails when KaptainPM.yaml contains an unresolved \${PascalCase} token" {
  export LAYER_TYPE="layer"
  write_layer_json
  # Inject an unresolved token as a valid annotation value (yaml only).
  yq -i '.metadata.annotations.leftover = "${SomeUnresolvedToken}"' "${YAML_FILE}"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Unsubstituted tokens found in KaptainPM.yaml"* ]] || return 1
  [[ "$output" == *"\${SomeUnresolvedToken}"* ]] || return 1
  [[ "$output" == *"Unresolved-token scan failed: 1 file(s) with remnants"* ]] || return 1
}

@test "unresolved-token scan: fails when KaptainPM.json contains an unresolved \${PascalCase} token" {
  export LAYER_TYPE="layer"
  write_layer_json
  # Inject an unresolved token as a valid annotation value (json only).
  jq '.metadata.annotations.leftover = "${AnotherToken}"' "${JSON_FILE}" > "${JSON_FILE}.tmp"
  mv "${JSON_FILE}.tmp" "${JSON_FILE}"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Unsubstituted tokens found in KaptainPM.json"* ]] || return 1
  [[ "$output" == *"\${AnotherToken}"* ]] || return 1
  [[ "$output" == *"Unresolved-token scan failed: 1 file(s) with remnants"* ]] || return 1
}

@test "unresolved-token scan: reports remnants in both files in one run" {
  export LAYER_TYPE="layer"
  write_layer_json
  yq -i '.metadata.annotations.leftover = "${YamlToken}"' "${YAML_FILE}"
  jq '.metadata.annotations.leftover = "${JsonToken}"' "${JSON_FILE}" > "${JSON_FILE}.tmp"
  mv "${JSON_FILE}.tmp" "${JSON_FILE}"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"Unsubstituted tokens found in KaptainPM.yaml"* ]] || return 1
  [[ "$output" == *"\${YamlToken}"* ]] || return 1
  [[ "$output" == *"Unsubstituted tokens found in KaptainPM.json"* ]] || return 1
  [[ "$output" == *"\${JsonToken}"* ]] || return 1
  [[ "$output" == *"Unresolved-token scan failed: 2 file(s) with remnants"* ]] || return 1
}

# =============================================================================
# Layer payload destination path validation
# =============================================================================
#
# The script rejects destination paths that are absolute or contain a '..'
# path component. The '..' check uses the regex (^|/)..($|/) so it ONLY
# matches '..' as a whole path component, never as a substring of a filename.

@test "layer-payload destination: rejects bare '..'" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" ".."
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"parent-traversal '..'"* ]] || return 1
}

@test "layer-payload destination: rejects leading '../'" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "../escape"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"parent-traversal '..'"* ]] || return 1
}

@test "layer-payload destination: rejects middle '/../'" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "foo/../bar"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"parent-traversal '..'"* ]] || return 1
}

@test "layer-payload destination: rejects trailing '/..'" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "foo/.."
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"parent-traversal '..'"* ]] || return 1
}

@test "layer-payload destination: rejects absolute path" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "/etc/passwd"
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"must be relative"* ]] || return 1
}

@test "layer-payload destination: accepts 'omg..wtf' (dots inside filename)" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "omg..wtf"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /src.txt -> omg..wtf"* ]] || return 1
}

@test "layer-payload destination: accepts '..hidden' (leading dots in filename)" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "..hidden"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /src.txt -> ..hidden"* ]] || return 1
}

@test "layer-payload destination: accepts 'version..1' (dots inside)" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "version..1"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /src.txt -> version..1"* ]] || return 1
}

@test "layer-payload destination: accepts plain relative path 'foo/bar'" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "foo/bar"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /src.txt -> foo/bar"* ]] || return 1
}

@test "layer-payload destination: accepts leading './'" {
  export LAYER_TYPE="layer"
  write_layer_with_payload "/src.txt" "./foo"
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /src.txt -> ./foo"* ]] || return 1
}

# =============================================================================
# Layer payload context-listing and uniqueness rules
# =============================================================================
#
# The script walks the substituted docker context dir to build an in-image
# path listing, then validates:
#   - each declared source is a real file in that listing
#   - sources MAY repeat (same file copied to multiple destinations)
#   - destinations MUST be globally unique across all payload entries

@test "layer-payload context: source not in context listing fails" {
  export LAYER_TYPE="layer"
  # Declare a source but do NOT create the underlying file in SUB_DIR
  write_layer_with_payloads '[{"source":"/ghost.txt","destination":"foo"}]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"source not found in context listing"* ]] || return 1
  [[ "$output" == *"/ghost.txt"* ]] || return 1
}

@test "layer-payload context: directory source is rejected (find -type f only)" {
  export LAYER_TYPE="layer"
  # Create a directory where the source would be - find -type f won't list it
  mkdir -p "${SUB_DIR}/adir"
  write_layer_with_payloads '[{"source":"/adir","destination":"foo"}]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"source not found in context listing"* ]] || return 1
}

@test "layer-payload context: nested source path is matched" {
  export LAYER_TYPE="layer"
  touch_context_file "/deep/nested/path/file.txt"
  write_layer_with_payloads '[{"source":"/deep/nested/path/file.txt","destination":"out/file.txt"}]'
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /deep/nested/path/file.txt -> out/file.txt"* ]] || return 1
}

@test "layer-payload uniqueness: duplicate sources with unique destinations pass" {
  export LAYER_TYPE="layer"
  touch_context_file "/shared.txt"
  write_layer_with_payloads '[
    {"source":"/shared.txt","destination":"copy-a"},
    {"source":"/shared.txt","destination":"copy-b"}
  ]'
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /shared.txt -> copy-a"* ]] || return 1
  [[ "$output" == *"payload ok: /shared.txt -> copy-b"* ]] || return 1
}

@test "layer-payload uniqueness: different sources to same destination dir pass" {
  export LAYER_TYPE="layer"
  touch_context_file "/a.txt"
  touch_context_file "/b.txt"
  write_layer_with_payloads '[
    {"source":"/a.txt","destination":"shared-dir"},
    {"source":"/b.txt","destination":"shared-dir"}
  ]'
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"payload ok: /a.txt -> shared-dir"* ]] || return 1
  [[ "$output" == *"payload ok: /b.txt -> shared-dir"* ]] || return 1
}

@test "layer-payload uniqueness: same source, same destination is rejected" {
  export LAYER_TYPE="layer"
  touch_context_file "/same.txt"
  write_layer_with_payloads '[
    {"source":"/same.txt","destination":"dest"},
    {"source":"/same.txt","destination":"dest"}
  ]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  # Caught by the (source, destination) pair-uniqueness check (first entry accepted, second rejected)
  [[ "$output" == *"(source, destination) pair already used by an earlier entry"* ]] || return 1
  [[ "$output" == *"/same.txt -> dest"* ]] || return 1
}

@test "layer-payload uniqueness: three distinct entries all pass" {
  export LAYER_TYPE="layer"
  touch_context_file "/one.txt"
  touch_context_file "/two.txt"
  touch_context_file "/three.txt"
  write_layer_with_payloads '[
    {"source":"/one.txt","destination":"out/one"},
    {"source":"/two.txt","destination":"out/two"},
    {"source":"/three.txt","destination":"out/three"}
  ]'
  run "$SCRIPT"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"Validating 3 layer-payload entry/entries"* ]] || return 1
  [[ "$output" == *"payload ok: /one.txt -> out/one"* ]] || return 1
  [[ "$output" == *"payload ok: /two.txt -> out/two"* ]] || return 1
  [[ "$output" == *"payload ok: /three.txt -> out/three"* ]] || return 1
}

@test "layer-payload accumulates multiple errors and reports the count" {
  export LAYER_TYPE="layer"
  # Four entries, each broken in a different way:
  #   [0] source not in context listing
  #   [1] absolute destination
  #   [2] destination contains '..'
  #   [3] valid entry (should still log ok)
  touch_context_file "/present.txt"
  write_layer_with_payloads '[
    {"source":"/missing.txt","destination":"ok/a"},
    {"source":"/present.txt","destination":"/etc/evil"},
    {"source":"/present.txt","destination":"../escape"},
    {"source":"/present.txt","destination":"ok/b"}
  ]'
  run "$SCRIPT"
  [[ "$status" -ne 0 ]] || return 1
  [[ "$output" == *"source not found in context listing"* ]] || return 1
  [[ "$output" == *"destination must be relative"* ]] || return 1
  [[ "$output" == *"parent-traversal"* ]] || return 1
  [[ "$output" == *"payload ok: /present.txt -> ok/b"* ]] || return 1
  [[ "$output" == *"layer-payload validation failed: 3 error(s)"* ]] || return 1
}

teardown() {
  dump_bats_result
}
