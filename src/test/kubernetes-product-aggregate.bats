#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/kubernetes-product-aggregate.
#
# Covers product-naming validation, products-in-products rejection, end-to-end
# staging via mocked OCI fetches, per-bundle scheme conversion routing, and
# cross-bundle defaults conflict detection / merge.

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/kubernetes-product-aggregate"

setup() {
  TEST_DIR=$(create_test_dir "kubernetes-product-aggregate")
  mkdir -p "${TEST_DIR}/kaptainpm/final"
  export GITHUB_OUTPUT="${TEST_DIR}/github-output"
  : > "${GITHUB_OUTPUT}"
}

# Write a KaptainPM.yaml with optional spec.contents entries.
write_pm() {
  local pm_file="${TEST_DIR}/kaptainpm/final/KaptainPM.yaml"
  cat > "${pm_file}" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
spec:
  global:
    tokens:
      delimiterStyle: shell
      nameStyle: PascalCase
EOF
  if [[ $# -gt 0 ]]; then
    {
      echo "  contents:"
      local entry
      for entry in "$@"; do
        echo "    - ${entry}"
      done
    } >> "${pm_file}"
  fi
}

# Build a manifests zip with a single deployment.yaml that references one
# token in the given scheme. Default token: ${Replicas} (shell-PascalCase).
make_manifests_zip() {
  local zip_path="$1"
  local project="$2"
  local token_ref="${3:-\${Replicas}}"
  local stage="${TEST_DIR}/_stage-mz-$$-${RANDOM}"
  mkdir -p "${stage}/${project}"
  cat > "${stage}/${project}/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${project}
spec:
  replicas: ${token_ref}
EOF
  ( cd "${stage}" && zip -qr "${zip_path}" "${project}" )
  rm -rf "${stage}"
}

# Build a contract zip carrying tokens.delimiterStyle / tokens.nameStyle and
# optional defaults files. .config.required is always auto-populated with
# 'Replicas' (the default token in make_manifests_zip) plus each default
# name, so the bundle passes content_validate_bundle's defaults-orphan and
# manifest-token-coverage checks.
# Args: zip_path, delim, name, [token=value]...
make_contract_zip() {
  local zip_path="$1"
  local delim="$2"
  local name="$3"
  shift 3
  local stage="${TEST_DIR}/_stage-cz-$$-${RANDOM}"
  mkdir -p "${stage}"
  cat > "${stage}/contract.yaml" << EOF
apiVersion: kaptain.org/manifests-contract/1.2
kind: kubernetes-bundle
tokens:
  delimiterStyle: ${delim}
  nameStyle: ${name}
compatibility:
  automaticConversion: []
  repackageRequired: []
config:
  required:
    - Replicas
EOF
  if [[ $# -gt 0 ]]; then
    mkdir -p "${stage}/defaults"
    local pair token value
    for pair in "$@"; do
      token="${pair%%=*}"
      value="${pair#*=}"
      if [[ "${token}" != "Replicas" ]]; then
        printf '    - %s\n' "${token}" >> "${stage}/contract.yaml"
      fi
      printf '%s' "${value}" > "${stage}/defaults/${token}"
    done
  fi
  ( cd "${stage}" && zip -qr "${zip_path}" . )
  rm -rf "${stage}"
}

# Stand up mocks for util/artifact-resolve and util/extract-oci-image so the
# library doesn't need to talk to a real registry. Returns paths via globals
# MOCK_UTIL_DIR (for CONTENT_RESOLVE_UTIL_DIR) and MOCK_OCI_DIR.
setup_mock_oci() {
  MOCK_UTIL_DIR="${TEST_DIR}/mock-util-bin"
  MOCK_OCI_DIR="${TEST_DIR}/oci-fixtures"
  mkdir -p "${MOCK_UTIL_DIR}" "${MOCK_OCI_DIR}"

  cat > "${MOCK_UTIL_DIR}/artifact-resolve" << 'MOCK'
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
  chmod +x "${MOCK_UTIL_DIR}/artifact-resolve"

  cat > "${MOCK_UTIL_DIR}/extract-oci-image" << 'MOCK'
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
  chmod +x "${MOCK_UTIL_DIR}/extract-oci-image"

  # content_validate_bundle calls the real scan-unresolved-tokens utility via
  # CONTENT_RESOLVE_UTIL_DIR. It is pure local computation, not something
  # that needs mocking, so symlink the real one into the mock util dir.
  ln -sf "${SCRIPTS_DIR}/util/scan-unresolved-tokens" "${MOCK_UTIL_DIR}/scan-unresolved-tokens"
}

# Stage a fake OCI image fixture: pre-create the manifests + contract zips
# inside MOCK_OCI_DIR keyed by the URI the library is going to ask for.
# Args: manifests_uri, project, contract_delim, contract_name, [token=value]...
stage_oci_fixture() {
  local manifests_uri="$1"
  local project="$2"
  local delim="$3"
  local name="$4"
  shift 4
  local key
  key=$(echo "${manifests_uri}" | tr '/:' '__')
  local fixture_dir="${MOCK_OCI_DIR}/${key}"
  mkdir -p "${fixture_dir}"
  make_manifests_zip "${fixture_dir}/${project}-1.0-manifests.zip" "${project}"
  make_contract_zip "${fixture_dir}/${project}-1.0-contract.zip" \
    "${delim}" "${name}" "$@"
}

run_script() {
  : "${PROJECT_NAME=product-foo}"
  : "${OUTPUT_SUB_PATH:=kaptain-out}"
  : "${TOKEN_DELIMITER_STYLE:=shell}"
  : "${TOKEN_NAME_STYLE:=PascalCase}"
  run env \
    PROJECT_NAME="${PROJECT_NAME}" \
    OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH}" \
    TOKEN_DELIMITER_STYLE="${TOKEN_DELIMITER_STYLE}" \
    TOKEN_NAME_STYLE="${TOKEN_NAME_STYLE}" \
    BUILD_PLATFORM=test \
    GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
    KAPTAINPM_FILE="${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" \
    CONTENT_RESOLVE_UTIL_DIR="${MOCK_UTIL_DIR:-}" \
    MOCK_OCI_DIR="${MOCK_OCI_DIR:-}" \
    bash -c "cd '${TEST_DIR}' && '${SCRIPT}'"
}

github_output_value() {
  grep "^${1}=" "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-
}

# =============================================================================
# Naming validation
# =============================================================================

@test "naming: accepts product- prefix" {
  PROJECT_NAME=product-foo write_pm
  PROJECT_NAME=product-foo run_script
  [ "${status}" -eq 0 ]
  [ "$(github_output_value PRODUCT_NAME)" = "product-foo" ]
  [ "$(github_output_value PRODUCT_SHORT_NAME)" = "foo" ]
}

@test "naming: accepts -product suffix" {
  PROJECT_NAME=foo-product write_pm
  PROJECT_NAME=foo-product run_script
  [ "${status}" -eq 0 ]
  [ "$(github_output_value PRODUCT_NAME)" = "foo-product" ]
  [ "$(github_output_value PRODUCT_SHORT_NAME)" = "foo" ]
}

@test "naming: rejects neither prefix nor suffix" {
  PROJECT_NAME=foo write_pm
  PROJECT_NAME=foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "does not match the product naming rule"
}

@test "naming: rejects ambiguous product-foo-product" {
  PROJECT_NAME=product-foo-product write_pm
  PROJECT_NAME=product-foo-product run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "ambiguous"
}

@test "naming: rejects empty PROJECT_NAME" {
  write_pm
  PROJECT_NAME="" run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "PROJECT_NAME"
}

# =============================================================================
# Products in products
# =============================================================================

@test "products-in-products: rejects entry whose repo starts with product-" {
  write_pm "product-other:1.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Including a product inside another product"
  assert_output_contains "product-other:1.0"
}

@test "products-in-products: rejects entry whose repo ends with -product" {
  write_pm "ghcr.io/org/sub/some-product:9.9"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Including a product inside another product"
  assert_output_contains "some-product"
}

@test "envs-in-products: rejects entry whose repo starts with run-" {
  write_pm "run-some-env:1.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Including a run-* or run-platform-* project inside a product"
  assert_output_contains "run-some-env:1.0"
}

@test "envs-in-products: rejects entry whose repo starts with run-platform-" {
  write_pm "ghcr.io/org/run/run-platform-foo:2.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Including a run-* or run-platform-* project inside a product"
  assert_output_contains "run-platform-foo:2.0"
}

@test "composition: reports every offending entry of both kinds before failing" {
  write_pm "product-one:1.0" "run-two:1.0" "alpha:1.0" "three-product:1.0" "run-platform-four:1.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Including a product inside another product"
  assert_output_contains "Including a run-* or run-platform-* project inside a product"
  assert_output_contains "Offending entry: product-one:1.0"
  assert_output_contains "Offending entry: three-product:1.0"
  assert_output_contains "Offending entry: run-two:1.0"
  assert_output_contains "Offending entry: run-platform-four:1.0"
  [ "$(grep -c 'Offending entry: alpha' <<< "${output}")" -eq 0 ]
}

@test "products-in-products: accepts non-product entries" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
}

# =============================================================================
# Duplicate spec.contents
# =============================================================================

@test "duplicate spec.contents: same name different versions is rejected" {
  setup_mock_oci
  write_pm "alpha:1.0" "alpha:2.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "spec.contents contains duplicate"
  assert_output_contains "alpha"
}

@test "duplicate spec.contents: same name across different namespaces is rejected" {
  setup_mock_oci
  write_pm "ghcr.io/org-a/alpha:1.0" "ghcr.io/org-b/alpha:2.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "spec.contents contains duplicate"
  assert_output_contains "alpha"
}

# =============================================================================
# Empty spec.contents
# =============================================================================

@test "spec.contents empty: still emits PRODUCT_NAME and clears staging" {
  write_pm
  setup_mock_oci
  run_script
  [ "${status}" -eq 0 ]
  [ "$(github_output_value PRODUCT_NAME)" = "product-foo" ]
  [ -d "${TEST_DIR}/kaptain-out/contents/manifests" ]
}

# Builtin tokens for the product/ scan in prepare-substitution-tokens - on-disk
# delivery reaches every downstream substitution context without per-call-site
# env plumbing (which failed silently when a call site was missed).
@test "writes PRODUCT_NAME and PRODUCT_SHORT_NAME under builtin-resolved-tokens/product/" {
  write_pm
  setup_mock_oci
  run_script
  [ "${status}" -eq 0 ]

  # Filenames are written in the configured TOKEN_NAME_STYLE (PascalCase by default)
  local product_dir="${TEST_DIR}/kaptain-out/builtin-resolved-tokens/product"
  [ -f "${product_dir}/ProductName" ]
  [ "$(cat "${product_dir}/ProductName")" = "product-foo" ]
  [ -f "${product_dir}/ProductShortName" ]
  [ "$(cat "${product_dir}/ProductShortName")" = "foo" ]
}

# =============================================================================
# End-to-end staging
# =============================================================================

@test "end-to-end: stages a single bundle into additional-manifests + additional-defaults" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/contents/manifests/alpha/deployment.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/manifests/additional-defaults/Replicas" ]
  [ "$(cat "${TEST_DIR}/kaptain-out/manifests/additional-defaults/Replicas")" = "2" ]
  [ -f "${TEST_DIR}/kaptain-out/manifests/additional-manifests/alpha/deployment.yaml" ]

  # Entry builtins: Version is spec-shaped (variant suffix stripped from the
  # resolved tag); ManifestsDockerTag records the pulled artifact verbatim.
  local contents_tokens="${TEST_DIR}/kaptain-out/builtin-resolved-tokens/contents"
  [ "$(cat "${contents_tokens}/ContentAlphaVersion")" = "1.0" ]
  [ "$(cat "${contents_tokens}/ContentAlphaManifestsDockerTag")" = "1.0-manifests" ]
}

@test "end-to-end: stages two bundles into sibling subdirs" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_oci_fixture "beta:2.0-manifests"  "beta"  shell PascalCase "MaxHeapSize=512Mi"
  write_pm "alpha:1.0" "beta:2.0"
  run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/contents/manifests/alpha/deployment.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/manifests/beta/deployment.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/manifests/additional-defaults/Replicas" ]
  [ -f "${TEST_DIR}/kaptain-out/manifests/additional-defaults/MaxHeapSize" ]
}

