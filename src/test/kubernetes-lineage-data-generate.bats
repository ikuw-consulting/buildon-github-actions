#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/kubernetes-lineage-data-generate.
#
# Generic across product, app, bundle, and env/rp builds. Dispatches on
# BUILD_KIND (plus ENV_BUILD_SECTION for env/rp), picks the reserved filename,
# role label, and per-kind data files (contents.yaml for products, templates.yaml
# for apps/bundles), then assembles the lineage CM and writes it into the
# substituted product tree post-substitute. Runs after
# kubernetes-manifests-contract-generate and includes contract.yaml verbatim as
# a CM data key. Both lineage and contract are already-substituted, so a
# verbatim copy is enough. The final CM must contain no unresolved tokens. For
# env/rp builds the working dirs are namespaced under ENV_BUILD_SECTION so the
# script can run twice against the same OUTPUT_SUB_PATH.

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/kubernetes-lineage-data-generate"

setup() {
  TEST_DIR=$(create_test_dir "kubernetes-lineage-data-generate")
  export GITHUB_OUTPUT="${TEST_DIR}/github-output"
  : > "${GITHUB_OUTPUT}"
}

# Stage a typical product build at the lineage-data-generate step:
#
#  - KaptainPM.yaml with spec.contents
#  - contents-resolved.yaml from kubernetes-product-aggregate
#  - the tokens dir laid down by prepare-substitution-tokens
#  - a substituted product tree with a pair of workloads
#
# Project name is fixed at product-foo.
stage_product_preconditions() {
  local out="${TEST_DIR}/kaptain-out"

  mkdir -p "${TEST_DIR}/kaptainpm/final"
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-product
spec:
  global:
    tokens:
      delimiterStyle: shell
      nameStyle: PascalCase
  contents:
    - alpha:1.0
    - beta:2.0
EOF

  mkdir -p "${out}/contents"
  cat > "${out}/contents/contents.yaml" << 'EOF'
- alpha:1.0
- beta:2.0
EOF
  cat > "${out}/contents/contents-resolved.yaml" << 'EOF'
- ghcr.io/org/alpha:1.0.0-manifests
- ghcr.io/org/beta:2.0.0-manifests
EOF

  stage_tokens_and_substituted_tree "product-foo"
}

# Stage a typical app or bundle build. spec.templates is staged via the
# templates content-resolve pass (templates.yaml, optionally
# templates-resolved.yaml). Both are currently soft-fail in lineage; the
# fixture stages templates.yaml so the lineage CM has a populated data key.
stage_app_or_bundle_preconditions() {
  local project="$1"
  local out="${TEST_DIR}/kaptain-out"

  mkdir -p "${TEST_DIR}/kaptainpm/final"
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << EOF
apiVersion: kaptain.org/v1
kind: kubernetes-app
spec:
  global:
    tokens:
      delimiterStyle: shell
      nameStyle: PascalCase
  templates:
    - upstream/base:7.0
    - upstream/extras:7.0
EOF

  mkdir -p "${out}/templates"
  cat > "${out}/templates/templates.yaml" << 'EOF'
- upstream/base:7.0
- upstream/extras:7.0
EOF

  stage_tokens_and_substituted_tree "${project}"
}

# Common: tokens dir + substituted tree with a Deployment and Service +
# contract.yaml from kubernetes-manifests-contract-generate (which runs
# immediately before lineage-data-generate).
stage_tokens_and_substituted_tree() {
  local project="$1"
  local out="${TEST_DIR}/kaptain-out"

  mkdir -p "${out}/manifests/config"
  printf '%s' "${project}" > "${out}/manifests/config/ProjectName"
  printf '%s' "1.2.3" > "${out}/manifests/config/Version"
  printf '%s' "${project}" > "${out}/manifests/config/ProductName"
  printf '%s' "${project#product-}" > "${out}/manifests/config/ProductShortName"

  mkdir -p "${out}/manifests/substituted/${project}"
  cat > "${out}/manifests/substituted/${project}/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${project}
spec:
  replicas: 2
EOF
  cat > "${out}/manifests/substituted/${project}/service.yaml" << EOF
apiVersion: v1
kind: Service
metadata:
  name: ${project}
spec:
  ports:
    - port: 80
EOF

  mkdir -p "${out}/manifests/contract"
  cat > "${out}/manifests/contract/contract.yaml" << EOF
apiVersion: kaptain.org/manifests-contract/v1
kind: ${BUILD_KIND:-kubernetes-product-aggregate}
metadata:
  projectName: ${project}
  version: 1.2.3
tokens:
  delimiterStyle: shell
  nameStyle: PascalCase
EOF
}

