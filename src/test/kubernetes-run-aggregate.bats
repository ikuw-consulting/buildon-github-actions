#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/kubernetes-run-aggregate (env and RP builds).

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/kubernetes-run-aggregate"

setup() {
  TEST_DIR=$(create_test_dir "kubernetes-run-aggregate")
  mkdir -p "${TEST_DIR}/kaptainpm/final"
  export GITHUB_OUTPUT="${TEST_DIR}/github-output"
  : > "${GITHUB_OUTPUT}"
  # The secrets preflight always records the base image's supported types.
  setup_mock_decryption_providers
}

write_pm() {
  local pm_file="${TEST_DIR}/kaptainpm/final/KaptainPM.yaml"
  cat > "${pm_file}" << 'EOF'
apiVersion: kaptain.org/v1
kind: kubernetes-run-environment
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

# MANIFESTS_CONTRACT_KIND overrides the build kind the contract publishes, for
# the tests that care which level produced a child.
make_contract_zip() {
  local zip_path="$1"
  local delim="$2"
  local name="$3"
  shift 3
  local stage="${TEST_DIR}/_stage-cz-$$-${RANDOM}"
  mkdir -p "${stage}"
  cat > "${stage}/contract.yaml" << EOF
apiVersion: kaptain.org/manifests-contract/1.2
kind: ${MANIFESTS_CONTRACT_KIND:-kubernetes-bundle}
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

  # Not a symlink: the util sources ../defaults relative to its own path.
  cat > "${MOCK_UTIL_DIR}/scan-unresolved-tokens" << MOCK
#!/usr/bin/env bash
exec "${SCRIPTS_DIR}/../util/scan-unresolved-tokens" "\$@"
MOCK
  chmod +x "${MOCK_UTIL_DIR}/scan-unresolved-tokens"
}

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

# Under the block's own pipeline dir, which uses a block-local OUTPUT_SUB_PATH
# (lib/run-image-deploy-manifests-paths.bash).
stage_own_deploy_manifests_output() {
  local project="$1"
  local pipeline="${TEST_DIR}/kaptain-out/run-image-deploy-manifests/pipeline"
  mkdir -p "${pipeline}/manifests/substituted/${project}" \
           "${pipeline}/manifests/contract"
  cat > "${pipeline}/manifests/substituted/${project}/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${project}-deployer
spec:
  replicas: 1
EOF
  cat > "${pipeline}/manifests/contract/contract.yaml" << 'EOF'
apiVersion: kaptain.org/manifests-contract/1.2
kind: kubernetes-bundle
tokens:
  delimiterStyle: shell
  nameStyle: PascalCase
compatibility:
  automaticConversion: []
  repackageRequired: []
config:
  required: []
EOF
}

run_script() {
  : "${PROJECT_NAME=run-foo}"
  : "${BUILD_KIND=kubernetes-run-environment}"
  : "${OUTPUT_SUB_PATH:=kaptain-out}"
  : "${TOKEN_DELIMITER_STYLE:=shell}"
  : "${TOKEN_NAME_STYLE:=PascalCase}"
  : "${MANIFESTS_SUB_PATH:=src/kubernetes}"
  : "${ENV_ALLOW_LOCAL_MANIFESTS_OVERRIDE:=false}"
  : "${BUILD_MODE:=build_server}"
  run env \
    PROJECT_NAME="${PROJECT_NAME}" \
    BUILD_KIND="${BUILD_KIND}" \
    OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH}" \
    TOKEN_DELIMITER_STYLE="${TOKEN_DELIMITER_STYLE}" \
    TOKEN_NAME_STYLE="${TOKEN_NAME_STYLE}" \
    MANIFESTS_SUB_PATH="${MANIFESTS_SUB_PATH}" \
    ENV_ALLOW_LOCAL_MANIFESTS_OVERRIDE="${ENV_ALLOW_LOCAL_MANIFESTS_OVERRIDE}" \
    BUILD_MODE="${BUILD_MODE}" \
    BUILD_PLATFORM=test \
    GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
    KAPTAINPM_FILE="${TEST_DIR}/kaptainpm/final/KaptainPM.yaml" \
    CONTENT_RESOLVE_UTIL_DIR="${MOCK_UTIL_DIR:-}" \
    MOCK_OCI_DIR="${MOCK_OCI_DIR:-}" \
    bash -c "cd '${TEST_DIR}' && '${SCRIPT}'"
}

