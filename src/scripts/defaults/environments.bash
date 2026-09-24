#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# environments.bash - Defaults for env (`run-*`) and run-platform
# (`run-platform-*`) build flows. See EnvFlow.md and RpFlow.md.
#
# ENV_* names are the env/RP-scope spec-field projections used by
# load-final-kaptainpm-yaml; the unprefixed names are generic build-time
# toggles consumed by the workload stage and finalise.
#
# shellcheck disable=SC2034  # Variables used by sourcing scripts

# --- env/RP-scope spec field defaults (see spec.main.{environment,runPlatform}) ---

ENV_ALLOW_LOCAL_MANIFESTS_OVERRIDE="${ENV_ALLOW_LOCAL_MANIFESTS_OVERRIDE:-false}"
ENV_ENVIRONMENT_DEPLOY_SOURCE_BASE_PATH="${ENV_ENVIRONMENT_DEPLOY_SOURCE_BASE_PATH:-src/environment}"
ENV_GENERATE_IDEAL_ENVIRONMENT_DEPLOY_MANIFESTS="${ENV_GENERATE_IDEAL_ENVIRONMENT_DEPLOY_MANIFESTS:-true}"
# How a run-platform applies this environment's deploy-manifests set.
# Matches the schema default; seed-and-compare is the marked case, so the
# marker manifest is emitted for the default as well as an explicit setting.
ENV_IMAGE_DEPLOY_MANIFESTS_APPLY_MODE="${ENV_IMAGE_DEPLOY_MANIFESTS_APPLY_MODE:-seed-and-compare}"
ENV_DEPLOY_MODE="${ENV_DEPLOY_MODE:-deployment}"
ENV_CHECKSUM_SECRETS_TIMING="${ENV_CHECKSUM_SECRETS_TIMING:-build}"

# Cleanup config has no defaults here. It arrives whole, as one JSON value
# in ENV_CLEAN_UP, and the safe defaults (preview only, remove nothing) are
# applied structurally where the policy document is built, in
# kubernetes-run-aggregate. Splitting them across both places would let the
# shipped document and the build disagree about what the default IS.
ENV_IMAGE_AUTO_UPDATE_PROVIDER="${ENV_IMAGE_AUTO_UPDATE_PROVIDER:-keelson}"

# Auto-update annotation settings consumed by the deploy-image manifest
# generation. Policy 'force' is keel-only (belt-and-braces re-check at
# generation time; the schema also rejects it for other providers).
# Poll schedule is a plain single-unit duration, rendered per provider.
# Field-manager strategy is keelson-only; ignored for keel and none.
ENV_IMAGE_AUTO_UPDATE_POLICY="${ENV_IMAGE_AUTO_UPDATE_POLICY:-patch}"
ENV_IMAGE_AUTO_UPDATE_TRIGGER="${ENV_IMAGE_AUTO_UPDATE_TRIGGER:-poll}"
ENV_IMAGE_AUTO_UPDATE_POLL_SCHEDULE="${ENV_IMAGE_AUTO_UPDATE_POLL_SCHEDULE:-1m}"
ENV_IMAGE_AUTO_UPDATE_FIELD_MANAGER_STRATEGY="${ENV_IMAGE_AUTO_UPDATE_FIELD_MANAGER_STRATEGY:-mimic}"

# Cluster-scoped delegation doubles as the deploy permission model:
# 'self' (default) generates cluster-admin RBAC and the env applies its own
# cluster-scoped resources; 'parent' generates namespace-admin RBAC (a
# RoleBinding to the built-in 'admin' ClusterRole) and the env's
# cluster-scoped resources are packaged into the on-behalf dir for the
# run-platform parent. Env-only; RP is the root and is always 'self'.
ENV_CLUSTER_SCOPED_DELEGATION="${ENV_CLUSTER_SCOPED_DELEGATION:-self}"

# Env deploy base image - composed at build time as
# '<registry>/[<namespace>/]image/image-environment-deploy-<family>:<version>'
# and injected into the env image Dockerfile FROM. Never injected into
# manifests. INCLUDE_NAMESPACE is the explicit registry-discriminator flag:
# true (default, matching the namespace default having a value) includes
# the namespace segment; false ignores the namespace value entirely and
# condenses the segment out. No present-empty magic - every value here
# is a plain overridable default, so it survives any transport (GH env
# plumbing included).
ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_REGISTRY="${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_REGISTRY:-ghcr.io}"
ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_INCLUDE_NAMESPACE="${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_INCLUDE_NAMESPACE:-true}"
ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_NAMESPACE="${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_NAMESPACE:-kube-kaptain}"
ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_FAMILY="${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_FAMILY:-trixie-slim}"
ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_VERSION="${ENV_ENVIRONMENT_DEPLOY_BASE_IMAGE_VERSION:-1.0.14.1.35.1}"

# --- workload finalise: signoff ---

MANIFESTS_SIGNOFFS_SUB_PATH="${MANIFESTS_SIGNOFFS_SUB_PATH:-src/signoffs}"
MANIFESTS_SIGNOFFS_KINDS_FILE="${MANIFESTS_SIGNOFFS_KINDS_FILE:-default-1.1.txt}"
MANIFESTS_TRUSTED_CONTRIBUTORS_ONLY="${MANIFESTS_TRUSTED_CONTRIBUTORS_ONLY:-false}"

# --- workload finalise: secrets ---

# Env-only: if this directory exists, checksum_secrets runs on
# *.template.yaml Secrets. RP skips checksum_secrets regardless.
# SECRETS_SUB_PATH / CONFIG_SUB_PATH are spec.global projections (shared
# with the wider build, not env/RP-scoped).
SECRETS_SUB_PATH="${SECRETS_SUB_PATH:-src/secrets}"
CONFIG_SUB_PATH="${CONFIG_SUB_PATH:-src/config}"

# Unreferenced-value gate: config/secret value files no token references.
# true (default) fails the build (local builds warn); false warns only.
# Child defaults are exempt - an unused default is a permitted fallback.
ENV_FAIL_ON_UNREFERENCED_CONFIG_OR_SECRETS="${ENV_FAIL_ON_UNREFERENCED_CONFIG_OR_SECRETS:-true}"

# --- workload finalise: resource checksum ---

# Presence of the '-checksum' suffix on a resource name is the trigger;
# resources without it pass through untouched. No enable/disable toggle.
# Base32 suffix length. Warn at <4 or >12. Hard fail >52.
RESOURCE_CHECKSUM_LENGTH="${RESOURCE_CHECKSUM_LENGTH:-5}"

# Versioned file NAMES resolved in fixed src/data/ sub dirs (extensions
# can ship additional lists there); the selected file replaces, never
# merges. See the data files' own headers for the immutability model.
MANIFESTS_CHECKSUM_ORDER_FILE="${MANIFESTS_CHECKSUM_ORDER_FILE:-default-1.1.txt}"
# Cluster-scoped Kind list driving the clusterScopedDelegation=parent
# carve-out (env-only; RP is the root and always 'self').
MANIFESTS_CLUSTER_SCOPED_KINDS_FILE="${MANIFESTS_CLUSTER_SCOPED_KINDS_FILE:-default-1.1.txt}"