run_script() {
  : "${PROJECT_NAME=product-foo}"
  : "${VERSION=1.2.3}"
  : "${BUILD_KIND=kubernetes-product-aggregate}"
  : "${ENV_BUILD_SECTION=}"
  : "${PRODUCT_NAME=product-foo}"
  : "${PRODUCT_SHORT_NAME=foo}"
  : "${TOKEN_DELIMITER_STYLE=shell}"
  : "${TOKEN_NAME_STYLE=PascalCase}"
  : "${OUTPUT_SUB_PATH=kaptain-out}"
  run env \
    PROJECT_NAME="${PROJECT_NAME}" \
    VERSION="${VERSION}" \
    BUILD_KIND="${BUILD_KIND}" \
    ENV_BUILD_SECTION="${ENV_BUILD_SECTION}" \
    PRODUCT_NAME="${PRODUCT_NAME}" \
    PRODUCT_SHORT_NAME="${PRODUCT_SHORT_NAME}" \
    TOKEN_DELIMITER_STYLE="${TOKEN_DELIMITER_STYLE}" \
    TOKEN_NAME_STYLE="${TOKEN_NAME_STYLE}" \
    OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH}" \
    ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH="${ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH:-}" \
    ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH="${ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH:-}" \
    GIT_SHA="${GIT_SHA:-}" \
    BUILD_PLATFORM=test \
    GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
    bash -c "cd '${TEST_DIR}' && '${SCRIPT}'"
}

final_lineage_data_path() {
  local project="$1"
  local filename="$2"
  echo "${TEST_DIR}/kaptain-out/manifests/substituted/${project}/${filename}"
}

# =============================================================================
# Product happy path
# =============================================================================

@test "product happy path: produces lineage data CM and copies into substituted product tree" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  [ -f "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")" ]
  [ -f "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/contents.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/contents-resolved.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/lineage-data/generated-configmap/manifests/combined/configmap-lineage-data.yaml" ]
}

@test "product happy path: contract.yaml is included verbatim as a data file" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/contract.yaml"
  [ -f "${file}" ]
  diff -q "${TEST_DIR}/kaptain-out/manifests/contract/contract.yaml" "${file}"
}

@test "product happy path: contents.yaml mirrors spec.contents from KaptainPM" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/contents.yaml"
  grep -q "alpha:1.0" "${file}"
  grep -q "beta:2.0" "${file}"
}

@test "product happy path: contents-resolved.yaml is content-resolve's full-OCI-ref output" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/contents-resolved.yaml"
  grep -q "ghcr.io/org/alpha:1.0.0-manifests" "${file}"
  grep -q "ghcr.io/org/beta:2.0.0-manifests" "${file}"
}

# =============================================================================
# App / bundle happy path
# =============================================================================

@test "app happy path: produces lineage data CM with templates.yaml data file" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  [ -f "$(final_lineage_data_path "myapp" "kaptain-app-lineage-data.yaml")" ]
  [ -f "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/templates.yaml" ]
  # No contents.yaml on app builds
  [ ! -f "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/contents.yaml" ]
}

@test "app happy path: templates.yaml mirrors spec.templates from KaptainPM" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/templates.yaml"
  grep -q "upstream/base:7.0" "${file}"
  grep -q "upstream/extras:7.0" "${file}"
}

@test "app happy path: templates-resolved.yaml staged optionally" {
  stage_app_or_bundle_preconditions "myapp"
  mkdir -p "${TEST_DIR}/kaptain-out/templates"
  cat > "${TEST_DIR}/kaptain-out/templates/templates-resolved.yaml" << 'EOF'
- ghcr.io/upstream/base:7.0.1-manifests
- ghcr.io/upstream/extras:7.0.1-manifests
EOF
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/templates-resolved.yaml"
  [ -f "${file}" ]
  grep -q "ghcr.io/upstream/base:7.0.1-manifests" "${file}"
}