write_local_manifest() {
  local rel="$1"
  local content="$2"
  local target="${TEST_DIR}/src/kubernetes/${rel}"
  mkdir -p "$(dirname "${target}")"
  printf '%s' "${content}" > "${target}"
}

github_output_value() {
  grep "^${1}=" "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-
}

# =============================================================================
# Kind (BUILD_KIND) + the name suiting it
# =============================================================================

@test "kind: an environment emits ENVIRONMENT_NAME/SHORT_NAME" {
  write_pm
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  PROJECT_NAME=run-foo run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Build kind: kubernetes-run-environment"
  [ "$(github_output_value ENVIRONMENT_NAME)" = "run-foo" ]
  [ "$(github_output_value ENVIRONMENT_SHORT_NAME)" = "foo" ]
  [ -d "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated" ]
}

@test "kind: a run-platform strips the full prefix" {
  write_pm
  setup_mock_oci
  stage_own_deploy_manifests_output run-platform-foo
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Build kind: kubernetes-run-platform-meta-environment"
  [ "$(github_output_value ENVIRONMENT_NAME)" = "run-platform-foo" ]
  [ "$(github_output_value ENVIRONMENT_SHORT_NAME)" = "foo" ]
  [ -d "${TEST_DIR}/kaptain-out/run-platform-meta-environment/manifests-aggregated" ]
}

@test "kind: a missing BUILD_KIND fails" {
  write_pm
  BUILD_KIND="" run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "BUILD_KIND is required"
}

@test "kind: a BUILD_KIND that is not a run kind fails" {
  write_pm
  BUILD_KIND=kubernetes-product-aggregate run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "is not a run kind"
}

@test "naming: an environment may not take a run-platform- name" {
  write_pm
  PROJECT_NAME=run-platform-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "'run-platform-' names are for kubernetes-run-platform-meta-environment"
}

@test "naming: a run-platform needs a run-platform- name" {
  write_pm
  PROJECT_NAME=run-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "does not suit kubernetes-run-platform-meta-environment: it must start 'run-platform-'"
}

@test "naming: a run-platform- name with nothing after the prefix fails" {
  write_pm
  PROJECT_NAME=run-platform- BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "has nothing after the 'run-platform-' prefix"
}

@test "naming: rejects bare name without run- prefix" {
  write_pm
  PROJECT_NAME=foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "does not suit kubernetes-run-environment: it must start 'run-'"
}

@test "naming: rejects empty PROJECT_NAME" {
  write_pm
  PROJECT_NAME="" run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "PROJECT_NAME"
}

# =============================================================================
# Kind-keyed composition rule
# =============================================================================

@test "composition: env rejects entry whose repo starts with run-" {
  write_pm "run-other:1.0"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "inside an environment is not"
  assert_output_contains "run-other:1.0"
}

@test "composition: env rejects entry whose repo starts with run-platform-" {
  write_pm "ghcr.io/org/sub/run-platform-other:9.9"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "inside an environment is not"
  assert_output_contains "run-platform-other"
}

@test "composition: rp rejects entry whose repo starts with run-platform-" {
  write_pm "run-platform-other:1.0"
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "inside another run-platform is not"
  assert_output_contains "run-platform-other"
}

@test "composition: env reports every offending entry before failing" {
  write_pm "run-one:1.0" "alpha:1.0" "run-platform-two:1.0"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Offending entry: run-one:1.0"
  assert_output_contains "Offending entry: run-platform-two:1.0"
  [ "$(grep -c 'inside an environment is not' <<< "${output}")" -eq 1 ]
}

@test "composition: rp reports every offending entry before failing" {
  write_pm "run-platform-one:1.0" "run-child:1.0" "run-platform-two:1.0"
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Offending entry: run-platform-one:1.0"
  assert_output_contains "Offending entry: run-platform-two:1.0"
  [ "$(grep -c 'Offending entry: run-child' <<< "${output}")" -eq 0 ]
}