@test "end-to-end: leaves audit trail under contents/extract and contents/unzipped" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_oci_fixture "beta:2.0-manifests"  "beta"  shell PascalCase "MaxHeapSize=512Mi"
  write_pm "alpha:1.0" "beta:2.0"
  run_script
  [ "${status}" -eq 0 ]

  local alpha_slug beta_slug
  alpha_slug=$(echo "alpha:1.0-manifests" | tr '/:' '__')
  beta_slug=$(echo "beta:2.0-manifests" | tr '/:' '__')

  [ -d "${TEST_DIR}/kaptain-out/contents/extract/${alpha_slug}" ]
  [ -d "${TEST_DIR}/kaptain-out/contents/extract/${beta_slug}" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/extract/${alpha_slug}/alpha-1.0-manifests.zip" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/extract/${alpha_slug}/alpha-1.0-contract.zip" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/extract/${alpha_slug}/resolved-uri" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/extract/${beta_slug}/beta-1.0-manifests.zip" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/extract/${beta_slug}/beta-1.0-contract.zip" ]

  [ -d "${TEST_DIR}/kaptain-out/contents/unzipped/${alpha_slug}" ]
  [ -d "${TEST_DIR}/kaptain-out/contents/unzipped/${beta_slug}" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/unzipped/${alpha_slug}/contract.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/unzipped/${alpha_slug}/alpha/deployment.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/unzipped/${beta_slug}/contract.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/contents/unzipped/${beta_slug}/beta/deployment.yaml" ]
}

# =============================================================================
# Cross-bundle defaults conflict detection
# =============================================================================

@test "defaults: byte-identical values from two bundles collapse" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_oci_fixture "beta:2.0-manifests"  "beta"  shell PascalCase "Replicas=2"
  write_pm "alpha:1.0" "beta:2.0"
  run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/manifests/additional-defaults/Replicas" ]
  [ "$(cat "${TEST_DIR}/kaptain-out/manifests/additional-defaults/Replicas")" = "2" ]
}