@test "app happy path: templates-resolved.yaml absent is soft-skip" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/templates-resolved.yaml" ]
}

@test "bundle happy path: produces lineage data CM with templates.yaml data file" {
  stage_app_or_bundle_preconditions "mybundle"
  BUILD_KIND=kubernetes-bundle-resources PROJECT_NAME=mybundle \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  [ -f "$(final_lineage_data_path "mybundle" "kaptain-bundle-lineage-data.yaml")" ]
  [ -f "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/templates.yaml" ]
}

# =============================================================================
# resources.yaml inventory
# =============================================================================

@test "resources.yaml: includes every kind/name in the substituted product tree" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "path: deployment.yaml" "${file}"
  grep -q "path: service.yaml" "${file}"
  grep -q "kind: Deployment" "${file}"
  grep -q "kind: Service" "${file}"
}

@test "resources.yaml: includes self-reference for the lineage data ConfigMap" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "path: kaptain-product-lineage-data.yaml" "${file}"
  grep -q "kind: ConfigMap" "${file}"
}

@test "resources.yaml: self-reference name resolved by sub-round substitute" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  # After sub-round substitute the data file should hold the concrete CM name,
  # which is ${ProjectName}-lineage-data (the lineage CM's actual metadata.name).
  ! grep -q '\${ProjectName}' \
    "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "name: product-foo-lineage-data" \
    "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  ! grep -q '\${ProjectName}' \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

@test "resources.yaml: handles a multi-document yaml file" {
  stage_product_preconditions
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/product-foo/multi.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: product-foo-extra-cm
---
apiVersion: v1
kind: Secret
metadata:
  name: product-foo-extra-secret
EOF
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "name: product-foo-extra-cm" "${file}"
  grep -q "name: product-foo-extra-secret" "${file}"
}

# =============================================================================
# resources.yaml: manifests yq cannot parse
#
# Bundles ship partially substituted manifests. A token inside a YAML flow
# sequence or flow mapping makes the file unparseable, which must not lose the
# resource from the inventory.
# =============================================================================

@test "resources.yaml: token in a flow sequence still yields kind and name" {
  stage_product_preconditions
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/product-foo/distribution.yaml" << 'EOF'
apiVersion: cloudfront.services.k8s.aws/v1alpha1
kind: Distribution
metadata:
  name: ${Environment}-env-ext-example-com
spec:
  distributionConfig:
    allowedMethods:
      items: [${RunEnvironment/CloudfrontAllowedMethods}]
EOF
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "path: distribution.yaml" "${file}"
  grep -q "kind: Distribution" "${file}"
}

@test "resources.yaml: token in a flow sequence keeps the other resources too" {
  stage_product_preconditions
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/product-foo/gateway.yaml" << 'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: product-foo-gateway
spec:
  addresses: [${GatewayAddresses}]
EOF
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "kind: Gateway" "${file}"
  grep -q "kind: Deployment" "${file}"
  grep -q "kind: Service" "${file}"
}

@test "resources.yaml: multi-document file with one unparseable document" {
  stage_product_preconditions
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/product-foo/pair.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: product-foo-pair-cm
---
apiVersion: v1
kind: Secret
metadata:
  name: product-foo-pair-secret
stringData:
  hosts: [${Hosts}]
EOF
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "name: product-foo-pair-cm" "${file}"
  grep -q "name: product-foo-pair-secret" "${file}"
}

@test "resources.yaml: valid yaml still read by yq, not the fallback" {
  stage_product_preconditions
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/product-foo/flowmeta.yaml" << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata: {name: product-foo-sa, namespace: default}
EOF
  run_script
  [ "${status}" -eq 0 ]
  local file="${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -q "name: product-foo-sa" "${file}"
}

@test "resources.yaml: file with no kind or name fails the build" {
  stage_product_preconditions
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/product-foo/notamanifest.yaml" << 'EOF'
${ProjectName}
${project-name}
EOF
  run_script
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notamanifest.yaml"* ]] || return 1
}