@test "composition: rp accepts run-* (non-platform) children" {
  setup_mock_oci
  stage_oci_fixture "run-child:1.0-manifests" "run-child" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-platform-foo
  write_pm "run-child:1.0"
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/run-platform-meta-environment/manifests-aggregated/run-child/deployment.yaml" ]
}

# A child's delegated cluster-scoped set, as an env with
# clusterScopedDelegation: parent publishes it.
stage_on_behalf_zip() {
  local manifests_uri="$1"
  local project="$2"
  local key stage
  key=$(echo "${manifests_uri}" | tr '/:' '__')
  stage="${TEST_DIR}/_stage-ob-$$-${RANDOM}"
  mkdir -p "${stage}/${project}"
  cat > "${stage}/${project}/clusterrole.yaml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${project}
EOF
  ( cd "${stage}" && zip -qr "${MOCK_OCI_DIR}/${key}/${project}-1.0-cluster-scoped-resources.zip" "${project}" )
  rm -rf "${stage}"
}

@test "on-behalf: a run-platform collects a child's delegated set under contents" {
  setup_mock_oci
  stage_oci_fixture "run-child:1.0-manifests" "run-child" shell PascalCase "Replicas=2"
  stage_on_behalf_zip "run-child:1.0-manifests" "run-child"
  stage_own_deploy_manifests_output run-platform-foo
  write_pm "run-child:1.0"
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/contents/cluster-scoped-on-behalf/run-child/clusterrole.yaml" ]
  # Only the delegated set: nothing from the child's manifests zip.
  [ "$(find "${TEST_DIR}/kaptain-out/contents/cluster-scoped-on-behalf/run-child" -type f | wc -l)" -eq 1 ]
  [ ! -e "${TEST_DIR}/kaptain-out/contents/manifests/run-child/clusterrole.yaml" ]
}

@test "on-behalf: a symlink in a child's delegated set fails the build" {
  setup_mock_oci
  stage_oci_fixture "run-child:1.0-manifests" "run-child" shell PascalCase "Replicas=2"
  local key stage
  key=$(echo "run-child:1.0-manifests" | tr '/:' '__')
  stage="${TEST_DIR}/_stage-ob-link"
  mkdir -p "${stage}/run-child"
  ln -s /etc/hosts "${stage}/run-child/clusterrole.yaml"
  ( cd "${stage}" && zip -qry "${MOCK_OCI_DIR}/${key}/run-child-1.0-cluster-scoped-resources.zip" run-child )
  stage_own_deploy_manifests_output run-platform-foo
  write_pm "run-child:1.0"
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "a symbolic link"
  [ ! -e "${TEST_DIR}/kaptain-out/contents/cluster-scoped-on-behalf/run-child" ]
}

@test "on-behalf: a delegated zip in an environment's contents fails the build" {
  setup_mock_oci
  stage_oci_fixture "bundle-child:1.0-manifests" "bundle-child" shell PascalCase "Replicas=2"
  stage_on_behalf_zip "bundle-child:1.0-manifests" "bundle-child"
  write_pm "bundle-child:1.0"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "carries a delegated cluster-scoped zip: bundle-child-1.0-cluster-scoped-resources.zip"
  [ ! -e "${TEST_DIR}/kaptain-out/contents/cluster-scoped-on-behalf" ]
}

@test "on-behalf: every entry carrying a delegated zip is reported before failing" {
  setup_mock_oci
  stage_oci_fixture "bundle-one:1.0-manifests" "bundle-one" shell PascalCase "Replicas=2"
  stage_on_behalf_zip "bundle-one:1.0-manifests" "bundle-one"
  stage_oci_fixture "bundle-two:1.0-manifests" "bundle-two" shell PascalCase "Replicas=2"
  stage_on_behalf_zip "bundle-two:1.0-manifests" "bundle-two"
  write_pm "bundle-one:1.0" "bundle-two:1.0"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "bundle-one:1.0 carries a delegated cluster-scoped zip"
  assert_output_contains "bundle-two:1.0 carries a delegated cluster-scoped zip"
}

