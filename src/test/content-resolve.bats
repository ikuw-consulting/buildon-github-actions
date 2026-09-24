#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for content-resolve.bash library.
#
# The library exposes helpers for the product-aggregate (and later
# environment-build) flow: tag manipulation, zip discovery, unzipping
# manifests + contract, and an orchestrator that resolves every
# spec.contents entry.

bats_require_minimum_version 1.5.0

load helpers

setup() {
  TEST_DIR=$(create_test_dir "content-resolve")
  # content-resolve.bash now validates these at source time. Tests use the
  # 'contents' flavour so the file stems / dir layout match the product path.
  export OUTPUT_SUB_PATH="${TEST_DIR}"
  export CONTENT_FLAVOUR=contents
  source "$LIB_DIR/content-resolve.bash"
  unset CONTENT_MANIFESTS_ZIP CONTENT_CONTRACT_ZIP CONTENT_PROJECT_NAME
}

# Helper: create a manifests zip for a fake project at a given path.
# Layout: <project>/manifest.yaml plus optional extra files.
make_manifests_zip() {
  local zip_path="$1"
  local project="$2"
  local stage="${TEST_DIR}/_stage-$$-${RANDOM}"
  mkdir -p "${stage}/${project}"
  cat > "${stage}/${project}/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${project}
EOF
  ( cd "${stage}" && zip -qr "${zip_path}" "${project}" )
  rm -rf "${stage}"
}