# =============================================================================
# Metadata: additional labels and annotations
# =============================================================================

@test "metadata (product): kaptain.org/role label is kaptain-product-lineage-data" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/role: \"kaptain-product-lineage-data\"" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

@test "metadata (product): kaptain.org/build-kind label is kubernetes-product-aggregate" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/build-kind: \"kubernetes-product-aggregate\"" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

@test "metadata (product): kaptain.org/project-name label resolves to project name" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/project-name: \"product-foo\"" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

@test "metadata (product): kaptain.org/product-name label resolves to product name" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/product-name: \"product-foo\"" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

@test "metadata (product): kaptain.org/product-short-name label resolves to short name" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/product-short-name: \"foo\"" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

@test "metadata (app): kaptain.org/role label is kaptain-app-lineage-data" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/role: \"kaptain-app-lineage-data\"" \
    "$(final_lineage_data_path "myapp" "kaptain-app-lineage-data.yaml")"
}

@test "metadata (app): kaptain.org/build-kind label is the BUILD_KIND verbatim" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/build-kind: \"kubernetes-app-manifests-only\"" \
    "$(final_lineage_data_path "myapp" "kaptain-app-lineage-data.yaml")"
}

@test "metadata (app): kaptain.org/project-name label is on app builds too" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/project-name: \"myapp\"" \
    "$(final_lineage_data_path "myapp" "kaptain-app-lineage-data.yaml")"
}

@test "metadata (app): kaptain.org/product-name and product-short-name absent on app builds" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  ! grep -q "kaptain.org/product-name" \
    "$(final_lineage_data_path "myapp" "kaptain-app-lineage-data.yaml")"
  ! grep -q "kaptain.org/product-short-name" \
    "$(final_lineage_data_path "myapp" "kaptain-app-lineage-data.yaml")"
}

@test "metadata: kaptain.org/git-sha annotation present when GIT_SHA set" {
  stage_product_preconditions
  GIT_SHA=abc123def456 run_script
  [ "${status}" -eq 0 ]
  grep -q "kaptain.org/git-sha: \"abc123def456\"" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

@test "metadata: kaptain.org/git-sha annotation absent when GIT_SHA empty" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  ! grep -q "kaptain.org/git-sha" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

# =============================================================================
# CM body - data keys
# =============================================================================

@test "data keys (product): CM has one key per lineage data file" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  local final
  final="$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
  grep -q "^  contents.yaml:" "${final}"
  grep -q "^  contents-resolved.yaml:" "${final}"
  grep -q "^  resources.yaml:" "${final}"
  grep -q "^  contract.yaml:" "${final}"
}

@test "data keys (product): CM metadata.name resolves to project name with lineage-data suffix" {
  stage_product_preconditions
  run_script
  [ "${status}" -eq 0 ]
  grep -q "^  name: product-foo-lineage-data$" \
    "$(final_lineage_data_path "product-foo" "kaptain-product-lineage-data.yaml")"
}

# =============================================================================
# Squat check (per-kind reserved filename)
# =============================================================================

@test "squat (product): pre-existing kaptain-product-lineage-data.yaml fails the build" {
  stage_product_preconditions
  printf 'fake\n' \
    > "${TEST_DIR}/kaptain-out/manifests/substituted/product-foo/kaptain-product-lineage-data.yaml"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Reserved filename 'kaptain-product-lineage-data.yaml'"
}

@test "squat (app): pre-existing kaptain-app-lineage-data.yaml fails the build" {
  stage_app_or_bundle_preconditions "myapp"
  printf 'fake\n' \
    > "${TEST_DIR}/kaptain-out/manifests/substituted/myapp/kaptain-app-lineage-data.yaml"
  BUILD_KIND=kubernetes-app-manifests-only PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Reserved filename 'kaptain-app-lineage-data.yaml'"
}

@test "squat (bundle): pre-existing kaptain-bundle-lineage-data.yaml fails the build" {
  stage_app_or_bundle_preconditions "mybundle"
  printf 'fake\n' \
    > "${TEST_DIR}/kaptain-out/manifests/substituted/mybundle/kaptain-bundle-lineage-data.yaml"
  BUILD_KIND=kubernetes-bundle-resources PROJECT_NAME=mybundle \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Reserved filename 'kaptain-bundle-lineage-data.yaml'"
}