# =============================================================================
# Duplicate spec.contents
# =============================================================================

@test "duplicate spec.contents: same name different versions is rejected" {
  setup_mock_oci
  write_pm "alpha:1.0" "alpha:2.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "duplicate"
  assert_output_contains "alpha"
}

# =============================================================================
# Self-inclusion of the own deploy-manifests set
# =============================================================================

@test "self-inclusion: rp with empty contents still stages its own deploy-manifests set" {
  write_pm
  setup_mock_oci
  stage_own_deploy_manifests_output run-platform-foo
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "self-referencing"
  [ -f "${TEST_DIR}/kaptain-out/run-platform-meta-environment/manifests-aggregated/run-platform-foo/deployment.yaml" ]
}

@test "self-inclusion: rp fails loudly when its deploy-manifests output is missing" {
  write_pm
  setup_mock_oci
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Own deploy-manifests tree not found"
  assert_output_contains "Did the deploy-manifests block run first?"
}

# An env's deployer manifests are applied by its parent run-platform.
@test "self-inclusion: env does not self-include and needs no deploy-manifests output" {
  write_pm
  setup_mock_oci
  run_script
  [ "${status}" -eq 0 ]
  [ ! -e "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/run-foo" ]
}

# =============================================================================
# End-to-end staging
# =============================================================================

@test "end-to-end: env stages a bundle into the kind-named aggregate, without self" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/alpha/deployment.yaml" ]
  [ ! -e "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/run-foo" ]
  [ -f "${TEST_DIR}/kaptain-out/run-environment/config-defaults/Replicas" ]
  [ "$(cat "${TEST_DIR}/kaptain-out/run-environment/config-defaults/Replicas")" = "2" ]
}

@test "end-to-end: rp stages a bundle plus self into the kind-named aggregate" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-platform-foo
  write_pm "alpha:1.0"
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/run-platform-meta-environment/manifests-aggregated/alpha/deployment.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/run-platform-meta-environment/manifests-aggregated/run-platform-foo/deployment.yaml" ]
  [ -f "${TEST_DIR}/kaptain-out/run-platform-meta-environment/config-defaults/Replicas" ]
  [ "$(cat "${TEST_DIR}/kaptain-out/run-platform-meta-environment/config-defaults/Replicas")" = "2" ]
}

# =============================================================================
# Cross-bundle defaults conflict detection
# =============================================================================

@test "defaults: byte-identical values from two bundles collapse" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_oci_fixture "beta:2.0-manifests"  "beta"  shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0" "beta:2.0"
  run_script
  [ "${status}" -eq 0 ]
  [ "$(cat "${TEST_DIR}/kaptain-out/run-environment/config-defaults/Replicas")" = "2" ]
}

@test "defaults: differing values across bundles fails with diagnostic" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_oci_fixture "beta:2.0-manifests"  "beta"  shell PascalCase "Replicas=3"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0" "beta:2.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Default value collision for token 'Replicas'"
}

# =============================================================================
# Per-bundle scheme conversion
# =============================================================================

@test "scheme: bundle scheme matching the run is a no-op" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Token scheme matches"
}

# =============================================================================
# Local manifests fold
# =============================================================================

@test "local-manifests: standalone manifest is included in assembled tree" {
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  write_pm
  write_local_manifest "extra/thing.yaml" "kind: ConfigMap"
  run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/extra/thing.yaml" ]
}

@test "local-manifests: collision with override=false fails" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  write_local_manifest "alpha/deployment.yaml" "kind: Deployment"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "alpha/deployment.yaml"
  assert_output_contains "allowLocalManifestsOverride"
}

@test "local-manifests: collision with override=true wins and warns" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  write_local_manifest "alpha/deployment.yaml" "kind: LocalWins"
  ENV_ALLOW_LOCAL_MANIFESTS_OVERRIDE=true run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "overrides a file contributed by a child"
  grep -q "LocalWins" "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/alpha/deployment.yaml"
}

# =============================================================================
# Symlinks: rejected wherever manifests come in
# =============================================================================