# Helper: create a contract zip with contract.yaml and optional defaults files.
# Args: zip_path; remaining args are token-name=value pairs for defaults files.
# .config.required is auto-populated with each default name so the bundle
# passes content_validate_bundle's defaults-orphan check.
make_contract_zip() {
  local zip_path="$1"
  shift
  local stage="${TEST_DIR}/_stage-$$-${RANDOM}"
  mkdir -p "${stage}"
  cat > "${stage}/contract.yaml" << 'EOF'
apiVersion: kaptain.org/manifests-contract/1.2
kind: kubernetes-bundle
tokens:
  delimiterStyle: shell
  nameStyle: PascalCase
compatibility:
  automaticConversion: []
  repackageRequired: []
EOF
  if [[ $# -gt 0 ]]; then
    mkdir -p "${stage}/defaults"
    {
      echo "config:"
      echo "  required:"
      local pair
      for pair in "$@"; do
        echo "    - ${pair%%=*}"
      done
    } >> "${stage}/contract.yaml"
    local pair
    for pair in "$@"; do
      local name="${pair%%=*}"
      local value="${pair#*=}"
      mkdir -p "$(dirname "${stage}/defaults/${name}")"
      printf '%s' "${value}" > "${stage}/defaults/${name}"
    done
  fi
  ( cd "${stage}" && zip -qr "${zip_path}" . )
  rm -rf "${stage}"
}

# =============================================================================
# content_find_zips
# =============================================================================

@test "content_find_zips: locates one of each" {
  mkdir -p "$TEST_DIR/extract"
  touch "$TEST_DIR/extract/foo-1.0-manifests.zip"
  touch "$TEST_DIR/extract/foo-1.0-contract.zip"
  run -0 bash -c "
    source '$LIB_DIR/content-resolve.bash'
    content_find_zips '$TEST_DIR/extract'
    echo MZ=\${CONTENT_MANIFESTS_ZIP}
    echo CZ=\${CONTENT_CONTRACT_ZIP}
  "
  echo "$output" | grep -q "MZ=.*foo-1.0-manifests.zip"
  echo "$output" | grep -q "CZ=.*foo-1.0-contract.zip"
}

@test "content_find_zips: locates zips nested under subdirs" {
  mkdir -p "$TEST_DIR/extract/some/nested/dir"
  touch "$TEST_DIR/extract/some/nested/dir/bar-2.0-manifests.zip"
  touch "$TEST_DIR/extract/some/bar-2.0-contract.zip"
  run -0 bash -c "
    source '$LIB_DIR/content-resolve.bash'
    content_find_zips '$TEST_DIR/extract'
    echo MZ=\${CONTENT_MANIFESTS_ZIP}
    echo CZ=\${CONTENT_CONTRACT_ZIP}
  "
  echo "$output" | grep -q "MZ=.*bar-2.0-manifests.zip"
  echo "$output" | grep -q "CZ=.*bar-2.0-contract.zip"
}

@test "content_find_zips: fails when manifests zip missing" {
  mkdir -p "$TEST_DIR/extract"
  touch "$TEST_DIR/extract/foo-1.0-contract.zip"
  run content_find_zips "$TEST_DIR/extract"
  [ "$status" -ne 0 ]
}

@test "content_find_zips: fails when contract zip missing" {
  mkdir -p "$TEST_DIR/extract"
  touch "$TEST_DIR/extract/foo-1.0-manifests.zip"
  run content_find_zips "$TEST_DIR/extract"
  [ "$status" -ne 0 ]
}

@test "content_find_zips: fails when two manifests zips found" {
  mkdir -p "$TEST_DIR/extract"
  touch "$TEST_DIR/extract/a-manifests.zip"
  touch "$TEST_DIR/extract/b-manifests.zip"
  touch "$TEST_DIR/extract/foo-contract.zip"
  run content_find_zips "$TEST_DIR/extract"
  [ "$status" -ne 0 ]
}

@test "content_find_zips: fails on missing directory" {
  run content_find_zips "$TEST_DIR/nonexistent"
  [ "$status" -ne 0 ]
}

# =============================================================================
# content_unzip_manifests
# =============================================================================

@test "content_unzip_manifests: extracts and reports project name" {
  mkdir -p "$TEST_DIR/zips" "$TEST_DIR/unzipped/foo" "$TEST_DIR/staged"
  make_manifests_zip "$TEST_DIR/zips/foo-1.0-manifests.zip" "foo"

  run -0 bash -c "
    source '$LIB_DIR/content-resolve.bash'
    content_unzip_manifests '$TEST_DIR/zips/foo-1.0-manifests.zip' '$TEST_DIR/unzipped/foo' '$TEST_DIR/staged'
    echo PROJECT=\${CONTENT_PROJECT_NAME}
  "
  echo "$output" | grep -q "PROJECT=foo"
  [ -f "$TEST_DIR/staged/foo/deployment.yaml" ]
  [ -f "$TEST_DIR/unzipped/foo/foo/deployment.yaml" ]
}

@test "content_unzip_manifests: stages multiple bundles as siblings" {
  mkdir -p "$TEST_DIR/zips" "$TEST_DIR/unzipped/foo" "$TEST_DIR/unzipped/bar" "$TEST_DIR/staged"
  make_manifests_zip "$TEST_DIR/zips/foo-1.0-manifests.zip" "foo"
  make_manifests_zip "$TEST_DIR/zips/bar-2.0-manifests.zip" "bar"

  source "$LIB_DIR/content-resolve.bash"
  content_unzip_manifests "$TEST_DIR/zips/foo-1.0-manifests.zip" "$TEST_DIR/unzipped/foo" "$TEST_DIR/staged"
  content_unzip_manifests "$TEST_DIR/zips/bar-2.0-manifests.zip" "$TEST_DIR/unzipped/bar" "$TEST_DIR/staged"

  [ -f "$TEST_DIR/staged/foo/deployment.yaml" ]
  [ -f "$TEST_DIR/staged/bar/deployment.yaml" ]
}

@test "content_unzip_manifests: fails when project already staged" {
  mkdir -p "$TEST_DIR/zips" "$TEST_DIR/unzipped/foo" "$TEST_DIR/staged/foo"
  touch "$TEST_DIR/staged/foo/preexisting"
  make_manifests_zip "$TEST_DIR/zips/foo-1.0-manifests.zip" "foo"

  run content_unzip_manifests "$TEST_DIR/zips/foo-1.0-manifests.zip" "$TEST_DIR/unzipped/foo" "$TEST_DIR/staged"
  [ "$status" -ne 0 ]
}

@test "content_unzip_manifests: fails on missing zip" {
  run content_unzip_manifests "$TEST_DIR/nonexistent.zip" "$TEST_DIR/unzipped" "$TEST_DIR/staged"
  [ "$status" -ne 0 ]
}

# =============================================================================
# content_unzip_contract
# =============================================================================

@test "content_unzip_contract: extracts contract.yaml to per-project dir" {
  mkdir -p "$TEST_DIR/zips" "$TEST_DIR/unzipped/foo" "$TEST_DIR/contracts" "$TEST_DIR/defaults"
  make_contract_zip "$TEST_DIR/zips/foo-1.0-contract.zip"

  source "$LIB_DIR/content-resolve.bash"
  content_unzip_contract "$TEST_DIR/zips/foo-1.0-contract.zip" \
    "$TEST_DIR/unzipped/foo" "$TEST_DIR/contracts" "$TEST_DIR/defaults" "foo"

  [ -f "$TEST_DIR/contracts/foo/contract.yaml" ]
  grep -q "kind: kubernetes-bundle" "$TEST_DIR/contracts/foo/contract.yaml"
  [ -f "$TEST_DIR/unzipped/foo/contract.yaml" ]
}

@test "content_unzip_contract: stages defaults files into per-project dir" {
  mkdir -p "$TEST_DIR/zips" "$TEST_DIR/unzipped/foo" "$TEST_DIR/contracts" "$TEST_DIR/defaults"
  make_contract_zip "$TEST_DIR/zips/foo-1.0-contract.zip" \
    "Replicas=3" "MaxHeapSize=512Mi"

  source "$LIB_DIR/content-resolve.bash"
  content_unzip_contract "$TEST_DIR/zips/foo-1.0-contract.zip" \
    "$TEST_DIR/unzipped/foo" "$TEST_DIR/contracts" "$TEST_DIR/defaults" "foo"

  [ -f "$TEST_DIR/defaults/foo/Replicas" ]
  [ "$(cat "$TEST_DIR/defaults/foo/Replicas")" = "3" ]
  [ -f "$TEST_DIR/defaults/foo/MaxHeapSize" ]
  [ "$(cat "$TEST_DIR/defaults/foo/MaxHeapSize")" = "512Mi" ]
  [ -f "$TEST_DIR/unzipped/foo/defaults/Replicas" ]
}

@test "content_unzip_contract: handles zip without defaults dir" {
  mkdir -p "$TEST_DIR/zips" "$TEST_DIR/unzipped/foo" "$TEST_DIR/contracts" "$TEST_DIR/defaults"
  make_contract_zip "$TEST_DIR/zips/foo-1.0-contract.zip"

  source "$LIB_DIR/content-resolve.bash"
  content_unzip_contract "$TEST_DIR/zips/foo-1.0-contract.zip" \
    "$TEST_DIR/unzipped/foo" "$TEST_DIR/contracts" "$TEST_DIR/defaults" "foo"

  [ -f "$TEST_DIR/contracts/foo/contract.yaml" ]
  [ ! -d "$TEST_DIR/defaults/foo" ]
}

@test "content_unzip_contract: fails on missing zip" {
  run bash -c "
    source '$LIB_DIR/content-resolve.bash'
    content_unzip_contract '$TEST_DIR/nope.zip' '$TEST_DIR/u' '$TEST_DIR/c' '$TEST_DIR/d' 'foo'
  "
  [ "$status" -ne 0 ]
}

@test "content_unzip_contract: fails when project name is empty" {
  mkdir -p "$TEST_DIR/zips"
  make_contract_zip "$TEST_DIR/zips/foo-1.0-contract.zip"
  run bash -c "
    source '$LIB_DIR/content-resolve.bash'
    content_unzip_contract '$TEST_DIR/zips/foo-1.0-contract.zip' '$TEST_DIR/u' '$TEST_DIR/c' '$TEST_DIR/d' ''
  "
  [ "$status" -ne 0 ]
}

# =============================================================================
# content_resolve_all - orchestrator (uses PATH-injected mocks)
# =============================================================================

# Set up mock util scripts that the library calls.
# - artifact-resolve writes the input verbatim to the output file (already-resolved fixtures).
# - extract-oci-image copies pre-staged zips from $MOCK_OCI_DIR into the output dir.
setup_mock_utils() {
  export MOCK_BIN_DIR="${TEST_TARGET_DIR}/$(basename "${BATS_TEST_FILENAME}" .bats)/mock-bin-utils-$$"
  mkdir -p "${MOCK_BIN_DIR}"

  # Mock artifact-resolve: writes its first arg to its second arg, appending
  # `-${variant}` if a third arg is given (mirroring the real resolver's
  # variant-suffix reconstruction).
  cat > "${MOCK_BIN_DIR}/artifact-resolve" << 'MOCK'
#!/usr/bin/env bash
ref="$1"
out="$2"
variant="${3:-}"
if [[ -n "${variant}" ]]; then
  echo "${ref}-${variant}" > "${out}"
else
  echo "${ref}" > "${out}"
fi
MOCK
  chmod +x "${MOCK_BIN_DIR}/artifact-resolve"

  # Mock extract-oci-image: copies pre-staged content from MOCK_OCI_DIR/<sanitized-uri> into output-dir.
  cat > "${MOCK_BIN_DIR}/extract-oci-image" << 'MOCK'
#!/usr/bin/env bash
image_uri="$1"
out_dir="$2"
mkdir -p "${out_dir}"
key=$(echo "${image_uri}" | tr '/:' '__')
src="${MOCK_OCI_DIR}/${key}"
if [[ ! -d "${src}" ]]; then
  echo "mock extract-oci-image: no fixture for key ${key} (uri ${image_uri})" >&2
  exit 1
fi
cp -R "${src}/." "${out_dir}/"
MOCK
  chmod +x "${MOCK_BIN_DIR}/extract-oci-image"

  # Override the library's util dir to point at our mocks
  CONTENT_RESOLVE_UTIL_DIR="${MOCK_BIN_DIR}"
}

# Stage a fake OCI image fixture under MOCK_OCI_DIR keyed by URI.
# Pre-creates the manifests + contract zips inside.
stage_oci_fixture() {
  local manifests_uri="$1"
  local project="$2"
  local key
  key=$(echo "${manifests_uri}" | tr '/:' '__')
  local fixture_dir="${MOCK_OCI_DIR}/${key}"
  mkdir -p "${fixture_dir}"
  make_manifests_zip "${fixture_dir}/${project}-1.0-manifests.zip" "${project}"
  make_contract_zip "${fixture_dir}/${project}-1.0-contract.zip" "Replicas=2"
}

@test "content_resolve_all: empty spec.contents is a no-op" {
  cat > "$TEST_DIR/kp.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
metadata:
  name: product-foo
spec:
  contents: []
EOF

  source "$LIB_DIR/content-resolve.bash"
  run content_resolve_all "$TEST_DIR/kp.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No contents entries"
  # Empty list still produces the summary files for consumer reliability.
  [ -f "$TEST_DIR/contents/contents.yaml" ]
  [ -f "$TEST_DIR/contents/contents-resolved.yaml" ]
  [ ! -s "$TEST_DIR/contents/contents.yaml" ]
  [ ! -s "$TEST_DIR/contents/contents-resolved.yaml" ]
}

@test "content_resolve_all: missing spec.contents is a no-op" {
  cat > "$TEST_DIR/kp.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
metadata:
  name: product-foo
spec:
  global:
    tokens:
      delimiterStyle: shell
      nameStyle: PascalCase
EOF
  source "$LIB_DIR/content-resolve.bash"
  run content_resolve_all "$TEST_DIR/kp.yaml"
  [ "$status" -eq 0 ]
}

@test "content_resolve_all: fails when KaptainPM file missing" {
  source "$LIB_DIR/content-resolve.bash"
  run content_resolve_all "$TEST_DIR/missing.yaml"
  [ "$status" -ne 0 ]
}

@test "content_resolve_all: fails on missing arguments" {
  source "$LIB_DIR/content-resolve.bash"
  run content_resolve_all
  [ "$status" -ne 0 ]
}

@test "content_resolve_all: stages a single bundle end to end" {
  source "$LIB_DIR/content-resolve.bash"
  setup_mock_utils
  export MOCK_OCI_DIR="${TEST_DIR}/oci-fixtures"
  mkdir -p "${MOCK_OCI_DIR}"

  # The library calls artifact-resolve with variant=manifests; mock returns
  # "foo:1.0-manifests" which extract-oci-image then pulls.
  stage_oci_fixture "foo:1.0-manifests" "foo"

  cat > "$TEST_DIR/kp.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
spec:
  contents:
    - foo:1.0
EOF

  run content_resolve_all "$TEST_DIR/kp.yaml"
  [ "$status" -eq 0 ]

  [ -f "$TEST_DIR/contents/manifests/foo/deployment.yaml" ]
  [ -f "$TEST_DIR/contents/contracts/foo/contract.yaml" ]
  [ -f "$TEST_DIR/contents/defaults/foo/Replicas" ]

  # Summary files written.
  [ -f "$TEST_DIR/contents/contents.yaml" ]
  [ -f "$TEST_DIR/contents/contents-resolved.yaml" ]
  grep -qx -- "- foo:1.0" "$TEST_DIR/contents/contents.yaml"
  grep -qx -- "- foo:1.0-manifests" "$TEST_DIR/contents/contents-resolved.yaml"

  # Audit trail preserved.
  local slug
  slug=$(echo "foo:1.0-manifests" | tr '/:' '__')
  [ -f "$TEST_DIR/contents/extract/${slug}/foo-1.0-manifests.zip" ]
  [ -f "$TEST_DIR/contents/extract/${slug}/foo-1.0-contract.zip" ]
  [ -f "$TEST_DIR/contents/extract/${slug}/resolved-uri" ]
  [ -f "$TEST_DIR/contents/unzipped/${slug}/contract.yaml" ]
  [ -f "$TEST_DIR/contents/unzipped/${slug}/foo/deployment.yaml" ]
}

@test "content_resolve_all: stages two bundles into sibling subdirs" {
  source "$LIB_DIR/content-resolve.bash"
  setup_mock_utils
  export MOCK_OCI_DIR="${TEST_DIR}/oci-fixtures"
  mkdir -p "${MOCK_OCI_DIR}"

  stage_oci_fixture "alpha:1.0-manifests" "alpha"
  stage_oci_fixture "beta:2.0-manifests"  "beta"

  cat > "$TEST_DIR/kp.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
spec:
  contents:
    - alpha:1.0
    - beta:2.0
EOF

  run content_resolve_all "$TEST_DIR/kp.yaml"
  [ "$status" -eq 0 ]

  [ -f "$TEST_DIR/contents/manifests/alpha/deployment.yaml" ]
  [ -f "$TEST_DIR/contents/manifests/beta/deployment.yaml" ]
  [ -f "$TEST_DIR/contents/contracts/alpha/contract.yaml" ]
  [ -f "$TEST_DIR/contents/contracts/beta/contract.yaml" ]
  [ -f "$TEST_DIR/contents/defaults/alpha/Replicas" ]
  [ -f "$TEST_DIR/contents/defaults/beta/Replicas" ]
}

@test "content_resolve_all: fails when extracted image is missing a zip" {
  source "$LIB_DIR/content-resolve.bash"
  setup_mock_utils
  export MOCK_OCI_DIR="${TEST_DIR}/oci-fixtures"
  mkdir -p "${MOCK_OCI_DIR}"

  # Stage a fixture missing the contract zip
  local key
  key=$(echo "broken:1.0-manifests" | tr '/:' '__')
  mkdir -p "${MOCK_OCI_DIR}/${key}"
  make_manifests_zip "${MOCK_OCI_DIR}/${key}/broken-1.0-manifests.zip" "broken"

  cat > "$TEST_DIR/kp.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
spec:
  contents:
    - broken:1.0
EOF

  run content_resolve_all "$TEST_DIR/kp.yaml"
  [ "$status" -ne 0 ]
}

@test "content_resolve_all: leaves audit trail under extract/ and unzipped/" {
  source "$LIB_DIR/content-resolve.bash"
  setup_mock_utils
  export MOCK_OCI_DIR="${TEST_DIR}/oci-fixtures"
  mkdir -p "${MOCK_OCI_DIR}"

  stage_oci_fixture "foo:1.0-manifests" "foo"

  cat > "$TEST_DIR/kp.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
spec:
  contents:
    - foo:1.0
EOF

  run content_resolve_all "$TEST_DIR/kp.yaml"
  [ "$status" -eq 0 ]

  # The audit trail under content/extract/<slug> and content/unzipped/<slug>.
  local slug
  slug=$(echo "foo:1.0-manifests" | tr '/:' '__')
  [ -d "$TEST_DIR/contents/extract/${slug}" ]
  [ -d "$TEST_DIR/contents/unzipped/${slug}" ]
  [ -f "$TEST_DIR/contents/extract/${slug}/foo-1.0-manifests.zip" ]
  [ -f "$TEST_DIR/contents/extract/${slug}/foo-1.0-contract.zip" ]
  [ -f "$TEST_DIR/contents/extract/${slug}/resolved-uri" ]
  [ "$(cat "$TEST_DIR/contents/extract/${slug}/resolved-uri")" = "foo:1.0-manifests" ]
  [ -f "$TEST_DIR/contents/unzipped/${slug}/contract.yaml" ]
}

teardown() {
  dump_bats_result
}

# --- content_validate_bundle: deploy-time context tokens ----------------------
# Kaptain writes ${Environment}, ${ProductName} and siblings into every bundle's
# labels and lineage; the product or environment build that deploys the bundle
# resolves them. A contract cannot declare them, so the undeclared-token check
# must exempt exactly that family and nothing else.

# Helper: lay out <root>/{contracts,defaults,manifests}/<project>/ with a
# contract in the given name style and one manifest using the given tokens.
make_bundle_dirs() {
  local root="$1" project="$2" name_style="$3"
  shift 3
  mkdir -p "${root}/contracts/${project}" "${root}/defaults/${project}" "${root}/manifests/${project}"
  printf '%s\n' \
    'apiVersion: kaptain.org/manifests-contract/1.2' \
    'kind: kubernetes-bundle' \
    'tokens:' \
    '  delimiterStyle: shell' \
    "  nameStyle: ${name_style}" \
    'compatibility:' \
    '  automaticConversion: []' \
    '  repackageRequired: []' > "${root}/contracts/${project}/contract.yaml"
  {
    printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: lineage' 'data:'
    local i=0 token
    for token in "$@"; do
      printf '  k%s: "${%s}"\n' "${i}" "${token}"
      i=$((i + 1))
    done
  } > "${root}/manifests/${project}/lineage.yaml"
}

@test "content_validate_bundle: accepts the deploy-time context family undeclared" {
  local root="${TEST_DIR}/deploy-time"
  make_bundle_dirs "${root}" app PascalCase \
    Environment EnvironmentName EnvironmentShortName EnvironmentType ProductName ProductShortName
  run content_validate_bundle app "${root}/contracts" "${root}/defaults" "${root}/manifests"
  [ "$status" -eq 0 ]
}

@test "content_validate_bundle: still rejects a real config token left undeclared" {
  local root="${TEST_DIR}/undeclared"
  make_bundle_dirs "${root}" app PascalCase Environment ProductName DatabaseUrl
  run content_validate_bundle app "${root}/contracts" "${root}/defaults" "${root}/manifests"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not declared in contract .config.required"* ]]
  [[ "$output" == *"DatabaseUrl"* ]]
  # Only the real token is reported; the deploy-time ones are not.
  [[ "$output" != *"  Environment"* ]]
  [[ "$output" != *"  ProductName"* ]]
}

@test "content_validate_bundle: exempts the deploy-time family in the bundle's own name style" {
  local root="${TEST_DIR}/upper-snake"
  make_bundle_dirs "${root}" app UPPER_SNAKE ENVIRONMENT PRODUCT_NAME
  run content_validate_bundle app "${root}/contracts" "${root}/defaults" "${root}/manifests"
  [ "$status" -eq 0 ]
}