@test "defaults: differing values across bundles fails with diagnostic" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_oci_fixture "beta:2.0-manifests"  "beta"  shell PascalCase "Replicas=3"
  write_pm "alpha:1.0" "beta:2.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Default value collision for token 'Replicas'"
  assert_output_contains "alpha"
  assert_output_contains "beta"
}

# =============================================================================
# Per-bundle scheme conversion
# =============================================================================

@test "scheme: bundle scheme matches product is a no-op" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Token scheme matches."
}

@test "scheme: differing scheme that auto-converts is rewritten" {
  setup_mock_oci
  # Bundle was built in mustache-PascalCase: {{Replicas}}; product wants
  # shell-PascalCase: ${Replicas}. assess-token-compatibility should rate
  # this AUTOMATIC_CONVERSION.
  local key="alpha:1.0-manifests"
  local sanitised
  sanitised=$(echo "${key}" | tr '/:' '__')
  mkdir -p "${MOCK_OCI_DIR}/${sanitised}"
  # Manifest with mustache-style token reference
  local stage="${TEST_DIR}/_stage-alpha-mustache"
  mkdir -p "${stage}/alpha"
  cat > "${stage}/alpha/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  replicas: {{ Replicas }}
EOF
  ( cd "${stage}" && zip -qr "${MOCK_OCI_DIR}/${sanitised}/alpha-1.0-manifests.zip" alpha )
  rm -rf "${stage}"
  make_contract_zip "${MOCK_OCI_DIR}/${sanitised}/alpha-1.0-contract.zip" \
    mustache PascalCase "Replicas=2"

  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  # Bundle's manifest should now use shell-style ${Replicas}, not {{Replicas}}.
  grep -q '\${Replicas}' "${TEST_DIR}/kaptain-out/manifests/additional-manifests/alpha/deployment.yaml"
  ! grep -q '{{ Replicas }}' "${TEST_DIR}/kaptain-out/manifests/additional-manifests/alpha/deployment.yaml"
}