@test "symlinks: a symlink in a child's manifests zip fails the build" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  local key stage
  key=$(echo "alpha:1.0-manifests" | tr '/:' '__')
  stage="${TEST_DIR}/_stage-link"
  mkdir -p "${stage}/alpha"
  ln -s /etc/hosts "${stage}/alpha/stolen.yaml"
  ( cd "${stage}" && zip -qy "${MOCK_OCI_DIR}/${key}/alpha-1.0-manifests.zip" alpha/stolen.yaml )
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "alpha/stolen.yaml: a symbolic link"
  [ ! -e "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/alpha/stolen.yaml" ]
}

@test "symlinks: a symlink in the local manifests fails the build" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  mkdir -p "${TEST_DIR}/src/kubernetes/extra"
  ln -s /etc/hosts "${TEST_DIR}/src/kubernetes/extra/stolen.yaml"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "extra/stolen.yaml: a symbolic link"
  [ ! -e "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/extra/stolen.yaml" ]
}

# =============================================================================
# Delete modifiers
# =============================================================================

AGGREGATED="kaptain-out/run-environment/manifests-aggregated"
PRUNED="kaptain-out/run-environment/manifests-pruned"

@test "delete: a local delete removes the child manifest and itself, and is recorded" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  write_local_manifest "alpha/deployment.yaml.delete-not-in-this-env" "# replaced by our own"
  run_script
  [ "${status}" -eq 0 ]
  [ ! -e "${TEST_DIR}/${PRUNED}/alpha/deployment.yaml" ]
  [ ! -e "${TEST_DIR}/${PRUNED}/alpha/deployment.yaml.delete-not-in-this-env" ]
  # Kept for provenance.
  [ -f "${TEST_DIR}/${AGGREGATED}/alpha/deployment.yaml" ]
  [ -f "${TEST_DIR}/${AGGREGATED}/alpha/deployment.yaml.delete-not-in-this-env" ]
  grep -qxF "$(printf 'alpha/deployment.yaml\talpha/deployment.yaml.delete-not-in-this-env')" \
    "${TEST_DIR}/kaptain-out/run-environment/deleted-manifests.tsv"
}

@test "delete: an empty delete file is fine" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  write_local_manifest "alpha/deployment.yaml.delete-gone" ""
  run_script
  [ "${status}" -eq 0 ]
  [ ! -e "${TEST_DIR}/${PRUNED}/alpha/deployment.yaml" ]
}

@test "delete: with no deletes the pruned tree is still written, identical to the merged one" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "No delete modifiers."
  [ -f "${TEST_DIR}/${PRUNED}/alpha/deployment.yaml" ]
  diff -r "${TEST_DIR}/${AGGREGATED}" "${TEST_DIR}/${PRUNED}"
}

@test "delete: a delete file holding anything but comments fails" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  write_local_manifest "alpha/deployment.yaml.delete-gone" "kind: Deployment"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "a delete modifier may hold only comments"
}

@test "delete: two deletes for one target fail" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  write_local_manifest "alpha/deployment.yaml.delete-one" ""
  write_local_manifest "alpha/deployment.yaml.delete-two" ""
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "alpha/deployment.yaml: more than one delete modifier"
}

@test "delete: a deleted target that is also patched fails" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  write_local_manifest "alpha/deployment.yaml.delete-gone" ""
  write_local_manifest "alpha/deployment.yaml.yq-expression-list-scale" ".spec.replicas = 3"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "also has yq-expression-list modifiers"
}

@test "delete: the generated cleanup policy cannot be deleted" {
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  write_pm
  write_local_manifest "kaptain-environment-cleanup-policy.yaml.delete-no" ""
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "is generated by this build and cannot be deleted"
}

# =============================================================================
# Secrets-dir preflight (both kinds; RPs have their own passphrase secret)
# =============================================================================

@test "preflight: plaintext .raw in secrets dir fails an env build" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets"
  printf 'oops' > "${TEST_DIR}/src/secrets/EnvApiToken.raw"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "PLAINTEXT secret present at build time"
}