# =============================================================================
# Validation: missing inputs / bad BUILD_KIND
# =============================================================================

@test "validation: unknown BUILD_KIND fails with diagnostic" {
  stage_product_preconditions
  BUILD_KIND=kubernetes-env-aggregate run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Unknown BUILD_KIND for lineage data"
}

@test "validation: missing substituted product dir fails with diagnostic" {
  stage_product_preconditions
  rm -rf "${TEST_DIR}/kaptain-out/manifests/substituted"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Substituted product directory not found"
  assert_output_contains "kubernetes-manifests-substitute"
}

@test "validation (product): missing contents-resolved.yaml fails with diagnostic" {
  stage_product_preconditions
  rm -f "${TEST_DIR}/kaptain-out/contents/contents-resolved.yaml"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Resolved-contents file not found"
  assert_output_contains "kubernetes-product-aggregate"
}

@test "validation (product): missing contents.yaml fails with diagnostic" {
  stage_product_preconditions
  rm -f "${TEST_DIR}/kaptain-out/contents/contents.yaml"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Contents list file not found"
  assert_output_contains "kubernetes-product-aggregate"
}

@test "validation: missing contract.yaml fails with diagnostic" {
  stage_product_preconditions
  rm -f "${TEST_DIR}/kaptain-out/manifests/contract/contract.yaml"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Contract file not found"
  assert_output_contains "kubernetes-manifests-contract-generate"
}

@test "validation: unresolved tokens left in lineage CM fail with diagnostic" {
  stage_product_preconditions
  # Inject an unresolved token into the contract so it survives into the lineage
  # CM. The sub-round substitute only resolves the self-reference token; this
  # token has no matching file in manifests/config and stays unresolved.
  cat >> "${TEST_DIR}/kaptain-out/manifests/contract/contract.yaml" << 'EOF'
extra:
  stray: ${SomeMissingToken}
EOF
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Lineage data ConfigMap still contains unresolved token(s)"
  assert_output_contains "SomeMissingToken"
}

@test "tokens: unresolved token in resources.yaml metadata.name is allowed" {
  stage_app_or_bundle_preconditions "mybundle"
  # Reusable bundles intentionally leave a token in metadata.name so the
  # consuming app or env supplies the final value at deploy time. This is the
  # one location where unresolved tokens are permitted to survive.
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/mybundle/template-cm.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mybundle-${Environment}-template
EOF
  BUILD_KIND=kubernetes-bundle-resources PROJECT_NAME=mybundle \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  grep -qF 'name: mybundle-${Environment}-template' \
    "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/resources.yaml"
  grep -qF 'mybundle-${Environment}-template' \
    "$(final_lineage_data_path "mybundle" "kaptain-bundle-lineage-data.yaml")"
}

@test "tokens: unresolved token in resources.yaml path field fails the build" {
  stage_app_or_bundle_preconditions "mybundle"
  # A filename carrying an unresolved token surfaces in resources.yaml's path
  # field. Build-time paths must be fully resolved - the name-field exception
  # is the only allowed location.
  cat > "${TEST_DIR}/kaptain-out/manifests/substituted/mybundle/"'${BadPath}-config.yaml' << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mybundle-extra
EOF
  BUILD_KIND=kubernetes-bundle-resources PROJECT_NAME=mybundle \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Lineage data ConfigMap still contains unresolved token(s)"
  assert_output_contains "BadPath"
}

@test "tokens: unresolved tokens in non-bookkeeping lineage files are allowed" {
  stage_app_or_bundle_preconditions "mybundle"
  # Only the kaptain-controlled bookkeeping files (contract, contents,
  # templates, resources) are scanned. Other files landing in the lineage data
  # dir - e.g. user payloads from a flat build with templates - may freely
  # contain unresolved tokens.
  mkdir -p "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data"
  cat > "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/random-file-unresolved-tokens.yaml" << 'EOF'
some-key: ${SomeRandomToken}
other-key: ${AnotherFreshToken}
EOF
  BUILD_KIND=kubernetes-bundle-resources PROJECT_NAME=mybundle \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  grep -qF '${SomeRandomToken}' \
    "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data/random-file-unresolved-tokens.yaml"
}

