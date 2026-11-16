#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for hook-pre-package-prepare script
# This hook runs after docker build, before manifest packaging
# Verifies that ALL exported variables are properly accessible

bats_require_minimum_version 1.5.0

load helpers

setup() {
  TEST_DIR=$(create_test_dir "hook-pre-package-prepare")
  HOOK_SCRIPT="${TEST_DIR}/test-hook.bash"
  HOOK_OUTPUT="${TEST_DIR}/hook-output.txt"

  # Set required step outputs (from versions-and-naming)
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
  export DOCKER_TAG="1.2.3"
  export DOCKER_IMAGE_NAME="test/my-image"
  export GIT_TAG="1.2.3"
  export PROJECT_NAME="my-image"
  export IS_RELEASE="true"

  # Docker build outputs
  export DOCKER_TARGET_IMAGE_FULL_URI="ghcr.io/test/my-image:1.2.3"
  export DOCKER_CONTEXT_SUB_PATH="target/docker/substituted"

  # Manifest outputs
  export MANIFESTS_SUBSTITUTED_SUB_PATH="target/manifests"

  # Set required workflow inputs
  export DOCKER_TARGET_REGISTRY="ghcr.io"
  export DOCKER_TARGET_NAMESPACE="test"
  export DOCKER_PUSH_TARGETS=""
  export DOCKER_REGISTRY_LOGINS=""
  export OUTPUT_SUB_PATH="target"
  export DOCKER_PUSH_IMAGE_LIST_FILE="target/docker-push-all/image-uris"
  export DOCKERFILE_SUB_PATH="src/docker"
  export DOCKERFILE_SQUASH="squash"
  export DOCKERFILE_NO_CACHE="true"
  export IMAGE_BUILD_COMMAND="docker"
  export DOCKER_CONTEXT_SUB_PATH=""
  export DOCKER_SOURCE_REGISTRY=""
  export DOCKER_SOURCE_NAMESPACE=""
  export DOCKER_SOURCE_IMAGE_NAME=""
  export DOCKER_SOURCE_TAG=""
  export MANIFESTS_SUB_PATH="src/kubernetes"
  export MANIFESTS_REPO_PROVIDER_TYPE="docker"
  export MANIFESTS_PACKAGING_BASE_IMAGE="scratch"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
  export TOKEN_NAME_VALIDATION="match-style"
  export CONFIG_SUB_PATH="src/config"
  export CONFIG_VALUE_TRAILING_NEWLINE="strip-for-single-line"
  export RELEASE_BRANCH="main"
  export DEFAULT_BRANCH="main"
  export CURRENT_BRANCH="main"
  export REPOSITORY_NAME="my-project"
  export REPOSITORY_OWNER="kube-kaptain"
  export ADDITIONAL_RELEASE_BRANCHES=""
  export BUILD_MODE="build_server"
  export BUILD_SCRIPTS_REPO_ROOT="/test/build-scripts-repo-root"
  export BUILD_KIND="kubernetes-app-docker-dockerfile"
  export TAG_VERSION_MAX_PARTS="10"
  export TAG_VERSION_CALCULATION_STRATEGY="git-tag-semver"
  export TAG_VERSION_PATTERN_TYPE=""
  export TAG_VERSION_PREFIX_PARTS="2"
  export TAG_VERSION_SOURCE_SUB_PATH=""
  export TAG_VERSION_SOURCE_FILE_NAME=""
  export TAG_VERSION_SOURCE_CUSTOM_PATTERN=""
  export QC_BLOCK_SLASH_CONTAINING_BRANCHES="false"
  export QC_BLOCK_DOUBLE_HYPHEN_CONTAINING_BRANCHES="true"
  export QC_REQUIRE_CONVENTIONAL_BRANCHES="false"
  export QC_REQUIRE_CONVENTIONAL_COMMITS="false"
  export QC_BLOCK_CONVENTIONAL_COMMITS="false"
  export GITHUB_RELEASE_ENABLED="false"
  export GITHUB_RELEASE_SUBSTITUTED_FILES=""
  export GITHUB_RELEASE_VERBATIM_FILES=""
  export GITHUB_RELEASE_NOTES=""
  export GITHUB_RELEASE_ADD_VERSION_TO_FILENAMES="true"

  # Kubernetes globals
  export KUBERNETES_GLOBAL_ADDITIONAL_LABELS=""
  export KUBERNETES_GLOBAL_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes configmap
  export KUBERNETES_CONFIGMAP_SUB_PATH="src/kubernetes/configmap"
  export KUBERNETES_CONFIGMAP_NAME_CHECKSUM_INJECTION="true"
  export KUBERNETES_CONFIGMAP_ADDITIONAL_LABELS=""
  export KUBERNETES_CONFIGMAP_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes secret-template
  export KUBERNETES_SECRET_TEMPLATE_SUB_PATH="src/kubernetes/secret-template"
  export KUBERNETES_SECRET_TEMPLATE_NAME_CHECKSUM_INJECTION="true"
  export KUBERNETES_SECRET_TEMPLATE_ADDITIONAL_LABELS=""
  export KUBERNETES_SECRET_TEMPLATE_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes serviceaccount
  export KUBERNETES_SERVICEACCOUNT_NAME_SUFFIX=""
  export KUBERNETES_SERVICEACCOUNT_COMBINED_SUB_PATH=""
  export KUBERNETES_SERVICEACCOUNT_ADDITIONAL_LABELS=""
  export KUBERNETES_SERVICEACCOUNT_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes workload
  export KUBERNETES_WORKLOAD_TYPE="deployment"
  export KUBERNETES_WORKLOAD_NAME_SUFFIX=""
  export KUBERNETES_WORKLOAD_COMBINED_SUB_PATH=""
  export KUBERNETES_WORKLOAD_REPLICAS="1"
  export KUBERNETES_WORKLOAD_REVISION_HISTORY_LIMIT="3"
  export KUBERNETES_WORKLOAD_MIN_READY_SECONDS="0"
  export KUBERNETES_WORKLOAD_PRIORITY_CLASS_NAME=""
  export KUBERNETES_WORKLOAD_CONTAINER_COMMAND=""
  export KUBERNETES_WORKLOAD_CONTAINER_ARGS=""
  export KUBERNETES_WORKLOAD_NODE_SELECTOR=""
  export KUBERNETES_WORKLOAD_DNS_POLICY=""
  export KUBERNETES_WORKLOAD_TOLERATIONS=""

  # Kubernetes deployment
  export KUBERNETES_DEPLOYMENT_ENV_SUB_PATH="src/kubernetes/deployment-env"
  export KUBERNETES_DEPLOYMENT_ADDITIONAL_LABELS=""
  export KUBERNETES_DEPLOYMENT_ADDITIONAL_ANNOTATIONS=""
  export KUBERNETES_DEPLOYMENT_MAX_SURGE="1"
  export KUBERNETES_DEPLOYMENT_MAX_UNAVAILABLE="0"

  # Kubernetes statefulset
  export KUBERNETES_STATEFULSET_ENV_SUB_PATH="src/kubernetes/statefulset-env"
  export KUBERNETES_STATEFULSET_SERVICE_NAME=""
  export KUBERNETES_STATEFULSET_POD_MANAGEMENT_POLICY="OrderedReady"
  export KUBERNETES_STATEFULSET_UPDATE_STRATEGY_TYPE="RollingUpdate"
  export KUBERNETES_STATEFULSET_PVC_ENABLED="false"
  export KUBERNETES_STATEFULSET_PVC_STORAGE_CLASS=""
  export KUBERNETES_STATEFULSET_PVC_STORAGE_SIZE="1Gi"
  export KUBERNETES_STATEFULSET_PVC_ACCESS_MODE="ReadWriteOnce"
  export KUBERNETES_STATEFULSET_PVC_VOLUME_NAME="data"
  export KUBERNETES_STATEFULSET_PVC_MOUNT_PATH="/data"
  export KUBERNETES_STATEFULSET_ADDITIONAL_LABELS=""
  export KUBERNETES_STATEFULSET_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes daemonset
  export KUBERNETES_DAEMONSET_ENV_SUB_PATH="src/kubernetes/daemonset-env"
  export KUBERNETES_DAEMONSET_UPDATE_STRATEGY_TYPE="RollingUpdate"
  export KUBERNETES_DAEMONSET_MAX_UNAVAILABLE="1"
  export KUBERNETES_DAEMONSET_HOST_NETWORK="false"
  export KUBERNETES_DAEMONSET_HOST_PID="false"
  export KUBERNETES_DAEMONSET_HOST_IPC="false"
  export KUBERNETES_DAEMONSET_RUN_AS_NON_ROOT="true"
  export KUBERNETES_DAEMONSET_PRIVILEGED="false"
  export KUBERNETES_DAEMONSET_DNS_POLICY=""
  export KUBERNETES_DAEMONSET_TOLERATIONS=""
  export KUBERNETES_DAEMONSET_NODE_SELECTOR=""
  export KUBERNETES_DAEMONSET_ADDITIONAL_LABELS=""
  export KUBERNETES_DAEMONSET_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes cronjob
  export KUBERNETES_CRONJOB_NAME_SUFFIX=""
  export KUBERNETES_CRONJOB_COMBINED_SUB_PATH=""
  export KUBERNETES_CRONJOB_CONCURRENCY_POLICY="Forbid"
  export KUBERNETES_CRONJOB_STARTING_DEADLINE_SECONDS=""
  export KUBERNETES_CRONJOB_SUCCESSFUL_JOBS_HISTORY_LIMIT="1"
  export KUBERNETES_CRONJOB_FAILED_JOBS_HISTORY_LIMIT="5"
  export KUBERNETES_CRONJOB_BACKOFF_LIMIT="3"
  export KUBERNETES_CRONJOB_COMPLETIONS="1"
  export KUBERNETES_CRONJOB_PARALLELISM="1"
  export KUBERNETES_CRONJOB_ACTIVE_DEADLINE_SECONDS=""
  export KUBERNETES_CRONJOB_TTL_SECONDS_AFTER_FINISHED=""
  export KUBERNETES_CRONJOB_RESTART_POLICY="Never"
  export KUBERNETES_CRONJOB_ENV_SUB_PATH="src/kubernetes/cronjob-env"
  export KUBERNETES_CRONJOB_ADDITIONAL_LABELS=""
  export KUBERNETES_CRONJOB_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes job
  export KUBERNETES_JOB_NAME_SUFFIX=""
  export KUBERNETES_JOB_COMBINED_SUB_PATH=""
  export KUBERNETES_JOB_BACKOFF_LIMIT="3"
  export KUBERNETES_JOB_COMPLETIONS="1"
  export KUBERNETES_JOB_PARALLELISM="1"
  export KUBERNETES_JOB_ACTIVE_DEADLINE_SECONDS=""
  export KUBERNETES_JOB_TTL_SECONDS_AFTER_FINISHED="3600"
  export KUBERNETES_JOB_RESTART_POLICY="Never"
  export KUBERNETES_JOB_ENV_SUB_PATH="src/kubernetes/job-env"
  export KUBERNETES_JOB_ADDITIONAL_LABELS=""
  export KUBERNETES_JOB_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes service
  export KUBERNETES_SERVICE_TYPE="ClusterIP"
  export KUBERNETES_SERVICE_PORT="80"
  export KUBERNETES_SERVICE_TARGET_PORT="1024"
  export KUBERNETES_SERVICE_PROTOCOL="TCP"
  export KUBERNETES_SERVICE_PORT_NAME=""
  export KUBERNETES_SERVICE_NODE_PORT=""
  export KUBERNETES_SERVICE_EXTERNAL_NAME=""
  export KUBERNETES_SERVICE_EXTERNAL_TRAFFIC_POLICY=""
  export KUBERNETES_SERVICE_NAME_SUFFIX=""
  export KUBERNETES_SERVICE_COMBINED_SUB_PATH=""
  export KUBERNETES_SERVICE_GENERATION_ENABLED=""
  export KUBERNETES_SERVICE_ADDITIONAL_LABELS=""
  export KUBERNETES_SERVICE_ADDITIONAL_ANNOTATIONS=""

  # Kubernetes poddisruptionbudget
  export KUBERNETES_PODDISRUPTIONBUDGET_GENERATION_ENABLED=""
  export KUBERNETES_PODDISRUPTIONBUDGET_NAME_SUFFIX=""
  export KUBERNETES_PODDISRUPTIONBUDGET_COMBINED_SUB_PATH=""
  export KUBERNETES_PODDISRUPTIONBUDGET_STRATEGY="max-unavailable"
  export KUBERNETES_PODDISRUPTIONBUDGET_VALUE="1"
  export KUBERNETES_PODDISRUPTIONBUDGET_ADDITIONAL_LABELS=""
  export KUBERNETES_PODDISRUPTIONBUDGET_ADDITIONAL_ANNOTATIONS=""
}