@test "preflight: plaintext .raw in secrets dir fails an rp build too" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets"
  printf 'oops' > "${TEST_DIR}/src/secrets/EnvironmentPassphrase.raw"
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "PLAINTEXT secret present at build time"
}

@test "preflight: nested secret value is accepted and its type recorded" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets/Vendor"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/Vendor/DbPassword.age"
  PROJECT_NAME=run-foo run_script
  assert_output_contains "OK: all values carry the 'age' suffix."
  [ "$(cat "${TEST_DIR}/kaptain-out/run-aggregate/secret-encryption-type")" = "age" ]
  grep -qx "age" "${TEST_DIR}/kaptain-out/run-aggregate/secret-encryption-types"
  ! grep -q "RUN_SECRETS_ENCRYPTION_TYPE" "${GITHUB_OUTPUT}"
}

@test "preflight: no secrets dir records the supported types and an empty type" {
  setup_mock_decryption_providers
  write_pm
  PROJECT_NAME=run-foo run_script
  [ "$(head -1 "${TEST_DIR}/kaptain-out/run-aggregate/secret-encryption-types")" = "sha256.aes256.100k" ]
  [ -f "${TEST_DIR}/kaptain-out/run-aggregate/secret-encryption-type" ]
  [ -z "$(cat "${TEST_DIR}/kaptain-out/run-aggregate/secret-encryption-type")" ]
}

@test "preflight: a local build with problems still records the valid values' type" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/ApiKey.age"
  printf 'oops' > "${TEST_DIR}/src/secrets/Other.raw"
  PROJECT_NAME=run-foo BUILD_MODE=local run_script
  assert_output_contains "PLAINTEXT secret present at build time"
  [ "$(cat "${TEST_DIR}/kaptain-out/run-aggregate/secret-encryption-type")" = "age" ]
}

@test "preflight: mixed encryption types fail and record no type" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/ApiKey.age"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/Other.sha256.aes256"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "mixed encryption-type suffixes"
  [ ! -e "${TEST_DIR}/kaptain-out/run-aggregate/secret-encryption-type" ]
}

@test "preflight: a dotted encryption type is taken whole, not from the first dot" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/ApiKey.sha256.aes256.10k"
  PROJECT_NAME=run-foo run_script
  assert_output_contains "OK: all values carry the 'sha256.aes256.10k' suffix."
}

@test "preflight: unsupported suffix fails and names the nested path" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets/Vendor"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/Vendor/DbPassword.gpg"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "src/secrets/Vendor/DbPassword.gpg: no supported encryption-type suffix"
  assert_output_contains "type one of: age sha256.aes256 sha256.aes256.100k sha256.aes256.10k sha256.aes256.600k"
}

@test "preflight: supported types come from the deploy base image" {
  setup_mock_decryption_providers
  export MOCK_DOCKER_RUN_OUTPUT="decrypt-age"
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/ApiKey.sha256.aes256"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "ApiKey.sha256.aes256: no supported encryption-type suffix"
  assert_docker_called "run --rm --entrypoint ls ghcr.io/kube-kaptain/image/image-environment-deploy-trixie-slim:1.0.16.1.36.1 /kd/bin/plugins/decryption-providers"
}

@test "preflight: a base image without decryption providers fails" {
  setup_mock_decryption_providers
  export MOCK_DOCKER_RUN_OUTPUT="something-else"
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/ApiKey.age"
  PROJECT_NAME=run-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "has no decrypt-<type> providers"
}

# =============================================================================
# Reserved env-lineage-data filename squat
# =============================================================================

@test "squat: local kaptain-environment-lineage-data.yaml fails the build" {
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  write_pm
  write_local_manifest "kaptain-environment-lineage-data.yaml" "kind: ConfigMap"
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "kaptain-environment-lineage-data.yaml"
}

# =============================================================================
# Contents list output
# =============================================================================

@test "contents-list: writes bullets for every spec.contents entry verbatim" {
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  local list_file
  list_file="$(github_output_value ENVIRONMENT_WORKLOAD_CONTENTS_FILE)"
  [ -n "${list_file}" ]
  grep -qx -- "- alpha:1.0" "${TEST_DIR}/${list_file}"
}