@test "validation: missing tokens directory fails with diagnostic" {
  stage_product_preconditions
  rm -rf "${TEST_DIR}/kaptain-out/manifests/config"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Tokens directory not found"
  assert_output_contains "kubernetes-manifests-package-prepare"
}

@test "validation: missing KaptainPM file fails with diagnostic" {
  stage_product_preconditions
  rm -f "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "KaptainPM file not found"
}

# =============================================================================
# ENV_BUILD_SECTION dispatch (kubernetes-run-environment, kubernetes-run-platform-meta-environment)
#
# These BUILD_KINDs run lineage-data-generate twice per build. ENV_BUILD_SECTION
# selects which run: 'app' produces the inner app CM (full happy path); 'env' or
# 'rp' produce the ENVIRONMENT RECORD CM (contents, contents-resolved,
# consumption-report, resources data keys) into the tree at ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH.
# =============================================================================

# Stage an env/rp build at the environment-record step: flavour-named
# contents files, a consumption report, the final-config tokens dir
# (default location), and the finalised workload tree.
stage_env_or_rp_preconditions() {
  local project="$1"
  local flavour="$2"
  local out="${TEST_DIR}/kaptain-out"

  mkdir -p "${TEST_DIR}/kaptainpm/final"
  cat > "${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-run-environment
spec:
  global:
    tokens:
      delimiterStyle: shell
      nameStyle: PascalCase
  contents:
    - alpha:1.0
EOF

  mkdir -p "${out}/${flavour}"
  cat > "${out}/${flavour}/${flavour}.yaml" << 'EOF'
- alpha:1.0
EOF
  cat > "${out}/${flavour}/${flavour}-resolved.yaml" << 'EOF'
- ghcr.io/org/alpha:1.0.0-manifests
EOF

  mkdir -p "${out}/run-consumption-report"
  cat > "${out}/run-consumption-report/${project}-1.2.3-consumption-report.yaml" << EOF
kind: ${flavour}
name: ${project}
version: 1.2.3
consumed:
  - alpha:1.0
EOF

  # The stacked final-config dir the record sections take via
  # ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH (deliberately NOT the app-side default location).
  mkdir -p "${out}/final-config"
  printf '%s' "${project}" > "${out}/final-config/ProjectName"
  printf '%s' "1.2.3" > "${out}/final-config/Version"
  printf '%s' "${project}" > "${out}/final-config/EnvironmentName"
  printf '%s' "${project#run-}" > "${out}/final-config/EnvironmentShortName"

  mkdir -p "${out}/run-agg/substituted"
  cat > "${out}/run-agg/substituted/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${project}
spec:
  replicas: 2
EOF
}

@test "env-section: kubernetes-run-environment + app dispatches as app" {
  stage_app_or_bundle_preconditions "myenv"
  BUILD_KIND=kubernetes-run-environment ENV_BUILD_SECTION=app PROJECT_NAME=myenv \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  [ -f "$(final_lineage_data_path "myenv" "kaptain-app-lineage-data.yaml")" ]
  grep -q "kaptain.org/role: \"kaptain-app-lineage-data\"" \
    "$(final_lineage_data_path "myenv" "kaptain-app-lineage-data.yaml")"
  grep -q "kaptain.org/build-kind: \"kubernetes-run-environment\"" \
    "$(final_lineage_data_path "myenv" "kaptain-app-lineage-data.yaml")"
}

@test "env-section: working dirs are namespaced under ENV_BUILD_SECTION subdir" {
  stage_app_or_bundle_preconditions "myenv"
  BUILD_KIND=kubernetes-run-environment ENV_BUILD_SECTION=app PROJECT_NAME=myenv \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  [ -d "${TEST_DIR}/kaptain-out/lineage-data/app/keys-for-lineage-data" ]
  [ -d "${TEST_DIR}/kaptain-out/lineage-data/app/generated-configmap" ]
  [ -f "${TEST_DIR}/kaptain-out/lineage-data/app/keys-for-lineage-data/templates.yaml" ]
  # Flat layout (no section subdir) must not exist on env-section builds
  [ ! -d "${TEST_DIR}/kaptain-out/lineage-data/keys-for-lineage-data" ]
}

