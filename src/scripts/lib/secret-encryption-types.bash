#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# secret-encryption-types.bash - The encryption types an encrypted secret value
# file may carry, and the token name such a file stands for.
#
# An encrypted value lives at <SECRETS_SUB_PATH>/<Token>.<type>, where <Token>
# may be a nested path (Vendor/DbPassword) exactly like a config token, and
# <type> may itself contain dots (sha256.aes256.10k). The type is therefore not
# "everything after the first dot": it is whichever supported type the name
# ends in.
#
# The supported types are whatever the configured env deploy base image can
# decrypt: one decrypt-<type> provider per type in its decryption providers
# dir (kaptain-deploy-scripts, copied into the base image). That image is the
# FROM of the env image the package step builds, so pulling it here costs
# nothing the build was not already going to spend. The listing is read once
# per process with an ls inside the image.
#
# Functions:
#   secret_encryption_types_load  - Sets SECRET_ENCRYPTION_TYPES (newline list,
#                                   longest first) on first use
#   secret_value_token_name       - <rel-path> -> token name; returns 1 if the
#                                   path carries no supported type suffix
#   secret_value_file_for_token   - <secrets-dir> <token> -> the value file;
#                                   returns 1 if there is none
#
# Requires: log.bash, defaults/environments.bash and
# lib/env-deploy-base-image-compose.bash sourced by the caller, and
# IMAGE_BUILD_COMMAND (docker or podman) set.

SECRET_ENCRYPTION_PROVIDERS_IMAGE_PATH="/kd/bin/plugins/decryption-providers"
SECRET_ENCRYPTION_TYPES=""

secret_encryption_types_load() {
  [[ -n "${SECRET_ENCRYPTION_TYPES}" ]] && return 0

  local image
  image=$(env_deploy_base_image_configured) || return 1
  log "Listing the secret encryption types ${image} can decrypt..."
  local listing
  if ! listing=$("${IMAGE_BUILD_COMMAND:?IMAGE_BUILD_COMMAND is required}" run --rm \
      --entrypoint ls "${image}" "${SECRET_ENCRYPTION_PROVIDERS_IMAGE_PATH}"); then
    log_error "Could not list ${SECRET_ENCRYPTION_PROVIDERS_IMAGE_PATH} in ${image}"
    log_error "The env deploy base image supplies the supported secret encryption types."
    return 1
  fi

  # Longest first, so a type that ends another type's name can never win.
  SECRET_ENCRYPTION_TYPES=$(
    printf '%s\n' "${listing}" \
      | sed -n 's/^decrypt-//p' \
      | awk '{ print length($0) "\t" $0 }' \
      | LC_ALL=C sort -k1,1nr -k2,2 \
      | cut -f2
  )
  if [[ -z "${SECRET_ENCRYPTION_TYPES}" ]]; then
    log_error "${image} has no decrypt-<type> providers in ${SECRET_ENCRYPTION_PROVIDERS_IMAGE_PATH}"
    return 1
  fi
}

# Usage: secret_value_token_name <path-relative-to-secrets-dir>
# Example: Vendor/DbPassword.sha256.aes256.10k -> Vendor/DbPassword
secret_value_token_name() {
  local rel="${1}"
  local type
  while IFS= read -r type; do
    [[ -z "${type}" ]] && continue
    if [[ "${rel}" == ?*".${type}" ]]; then
      printf '%s\n' "${rel%".${type}"}"
      return 0
    fi
  done <<< "${SECRET_ENCRYPTION_TYPES}"
  return 1
}

# Usage: secret_value_file_for_token <secrets-dir> <token>
# First supported type in LC_ALL=C order, so the answer is deterministic if a
# token somehow carries more than one (the aggregate preflight refuses that).
secret_value_file_for_token() {
  local secrets_dir="${1}"
  local token="${2}"
  local type
  while IFS= read -r type; do
    [[ -z "${type}" ]] && continue
    if [[ -f "${secrets_dir}/${token}.${type}" ]]; then
      printf '%s\n' "${secrets_dir}/${token}.${type}"
      return 0
    fi
  done < <(printf '%s\n' "${SECRET_ENCRYPTION_TYPES}" | LC_ALL=C sort)
  return 1
}