@test "contents-list: empty contents writes empty file" {
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  local list_file
  list_file="$(github_output_value ENVIRONMENT_WORKLOAD_CONTENTS_FILE)"
  [ -f "${TEST_DIR}/${list_file}" ]
  [ ! -s "${TEST_DIR}/${list_file}" ]
}

# =============================================================================
# Cleanup policy ConfigMap
# =============================================================================

# A validator plugin that records what it was asked to validate, then hands
# off to the host's real one.
use_recording_validator() {
  VALIDATOR_LOG="${TEST_DIR}/validator-calls.log"
  local real="${SCHEMA_VALIDATION_COMMAND}"
  cat > "${TEST_DIR}/recording-validator" << EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$1")" "\$(basename "\$2")" >> "${VALIDATOR_LOG}"
exec "${real}" "\$@"
EOF
  chmod +x "${TEST_DIR}/recording-validator"
  export SCHEMA_VALIDATION_COMMAND="${TEST_DIR}/recording-validator"
}

@test "schema validation: the cleanup policy and child contracts go through SCHEMA_VALIDATION_COMMAND" {
  use_recording_validator
  setup_mock_oci
  stage_oci_fixture "alpha:1.0-manifests" "alpha" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-foo
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  grep -qE '^spec-kaptainpm-schema\.[0-9.]+\.json cleanup-policy' "${VALIDATOR_LOG}"
  grep -qE '^spec-manifests-contract-schema-[0-9.]+\.json contract\.yaml$' "${VALIDATOR_LOG}"
}

@test "schema validation: an invalid cleanup policy fails with the validator's output" {
  export SCHEMA_VALIDATION_COMMAND="${TEST_DIR}/failing-validator"
  printf '#!/usr/bin/env bash\necho "schema says no"\nexit 1\n' > "${SCHEMA_VALIDATION_COMMAND}"
  chmod +x "${SCHEMA_VALIDATION_COMMAND}"
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  write_pm
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Generated cleanup policy document does not validate"
  assert_output_contains "  schema says no"
}

@test "schema validation: SCHEMA_VALIDATION_COMMAND is required" {
  unset SCHEMA_VALIDATION_COMMAND
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  write_pm
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "SCHEMA_VALIDATION_COMMAND is required"
}

@test "cleanup-policy: carries no product labels (an env is not part of a product)" {
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  write_pm
  run_script
  [ "${status}" -eq 0 ]
  local policy="${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/kaptain-environment-cleanup-policy.yaml"
  [ -f "${policy}" ]
  [ "$(grep -c "ProductName" "${policy}")" -eq 0 ]
  [ "$(grep -c "app.kubernetes.io/part-of" "${policy}")" -eq 0 ]
  [ "$(grep -c "kaptain.org/product" "${policy}")" -eq 0 ]
  grep -q "kaptain.org/project-name" "${policy}"
}

# =============================================================================
# Resource envelopes on the run's OWN manifests
#
# The environment's src/kubernetes holds deployables no product aggregate ever
# sees, because they belong to the environment rather than to a product bundle.
# They are also the only manifests in the assembled tree the environment author
# can fix in this repo, which is why they are the ones checked here.
# =============================================================================

# A child bundle whose one container carries no resource envelope, published
# under <contract-kind>. A product publishes kubernetes-product-aggregate,
# which is what an environment imports.
# Usage: stage_budgetless_child_fixture <manifests-uri> <project> <contract-kind>
stage_budgetless_child_fixture() {
  local manifests_uri="$1"
  local project="$2"
  local contract_kind="$3"
  local key fixture_dir stage
  key=$(echo "${manifests_uri}" | tr '/:' '__')
  fixture_dir="${MOCK_OCI_DIR}/${key}"
  mkdir -p "${fixture_dir}"

  stage="${TEST_DIR}/_stage-bc-$$-${RANDOM}"
  mkdir -p "${stage}/${project}"
  cat > "${stage}/${project}/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${project}
spec:
  template:
    spec:
      containers:
        - name: ${project}-web
          image: example:1.0
EOF
  ( cd "${stage}" && zip -qr "${fixture_dir}/${project}-1.0-manifests.zip" "${project}" )
  rm -rf "${stage}"

  MANIFESTS_CONTRACT_KIND="${contract_kind}" \
    make_contract_zip "${fixture_dir}/${project}-1.0-contract.zip" shell PascalCase
}