@test "env-section: kubernetes-run-environment + env produces the environment record" {
  stage_env_or_rp_preconditions "run-env-test" "environment"
  BUILD_KIND=kubernetes-run-environment ENV_BUILD_SECTION=env PROJECT_NAME=run-env-test \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH="kaptain-out/run-agg/substituted" \
    ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH="kaptain-out/final-config" \
    run_script
  [ "${status}" -eq 0 ]
  local cm="${TEST_DIR}/kaptain-out/run-agg/substituted/kaptain-environment-lineage-data.yaml"
  [ -f "${cm}" ]
  grep -q "kaptain.org/role: \"kaptain-environment-lineage-data\"" "${cm}"
  grep -q "kaptain.org/build-kind: \"kubernetes-run-environment\"" "${cm}"
  grep -q "kaptain.org/environment-name: \"run-env-test\"" "${cm}"
  grep -q "kaptain.org/environment-short-name: \"env-test\"" "${cm}"
  local keys="${TEST_DIR}/kaptain-out/lineage-data/env/keys-for-lineage-data"
  [ -f "${keys}/contents.yaml" ]
  [ -f "${keys}/contents-resolved.yaml" ]
  [ -f "${keys}/consumption-report.yaml" ]
  [ -f "${keys}/resources.yaml" ]
  # env is the final layer: no contract data key.
  [ ! -f "${keys}/contract.yaml" ]
  # The record lists itself in its own inventory, product-style.
  grep -q "name: run-env-test-lineage-data" "${keys}/resources.yaml"
}

@test "env-section: env record fails loudly when the consumption report is missing" {
  stage_env_or_rp_preconditions "run-env-test" "environment"
  rm -rf "${TEST_DIR}/kaptain-out/run-consumption-report"
  BUILD_KIND=kubernetes-run-environment ENV_BUILD_SECTION=env PROJECT_NAME=run-env-test \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH="kaptain-out/run-agg/substituted" \
    ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH="kaptain-out/final-config" \
    run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Consumption report not found"
  assert_output_contains "Did kubernetes-run-consumption-report run first?"
}

@test "env-section: kubernetes-run-environment without ENV_BUILD_SECTION defaults to the env record" {
  stage_env_or_rp_preconditions "run-env-test" "environment"
  BUILD_KIND=kubernetes-run-environment PROJECT_NAME=run-env-test \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH="kaptain-out/run-agg/substituted" \
    ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH="kaptain-out/final-config" \
    run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Kind family: env"
  [ -f "${TEST_DIR}/kaptain-out/run-agg/substituted/kaptain-environment-lineage-data.yaml" ]
}

@test "env-section: kubernetes-run-environment with invalid ENV_BUILD_SECTION fails with diagnostic" {
  BUILD_KIND=kubernetes-run-environment ENV_BUILD_SECTION=rp PROJECT_NAME=myenv \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -ne 0 ]
  [ "${status}" -ne 42 ]
  assert_output_contains "Invalid ENV_BUILD_SECTION 'rp' for BUILD_KIND=kubernetes-run-environment"
  assert_output_contains "Expected one of: app, env"
}

@test "env-section: kubernetes-run-platform-meta-environment + app dispatches as app" {
  stage_app_or_bundle_preconditions "myrp"
  BUILD_KIND=kubernetes-run-platform-meta-environment ENV_BUILD_SECTION=app PROJECT_NAME=myrp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -eq 0 ]
  [ -f "$(final_lineage_data_path "myrp" "kaptain-app-lineage-data.yaml")" ]
  grep -q "kaptain.org/role: \"kaptain-app-lineage-data\"" \
    "$(final_lineage_data_path "myrp" "kaptain-app-lineage-data.yaml")"
  grep -q "kaptain.org/build-kind: \"kubernetes-run-platform-meta-environment\"" \
    "$(final_lineage_data_path "myrp" "kaptain-app-lineage-data.yaml")"
}

