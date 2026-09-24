#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# run-image-deploy-manifests-context.bash - Pins the stock manifest pipeline
# at the deploy-manifests block's dirs.
#
# Sourced by the thin kubernetes-run-image-deploy-manifests-* wrapper
# entrypoints so each stock stage runs against the deploy-manifests tree
# while remaining an individually visible CI step. The overrides live in the
# wrapper's own process and die with it, so the inbound env landscape
# reaches the environment contents block untouched.
#
# OUTPUT_SUB_PATH is swapped for a block-local one. Every derived dir in
# defaults/manifests-sub-path.bash (combined, config, substituted, zip,
# defaults, additional-*) is built from OUTPUT_SUB_PATH, as are
# contract-generate's contract and zip dirs, so moving that ONE value
# relocates all of them together and keeps their sub-paths fixed rather
# than individually overrideable. The generator fleet already does exactly
# this with its own staging dir. Only load-final-kaptainpm-yaml publishes
# user config vars as step outputs, so the swap cannot escape this process.
#
# Requires: defaults/output-sub-path.bash and defaults/environments.bash
# sourced by the wrapper first (OUTPUT_SUB_PATH and
# ENV_ENVIRONMENT_DEPLOY_SOURCE_BASE_PATH).
# shellcheck disable=SC2154 # both provided by the defaults files above

# Derives the layout from the REAL output dir; must be sourced before the
# swap below, since every path hangs off the original value.
# shellcheck source=src/scripts/lib/run-image-deploy-manifests-paths.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-image-deploy-manifests-paths.bash"

export MANIFESTS_SUB_PATH="${RUN_IMAGE_DEPLOY_MANIFESTS_INPUT}"
export DEFAULTS_SUB_PATH="${RUN_IMAGE_DEPLOY_MANIFESTS_DEFAULTS}"
export CONFIG_SUB_PATH="${ENV_ENVIRONMENT_DEPLOY_SOURCE_BASE_PATH}/config"
export OUTPUT_SUB_PATH="${RUN_IMAGE_DEPLOY_MANIFESTS_PIPELINE}"