@test "envelopes: a local manifest whose container carries no envelope fails the build" {
  setup_mock_oci
  write_pm
  write_local_manifest redis-deployment.yaml 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  template:
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
'
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "src/kubernetes/redis-deployment.yaml"
  assert_output_contains "container 'redis' is missing requests.cpu, requests.memory, limits.cpu, limits.memory"
}

@test "envelopes: a local manifest declaring all four fields passes" {
  setup_mock_oci
  write_pm
  write_local_manifest redis-deployment.yaml 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  template:
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 64Mi
'
  run_script
  [ "${status}" -eq 0 ]
}

@test "envelopes: a local registered custom resource with no spec.resources fails the build" {
  setup_mock_oci
  write_pm
  export RESOURCE_ENVELOPE_CUSTOM_RESOURCES="widgets.example.com/v1|Widget|.spec.resources"
  write_local_manifest database.yaml 'apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: run-widget
spec:
  instances: 1
  storage:
    size: 10Gi
'
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "src/kubernetes/database.yaml"
  assert_output_contains "widgets.example.com/v1 Widget spec.resources 'run-widget' is missing"
}

@test "envelopes: every offending local manifest is reported before failing" {
  setup_mock_oci
  write_pm
  export RESOURCE_ENVELOPE_CUSTOM_RESOURCES="widgets.example.com/v1|Widget|.spec.resources"
  write_local_manifest redis-deployment.yaml 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  template:
    spec:
      containers:
        - name: redis
'
  write_local_manifest database.yaml 'apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: run-widget
spec:
  instances: 1
'
  run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "container 'redis'"
  assert_output_contains "Widget spec.resources 'run-widget'"
}

@test "envelopes: a local Service and HTTPRoute carry no budget and are not reported" {
  setup_mock_oci
  write_pm
  write_local_manifest redis-service.yaml 'apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  ports:
    - name: redis
      port: 6379
'
  write_local_manifest http-route.yaml 'apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-route
spec:
  rules:
    - backendRefs:
        - name: web
          port: 80
'
  run_script
  [ "${status}" -eq 0 ]
}

@test "envelopes: an environment with no local manifests at all passes" {
  setup_mock_oci
  write_pm
  run_script
  [ "${status}" -eq 0 ]
}

# The recorded decision, pinned so changing it has to argue with a test: an
# imported product bundle was already checked at its own product aggregate, by
# this same assertion, at the level that can fix it. Re-checking it here would
# fail an environment for a manifest it cannot change without a new product
# release - and would let a newer environment build fail a product that built
# green on an older one.
@test "envelopes: an imported product bundle is not re-checked at the environment" {
  setup_mock_oci
  stage_budgetless_child_fixture "alpha:1.0-manifests" "alpha" kubernetes-product-aggregate
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated/alpha/deployment.yaml" ]
}

# Same for an application bundle imported straight into an environment, which is
# the stronger case: even a kubernetes-app-* child is the product aggregate's to
# fail, not the environment's, so the rule stays in exactly one place.
@test "envelopes: an imported application bundle is not re-checked either" {
  setup_mock_oci
  stage_budgetless_child_fixture "alpha:1.0-manifests" "alpha" kubernetes-app-manifests-only
  write_pm "alpha:1.0"
  run_script
  [ "${status}" -eq 0 ]
}

@test "envelopes: a run-platform's own manifests are checked the same way" {
  setup_mock_oci
  stage_own_deploy_manifests_output run-platform-foo
  write_pm
  write_local_manifest redis-deployment.yaml 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  template:
    spec:
      containers:
        - name: redis
'
  PROJECT_NAME=run-platform-foo BUILD_KIND=kubernetes-run-platform-meta-environment run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "container 'redis'"
}

teardown() {
  dump_bats_result
  :
}
