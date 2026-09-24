#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/kubernetes-run-aggregate (shared by env and RP builds,
# kind derived from the project-name prefix).
#
# Covers kind derivation + naming validation, the kind-keyed composition
# rule (envs aggregate no run-* children; RPs aggregate run-* but never
# other platforms), self-inclusion of the build's own deploy-manifests
# set, end-to-end staging via mocked OCI fetches, per-bundle scheme
# conversion, cross-bundle defaults merge / conflict, local manifests
# fold + override flag, the secrets-dir preflight (both kinds), reserved
# env-lineage-data filename squat, and the contents list output.

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/kubernetes-run-aggregate"

setup() {
  TEST_DIR=$(create_test_dir "kubernetes-run-aggregate")
  mkdir -p "${TEST_DIR}/kaptainpm/final"
  export GITHUB_OUTPUT="${TEST_DIR}/github-output"
  : > "${GITHUB_OUTPUT}"
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

  # Passthrough by real path (a symlink would break the util's relative
  # sourcing of ../defaults from inside the mock dir).
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

# Minimal deploy-manifests output for the self-inclusion: the own tree (no
# tokens) and a schema-valid contract with nothing required. Lives under the
# block's own pipeline dir, since that stage runs with a block-local
# OUTPUT_SUB_PATH rather than writing into the environment contents
# namespace - see lib/run-image-deploy-manifests-paths.bash.
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
  : "${OUTPUT_SUB_PATH:=kaptain-out}"
  : "${TOKEN_DELIMITER_STYLE:=shell}"
  : "${TOKEN_NAME_STYLE:=PascalCase}"
  : "${MANIFESTS_SUB_PATH:=src/kubernetes}"
  : "${ENV_ALLOW_LOCAL_MANIFESTS_OVERRIDE:=false}"
  : "${BUILD_MODE:=build_server}"
  run env \
    PROJECT_NAME="${PROJECT_NAME}" \
    RUN_BUILD_KIND="${RUN_BUILD_KIND:-}" \
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
# Kind derivation + naming validation
# =============================================================================

@test "kind: run- prefix derives environment and emits ENVIRONMENT_NAME/SHORT_NAME" {
  write_pm
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  PROJECT_NAME=run-foo run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Build kind: environment"
  [ "$(github_output_value ENVIRONMENT_NAME)" = "run-foo" ]
  [ "$(github_output_value ENVIRONMENT_SHORT_NAME)" = "foo" ]
}

@test "kind: run-platform- prefix derives run-platform and strips the full prefix" {
  write_pm
  setup_mock_oci
  stage_own_deploy_manifests_output run-platform-foo
  PROJECT_NAME=run-platform-foo run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "Build kind: run-platform"
  [ "$(github_output_value ENVIRONMENT_NAME)" = "run-platform-foo" ]
  [ "$(github_output_value ENVIRONMENT_SHORT_NAME)" = "foo" ]
}

@test "kind: supplied RUN_BUILD_KIND mismatching the name prefix fails" {
  write_pm
  PROJECT_NAME=run-foo RUN_BUILD_KIND=run-platform run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "does not match PROJECT_NAME"
}

@test "naming: rejects bare name without run- prefix" {
  write_pm
  PROJECT_NAME=foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "does not match the run naming rule"
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
  PROJECT_NAME=run-platform-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "inside another run-platform is not"
  assert_output_contains "run-platform-other"
}

@test "composition: rp accepts run-* (non-platform) children" {
  setup_mock_oci
  stage_oci_fixture "run-child:1.0-manifests" "run-child" shell PascalCase "Replicas=2"
  stage_own_deploy_manifests_output run-platform-foo
  write_pm "run-child:1.0"
  PROJECT_NAME=run-platform-foo run_script
  [ "${status}" -eq 0 ]
  [ -f "${TEST_DIR}/kaptain-out/run-platform-meta-environment/manifests-aggregated/run-child/deployment.yaml" ]
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
  PROJECT_NAME=run-platform-foo run_script
  [ "${status}" -eq 0 ]
  assert_output_contains "self-referencing"
  [ -f "${TEST_DIR}/kaptain-out/run-platform-meta-environment/manifests-aggregated/run-platform-foo/deployment.yaml" ]
}

@test "self-inclusion: rp fails loudly when its deploy-manifests output is missing" {
  write_pm
  setup_mock_oci
  PROJECT_NAME=run-platform-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "Own deploy-manifests tree not found"
  assert_output_contains "Did the deploy-manifests block run first?"
}

# An environment is seeded BY a run-platform, so its deployer manifests are
# applied by that run-platform and have no business in its own content. This
# is also what frees an environment build from depending on the
# deploy-manifests set at all, which is why the two builds order differently.
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
  PROJECT_NAME=run-platform-foo run_script
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
# Secrets-dir preflight (both kinds - RPs have their own passphrase secret)
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
  PROJECT_NAME=run-platform-foo run_script
  [ "${status}" -ne 0 ]
  assert_output_contains "PLAINTEXT secret present at build time"
}

@test "preflight: nested secret value is accepted and its type published" {
  setup_mock_decryption_providers
  write_pm
  mkdir -p "${TEST_DIR}/src/secrets/Vendor"
  printf 'ciphertext' > "${TEST_DIR}/src/secrets/Vendor/DbPassword.age"
  PROJECT_NAME=run-foo run_script
  assert_output_contains "OK: all values carry the 'age' suffix."
  grep -qx "RUN_SECRETS_ENCRYPTION_TYPE=age" "${GITHUB_OUTPUT}"
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
  assert_docker_called "run --rm --entrypoint ls ghcr.io/kube-kaptain/image/image-environment-deploy-trixie-slim:1.0.14.1.36.1 /kd/bin/plugins/decryption-providers"
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

teardown() {
  dump_bats_result
  :
}

# =============================================================================
# Schema validation goes through SCHEMA_VALIDATION_COMMAND
# =============================================================================
# validate-tooling installs jv, not check-jsonschema, on build servers. A
# direct check-jsonschema call exits 127 there and every env build fails at the
# cleanup-policy step reporting "does not validate".

@test "cleanup policy: validated with SCHEMA_VALIDATION_COMMAND, never check-jsonschema directly" {
  local fake_bin="${TEST_DIR}/fake-bin"
  mkdir -p "${fake_bin}"
  printf '#!/usr/bin/env bash\necho "check-jsonschema called directly" >&2\nexit 127\n' > "${fake_bin}/check-jsonschema"
  printf '#!/usr/bin/env bash\necho "$@" >> "%s/validator.log"\nexit 0\n' "${TEST_DIR}" > "${fake_bin}/ok-validator"
  chmod +x "${fake_bin}/check-jsonschema" "${fake_bin}/ok-validator"

  write_pm
  setup_mock_oci
  stage_own_deploy_manifests_output run-foo
  PATH="${fake_bin}:${PATH}" SCHEMA_VALIDATION_COMMAND="${fake_bin}/ok-validator" PROJECT_NAME=run-foo run_script
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"check-jsonschema called directly"* ]] || return 1
  grep -q "cleanup" "${TEST_DIR}/validator.log"
}