teardown() {
  dump_bats_result
  :
}

@test "hook-pre-package-prepare exports ALL variables (self-validating)" {
  # Extract exports directly from the hook script - test fails if script adds new exports
  local exports
  exports=$(extract_hook_exports "$SCRIPTS_DIR/hook-pre-package-prepare")

  # Generate a hook that dumps all expected exports
  generate_export_dump_hook "$HOOK_SCRIPT" "$HOOK_OUTPUT" $exports

  export HOOK_PRE_PACKAGE_PREPARE_SCRIPT_SUB_PATH="${HOOK_SCRIPT}"
  export HOOK_OUTPUT

  run "$SCRIPTS_DIR/hook-pre-package-prepare"
  [ "$status" -eq 0 ]
  [ -f "${HOOK_OUTPUT}" ]

  # Verify all exports are accessible (not unset)
  verify_all_exports_accessible "$HOOK_OUTPUT" $exports
}

@test "hook-pre-package-prepare skips when no hook script configured" {
  unset HOOK_PRE_PACKAGE_PREPARE_SCRIPT_SUB_PATH

  run "$SCRIPTS_DIR/hook-pre-package-prepare"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No hook script configured"* ]] || return 1
}

@test "hook-pre-package-prepare exports all inputs from sourced defaults (self-validating)" {
  # This test ensures every input variable defined in sourced defaults files is exported
  # If a new input is added to a defaults file, this test will fail until the hook exports it
  run verify_hook_exports_all_inputs "$SCRIPTS_DIR/hook-pre-package-prepare"
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&3
    return 1
  fi
}

@test "hook-pre-package-prepare DOCKER_IMAGE_FULL_URI aliases DOCKER_TARGET_IMAGE_FULL_URI" {
  cat > "${HOOK_SCRIPT}" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "TARGET=${DOCKER_TARGET_IMAGE_FULL_URI}"
  echo "ALIAS=${DOCKER_IMAGE_FULL_URI}"
} > "${HOOK_OUTPUT}"
EOF
  chmod +x "${HOOK_SCRIPT}"

  export HOOK_PRE_PACKAGE_PREPARE_SCRIPT_SUB_PATH="${HOOK_SCRIPT}"
  export HOOK_OUTPUT

  run "$SCRIPTS_DIR/hook-pre-package-prepare"
  [ "$status" -eq 0 ]
  [ -f "${HOOK_OUTPUT}" ]
  grep -q "TARGET=ghcr.io/test/my-image:1.2.3" "${HOOK_OUTPUT}"
  grep -q "ALIAS=ghcr.io/test/my-image:1.2.3" "${HOOK_OUTPUT}"
}