@test "env-section: kubernetes-run-platform-meta-environment + rp produces the platform record" {
  stage_env_or_rp_preconditions "run-platform-test" "run-platform"
  BUILD_KIND=kubernetes-run-platform-meta-environment ENV_BUILD_SECTION=rp PROJECT_NAME=run-platform-test \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH="kaptain-out/run-agg/substituted" \
    ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH="kaptain-out/final-config" \
    run_script
  [ "${status}" -eq 0 ]
  local cm="${TEST_DIR}/kaptain-out/run-agg/substituted/kaptain-environment-lineage-data.yaml"
  [ -f "${cm}" ]
  grep -q "kaptain.org/role: \"kaptain-environment-lineage-data\"" "${cm}"
  grep -q "kaptain.org/build-kind: \"kubernetes-run-platform-meta-environment\"" "${cm}"
  local keys="${TEST_DIR}/kaptain-out/lineage-data/rp/keys-for-lineage-data"
  [ -f "${keys}/contents.yaml" ]
  [ -f "${keys}/consumption-report.yaml" ]
  [ ! -f "${keys}/contract.yaml" ]
}

@test "env-section: kubernetes-run-platform-meta-environment without ENV_BUILD_SECTION defaults to the rp record" {
  stage_env_or_rp_preconditions "run-platform-test" "run-platform"
  BUILD_KIND=kubernetes-run-platform-meta-environment PROJECT_NAME=run-platform-test \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    ENVIRONMENT_WORKLOAD_CONTENTS_SUB_PATH="kaptain-out/run-agg/substituted" \
    ENVIRONMENT_WORKLOAD_CONTENTS_CONFIG_SUB_PATH="kaptain-out/final-config" \
    run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Kind family: rp"
  [ -f "${TEST_DIR}/kaptain-out/run-agg/substituted/kaptain-environment-lineage-data.yaml" ]
}

@test "env-section: kubernetes-run-platform-meta-environment + env (wrong section) fails with diagnostic" {
  BUILD_KIND=kubernetes-run-platform-meta-environment ENV_BUILD_SECTION=env PROJECT_NAME=myrp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -ne 0 ]
  [ "${status}" -ne 42 ]
  assert_output_contains "Invalid ENV_BUILD_SECTION 'env' for BUILD_KIND=kubernetes-run-platform-meta-environment"
  assert_output_contains "Expected one of: app, rp"
}

@test "env-section: ENV_BUILD_SECTION must be empty for kubernetes-product-aggregate" {
  stage_product_preconditions
  ENV_BUILD_SECTION=app run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "ENV_BUILD_SECTION must not be set for BUILD_KIND=kubernetes-product-aggregate"
}

@test "env-section: ENV_BUILD_SECTION must be empty for kubernetes-app-*" {
  stage_app_or_bundle_preconditions "myapp"
  BUILD_KIND=kubernetes-app-manifests-only ENV_BUILD_SECTION=env PROJECT_NAME=myapp \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "ENV_BUILD_SECTION must not be set for BUILD_KIND=kubernetes-app-manifests-only"
}

@test "env-section: ENV_BUILD_SECTION must be empty for kubernetes-bundle-*" {
  stage_app_or_bundle_preconditions "mybundle"
  BUILD_KIND=kubernetes-bundle-resources ENV_BUILD_SECTION=rp PROJECT_NAME=mybundle \
    PRODUCT_NAME="" PRODUCT_SHORT_NAME="" \
    run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "ENV_BUILD_SECTION must not be set for BUILD_KIND=kubernetes-bundle-resources"
}

@test "validation: missing PROJECT_NAME fails with diagnostic" {
  stage_product_preconditions
  PROJECT_NAME="" run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "PROJECT_NAME"
}

@test "validation (product): missing PRODUCT_NAME fails with diagnostic" {
  stage_product_preconditions
  PRODUCT_NAME="" run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "PRODUCT_NAME"
}

@test "validation: a contract listing deferred built-ins as required tokens passes" {
  stage_product_preconditions
  local out="${TEST_DIR}/kaptain-out"
  cat >> "${out}/manifests/contract/contract.yaml" << 'EOF'
config:
  required:
    - ProjectName
    - Version
    - RepositoryName
EOF

  run_script
  [ "${status}" -eq 0 ]
}

teardown() {
  dump_bats_result
}