@test "scheme: bundle missing contract.yaml fails the build" {
  setup_mock_oci
  # Only stage manifests zip; no contract zip — content_resolve_all itself
  # will fail because both zips are required.
  local key
  key=$(echo "alpha:1.0-manifests" | tr '/:' '__')
  mkdir -p "${MOCK_OCI_DIR}/${key}"
  make_manifests_zip "${MOCK_OCI_DIR}/${key}/alpha-1.0-manifests.zip" "alpha"
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -ne 0 ]
}

# =============================================================================
# Contents list for GitHub release notes
# =============================================================================

@test "contents-list: writes bullets for every spec.contents entry verbatim" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase
  stage_oci_fixture "ghcr.io/org/sub/beta:2.0-manifests" "beta" shell PascalCase
  write_pm "alpha:1.0" "ghcr.io/org/sub/beta:2.0"
  run_script
  [ "${status}" -eq 0 ]
  local list="${TEST_DIR}/kaptain-out/contents/contents.yaml"
  [ -f "${list}" ]
  [ "$(github_output_value PRODUCT_CONTENTS_FILE)" = "kaptain-out/contents/contents.yaml" ]
  grep -qx -- "- alpha:1.0" "${list}"
  grep -qx -- "- ghcr.io/org/sub/beta:2.0" "${list}"
}

