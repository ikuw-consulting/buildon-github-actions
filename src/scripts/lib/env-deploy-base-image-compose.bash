# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# env-deploy-base-image-compose.bash - Compose the env deploy base image
# OCI reference used as the FROM in the env image's Dockerfile.
#
# Composition: '<registry>/[<namespace>/]image/image-environment-deploy-<family>:<version>'
# The middle two segments ('image/image-environment-deploy-') are fixed
# convention and not configurable. The leaf is '<family>:<version>'.
#
# Inputs (positional; callers usually pass the ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_*
# env vars from defaults/environments.bash):
#   $1 registry   - hostname (required; e.g. ghcr.io)
#   $2 namespace  - org/user segment (optional; empty omits the segment)
#   $3 family     - image family (required; see the list below)
#   $4 version    - image tag (required; see the scheme below)
#
# Version scheme: '<deploy-scripts-version>.<kube-major>.<kube-minor>.<patch>'
# where the deploy-scripts version is itself three-part, so a tag carries six
# numeric segments. 1.0.14.1.35.1 is deploy scripts 1.0.14, built against
# Kubernetes 1.35, first patch of that pairing. The Kubernetes segments are
# what make a family+version pick a kubectl that matches the cluster; the
# patch segment moves for image rebuilds that change neither.
#
# Families, each its own repo, tags listing the versions available:
#   * trixie-slim: https://github.com/kube-kaptain/image-environment-deploy-trixie-slim/tags
#
# Result: writes the composed reference to stdout. Returns non-zero with
# log_error on validation failure. Uses 'return' (not exit) so callers can
# decide how to handle errors.
#
# Empty-namespace semantics: an empty namespace omits the segment entirely
# ('<registry>/image/image-environment-deploy-<family>:<version>'). Callers
# that want the shipped default registry+namespace pair should rely on the
# defaults file rather than passing empty values here; this function trusts
# its inputs.
#
# Requires: log.bash sourced by the caller.

env_deploy_base_image_compose() {
  local registry="${1:-}"
  local namespace="${2:-}"
  local family="${3:-}"
  local version="${4:-}"

  if [[ -z "${registry}" ]]; then
    log_error "env_deploy_base_image_compose: registry is required"
    return 1
  fi
  if [[ -z "${family}" ]]; then
    log_error "env_deploy_base_image_compose: family is required"
    return 1
  fi
  if [[ -z "${version}" ]]; then
    log_error "env_deploy_base_image_compose: version is required"
    return 1
  fi
  if [[ "${registry}" == */* ]]; then
    log_error "env_deploy_base_image_compose: registry must not contain '/': ${registry}"
    return 1
  fi
  if [[ "${namespace}" == */* ]]; then
    log_error "env_deploy_base_image_compose: namespace must not contain '/': ${namespace}"
    return 1
  fi
  if [[ "${family}" == */* || "${family}" == *:* ]]; then
    log_error "env_deploy_base_image_compose: family must not contain '/' or ':': ${family}"
    return 1
  fi
  if [[ "${version}" == */* || "${version}" == *:* ]]; then
    log_error "env_deploy_base_image_compose: version must not contain '/' or ':': ${version}"
    return 1
  fi

  if [[ -n "${namespace}" ]]; then
    printf '%s/%s/image/image-environment-deploy-%s:%s\n' \
      "${registry}" "${namespace}" "${family}" "${version}"
  else
    printf '%s/image/image-environment-deploy-%s:%s\n' \
      "${registry}" "${family}" "${version}"
  fi
}

# Compose the configured env deploy base image from the
# ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_* vars (defaults/environments.bash).
# INCLUDE_NAMESPACE=false is the explicit registry-discriminator: the
# namespace value (including its default) is ignored and the segment
# condensed out of the composed reference.
# Usage: env_deploy_base_image_configured
# shellcheck disable=SC2154 # ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_* set by defaults/environments.bash
env_deploy_base_image_configured() {
  local namespace=""
  if [[ "${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_INCLUDE_NAMESPACE}" == "true" ]]; then
    namespace="${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_NAMESPACE}"
  fi
  env_deploy_base_image_compose \
    "${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_REGISTRY}" \
    "${namespace}" \
    "${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_FAMILY}" \
    "${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_VERSION}"
}
