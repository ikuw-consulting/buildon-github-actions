#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# run-image-deploy-manifests-paths.bash - The one definition of where the
# deploy-manifests block's directories live.
#
# Pure derivation: sets no pins, exports nothing, overrides nothing. Safe to
# source from any script that needs to KNOW the layout, including ones that
# must keep running against the real output dir. The pinning itself lives in
# run-image-deploy-manifests-context.bash, which sources this.
#
# Two roots under the block base, deliberately siblings rather than nested:
#
#   <base>/manifests, <base>/defaults   the block's INPUT tree, staged from
#                                       the user's deploy source (or
#                                       generated fill-the-gaps content)
#   <base>/pipeline                     the block's OUTPUT_SUB_PATH: the
#                                       stock manifest pipeline's whole
#                                       kaptain-out-shaped tree, so its
#                                       derived dirs (manifests/combined,
#                                       .../substituted, .../zip, ...) land
#                                       inside the block instead of the
#                                       environment contents namespace
#
# Nesting pipeline output under the input tree would put combined/,
# substituted/ and friends inside the dir package-prepare scans for source
# manifests, hence the split.
#
# Requires: defaults/output-sub-path.bash sourced first.
# shellcheck disable=SC2034  # consumed by sourcing scripts
# shellcheck disable=SC2154  # OUTPUT_SUB_PATH provided by the defaults file

if [[ -z "${OUTPUT_SUB_PATH:-}" ]]; then
  log_error "OUTPUT_SUB_PATH is not set. Source defaults/output-sub-path.bash before run-image-deploy-manifests-paths.bash."
  # shellcheck disable=SC2317 # dual-mode: works whether sourced or executed
  return 1 2>/dev/null || exit 1
fi

RUN_IMAGE_DEPLOY_MANIFESTS_BASE="${OUTPUT_SUB_PATH}/run-image-deploy-manifests"
RUN_IMAGE_DEPLOY_MANIFESTS_INPUT="${RUN_IMAGE_DEPLOY_MANIFESTS_BASE}/manifests"
RUN_IMAGE_DEPLOY_MANIFESTS_DEFAULTS="${RUN_IMAGE_DEPLOY_MANIFESTS_BASE}/defaults"
RUN_IMAGE_DEPLOY_MANIFESTS_PIPELINE="${RUN_IMAGE_DEPLOY_MANIFESTS_BASE}/pipeline"

# The pipeline's substituted tree, i.e. the finished deploy-manifests set.
# Read from OUTSIDE the block by the aggregate's self-inclusion, which runs
# against the real output dir and so cannot derive it from its own
# OUTPUT_SUB_PATH.
RUN_IMAGE_DEPLOY_MANIFESTS_SUBSTITUTED="${RUN_IMAGE_DEPLOY_MANIFESTS_PIPELINE}/manifests/substituted"
RUN_IMAGE_DEPLOY_MANIFESTS_CONTRACT="${RUN_IMAGE_DEPLOY_MANIFESTS_PIPELINE}/manifests/contract"