@test "contents-list: empty contents writes empty file" {
  setup_mock_oci
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  local list="${TEST_DIR}/kaptain-out/contents/contents.yaml"
  [ -f "${list}" ]
  [ ! -s "${list}" ]
}

# =============================================================================
# Resource envelopes
#
# lib/assert-resource-envelopes.bash has its own suite; these two prove it is
# wired into this build and that it decides the build's exit status. Fixtures
# stage an application contract kind, because the shared stage_oci_fixture
# publishes kubernetes-bundle, which the check skips by design.
# =============================================================================

# Stage an application bundle whose single container either carries a full
# resource envelope or none. Args: manifests_uri, project, envelope (full|none)
stage_app_oci_fixture() {
  local manifests_uri="$1"
  local project="$2"
  local envelope="$3"
  local key
  key=$(echo "${manifests_uri}" | tr '/:' '__')
  local fixture_dir="${MOCK_OCI_DIR}/${key}"
  mkdir -p "${fixture_dir}"

  local stage="${TEST_DIR}/_stage-app-$$-${RANDOM}"
  mkdir -p "${stage}/${project}"
  # ${Replicas} keeps the contract's required-token coverage check satisfied.
  cat > "${stage}/${project}/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${project}
spec:
  replicas: \${Replicas}
  template:
    spec:
      containers:
        - name: ${project}
EOF
  if [[ "${envelope}" == "full" ]]; then
    cat >> "${stage}/${project}/deployment.yaml" << 'EOF'
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
EOF
  fi
  ( cd "${stage}" && zip -qr "${fixture_dir}/${project}-1.0-manifests.zip" "${project}" )
  rm -rf "${stage}"

  local contract_stage="${TEST_DIR}/_stage-appc-$$-${RANDOM}"
  mkdir -p "${contract_stage}"
  cat > "${contract_stage}/contract.yaml" << 'EOF'
apiVersion: kaptain.org/manifests-contract/1.3
kind: kubernetes-app-manifests-only
tokens:
  delimiterStyle: shell
  nameStyle: PascalCase
compatibility:
  automaticConversion: []
  repackageRequired: []
config:
  required:
    - Replicas
EOF
  ( cd "${contract_stage}" && zip -qr "${fixture_dir}/${project}-1.0-contract.zip" . )
  rm -rf "${contract_stage}"
}

@test "envelopes: an application bundle with no requests or limits fails the aggregate" {
  setup_mock_oci
  stage_app_oci_fixture "alpha:1.0-manifests" "alpha" none
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "carry no resource envelope"
  assert_output_contains "container 'alpha'"
  assert_output_contains "requests.cpu"
  assert_output_contains "limits.memory"
}

@test "envelopes: an application bundle declaring all four fields passes" {
  setup_mock_oci
  stage_app_oci_fixture "alpha:1.0-manifests" "alpha" full
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "checking resource envelopes"
}

teardown() {
  dump_bats_result
}
