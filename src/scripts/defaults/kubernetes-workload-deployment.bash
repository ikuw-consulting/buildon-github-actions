#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# kubernetes-workload-deployment.bash - Default values for Kubernetes Deployment workloads
#
# Source this file to get consistent defaults for Deployment-specific variables.
# Source kubernetes-workload.bash separately for common workload defaults.
#
# Defaults are applied to long-form variables (KUBERNETES_DEPLOYMENT_*) which are
# unique and safe to use when multiple defaults files are sourced together.
# Short names are provided as convenience aliases for single-purpose scripts.
#

# shellcheck disable=SC2034  # Variables used by sourcing scripts

# =============================================================================
# Apply defaults to long-form variables (collision-safe)
# =============================================================================

# Workload naming but unique per type
KUBERNETES_DEPLOYMENT_ENV_SUB_PATH="${KUBERNETES_DEPLOYMENT_ENV_SUB_PATH:-src/deployment-env}"

# Additional labels/annotations
KUBERNETES_DEPLOYMENT_ADDITIONAL_LABELS="${KUBERNETES_DEPLOYMENT_ADDITIONAL_LABELS:-}"
KUBERNETES_DEPLOYMENT_ADDITIONAL_ANNOTATIONS="${KUBERNETES_DEPLOYMENT_ADDITIONAL_ANNOTATIONS:-}"

# Deployment strategy (always RollingUpdate - Recreate causes downtime)
KUBERNETES_DEPLOYMENT_MAX_SURGE="${KUBERNETES_DEPLOYMENT_MAX_SURGE:-1}"
KUBERNETES_DEPLOYMENT_MAX_UNAVAILABLE="${KUBERNETES_DEPLOYMENT_MAX_UNAVAILABLE:-0}"

# Ports (enabled by default; a workload that serves nothing, such as the env
# deploy reconciler, turns them off)
KUBERNETES_DEPLOYMENT_PORTS_ENABLED="${KUBERNETES_DEPLOYMENT_PORTS_ENABLED:-true}"

# =============================================================================
# Convenience short names (for single-purpose generator scripts only)
# =============================================================================

# Workload naming but unique per type
BASE_ENV_SUB_PATH="${KUBERNETES_DEPLOYMENT_ENV_SUB_PATH}"

# Additional labels/annotations
SPECIFIC_LABELS="${KUBERNETES_DEPLOYMENT_ADDITIONAL_LABELS}"
SPECIFIC_ANNOTATIONS="${KUBERNETES_DEPLOYMENT_ADDITIONAL_ANNOTATIONS}"

# Deployment strategy (always RollingUpdate - Recreate causes downtime)
MAX_SURGE="${KUBERNETES_DEPLOYMENT_MAX_SURGE}"
MAX_UNAVAILABLE="${KUBERNETES_DEPLOYMENT_MAX_UNAVAILABLE}"

# Ports
DEPLOYMENT_PORTS_ENABLED="${KUBERNETES_DEPLOYMENT_PORTS_ENABLED}"
