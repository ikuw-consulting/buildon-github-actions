#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# content-resolve.bash - Resolve and stage spec.contents / spec.templates entries.
#
# Sourced library exposing functions to resolve OCI artifact references,
# fetch and unpack the manifests + contract zips that each entry contains,
# and stage the result into per-entry directories. Used by product-aggregate
# (contents flavour) and later by app/bundle and env/rp builds (templates
# flavour). Layers do not use this lib — they have their own lib/layer-merge
# and stage under a different tree entirely.
#
# CONTENT_FLAVOUR contract (required, validated at source time):
#   contents      - read spec.contents[], stage under ${OUTPUT_SUB_PATH}/contents/,
#                   produce contents.yaml + contents-resolved.yaml
#   templates     - read spec.templates[], stage under ${OUTPUT_SUB_PATH}/templates/,
#                   produce templates.yaml + templates-resolved.yaml
#   environment   - env builds: read spec.contents[], stage under
#                   ${OUTPUT_SUB_PATH}/environment/, produce environment.yaml +
#                   environment-resolved.yaml
#   run-platform  - RP builds: read spec.contents[], stage under
#                   ${OUTPUT_SUB_PATH}/run-platform/, produce run-platform.yaml +
#                   run-platform-resolved.yaml
# A given script picks the flavour appropriate to its phase. env/rp builds will
# run two passes (environment/run-platform then templates) in separate scripts.
#
# Required env to source this file:
#   OUTPUT_SUB_PATH   - set by defaults/output-sub-path.bash before sourcing
#   CONTENT_FLAVOUR   - set by caller before sourcing; one of contents|templates
#   log / log_error   - functions from lib/log.bash sourced before this file
#
# Exported by sourcing this file:
#   CONTENT_BASE              - ${OUTPUT_SUB_PATH}/${CONTENT_FLAVOUR}
#   CONTENT_MANIFESTS_DIR     - ${CONTENT_BASE}/manifests/<bundle>/
#   CONTENT_DEFAULTS_DIR      - ${CONTENT_BASE}/defaults/<bundle>/
#   CONTENT_CONTRACTS_DIR     - ${CONTENT_BASE}/contracts/<bundle>/contract.yaml
#   CONTENT_EXTRACT_DIR       - ${CONTENT_BASE}/extract/<slug>/ (OCI audit trail)
#   CONTENT_UNZIPPED_DIR      - ${CONTENT_BASE}/unzipped/<slug>/ (zip audit trail)
#   CONTENT_LIST_FILE         - ${CONTENT_BASE}/contents.yaml | templates.yaml
#                               (verbatim entries, one '- <entry>' per line)
#   CONTENT_RESOLVED_FILE     - ${CONTENT_BASE}/contents-resolved.yaml |
#                               templates-resolved.yaml (resolved OCI URIs)
#
# Policy-free: the library only stages whatever is in the spec field into
# per-bundle subdirectories. Conflict detection across defaults, scheme
# conversion decisions, and merging are caller concerns (see lib/bundle-import).
#
# Output variables (set by helpers, read by caller / orchestrator):
#   CONTENT_MANIFESTS_ZIP   - absolute path to located manifests zip
#   CONTENT_CONTRACT_ZIP    - absolute path to located contract zip
#   CONTENT_PROJECT_NAME    - project name discovered from the manifests zip
#
# Required env (for content_resolve_all):
#   IMAGE_BUILD_COMMAND - docker or podman (used by extract-oci-image)
#
# Required tools: yq, unzip

# shellcheck disable=SC2034 # Some helpers set output vars consumed by callers.

if [[ -z "${OUTPUT_SUB_PATH:-}" ]]; then
  log_error "OUTPUT_SUB_PATH is not set. Source defaults/output-sub-path.bash before content-resolve.bash."
  # shellcheck disable=SC2317 # dual-mode: works whether sourced or executed
  return 1 2>/dev/null || exit 1
fi

case "${CONTENT_FLAVOUR:-}" in
  contents)
    CONTENT_RESOLVE_SPEC_EXPR='.spec.contents[]'
    ;;
  templates)
    CONTENT_RESOLVE_SPEC_EXPR='.spec.templates[]'
    ;;
  environment|run-platform)
    # env/RP builds aggregate spec.contents like a product does, but stage
    # under their own flavour-named tree.
    CONTENT_RESOLVE_SPEC_EXPR='.spec.contents[]'
    ;;
  "")
    log_error "CONTENT_FLAVOUR must be set before sourcing content-resolve.bash (expected 'contents', 'templates', 'environment', or 'run-platform')."
    # shellcheck disable=SC2317 # dual-mode: works whether sourced or executed
    return 1 2>/dev/null || exit 1
    ;;
  *)
    log_error "CONTENT_FLAVOUR='${CONTENT_FLAVOUR}' invalid (expected 'contents', 'templates', 'environment', or 'run-platform')."
    # shellcheck disable=SC2317 # dual-mode: works whether sourced or executed
    return 1 2>/dev/null || exit 1
    ;;
esac

CONTENT_BASE="${OUTPUT_SUB_PATH}/${CONTENT_FLAVOUR}"
CONTENT_MANIFESTS_DIR="${CONTENT_BASE}/manifests"
CONTENT_DEFAULTS_DIR="${CONTENT_BASE}/defaults"
CONTENT_CONTRACTS_DIR="${CONTENT_BASE}/contracts"
CONTENT_EXTRACT_DIR="${CONTENT_BASE}/extract"
CONTENT_UNZIPPED_DIR="${CONTENT_BASE}/unzipped"
CONTENT_LIST_FILE="${CONTENT_BASE}/${CONTENT_FLAVOUR}.yaml"
CONTENT_RESOLVED_FILE="${CONTENT_BASE}/${CONTENT_FLAVOUR}-resolved.yaml"
export CONTENT_BASE CONTENT_MANIFESTS_DIR CONTENT_DEFAULTS_DIR \
       CONTENT_CONTRACTS_DIR CONTENT_EXTRACT_DIR CONTENT_UNZIPPED_DIR \
       CONTENT_LIST_FILE CONTENT_RESOLVED_FILE

log "content-resolve: flavour=${CONTENT_FLAVOUR}"
log "content-resolve: base=${CONTENT_BASE}"

# Sub-lib dependency: dedup check runs inside content_resolve_all.
# shellcheck source=src/scripts/lib/assert-unique-artifact-refs.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assert-unique-artifact-refs.bash"
# shellcheck source=src/scripts/lib/builtin-tokens-from-entry.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/builtin-tokens-from-entry.bash"
# shellcheck source=src/scripts/defaults/schema-validation.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../defaults" && pwd)/schema-validation.bash"

CONTENT_RESOLVE_UTIL_DIR="${CONTENT_RESOLVE_UTIL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../util" && pwd)}"
CONTENT_RESOLVE_PLUGINS_DIR="${CONTENT_RESOLVE_PLUGINS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins" && pwd)}"
CONTENT_RESOLVE_SCHEMAS_DIR="${CONTENT_RESOLVE_SCHEMAS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../schemas" && pwd)}"

# Reduce a resolved OCI URI to a filesystem-safe slug. Replaces '/' and ':'
# with '_'. The slug names per-artifact subdirs under <out-extract-dir> and
# <out-unzipped-dir> so the audit trail is keyed on the artifact identity.
content_artifact_slug() {
  local uri="$1"
  echo "${uri}" | tr '/:' '__'
}

# Locate the manifests and contract zips inside an extracted OCI image tree.
# Sets CONTENT_MANIFESTS_ZIP and CONTENT_CONTRACT_ZIP to absolute paths.
# Returns 1 with diagnostic if either is missing or duplicated.
#
# Usage: content_find_zips <extract-dir>
content_find_zips() {
  if [[ $# -ne 1 ]]; then
    log_error "content_find_zips requires exactly 1 argument, got $#"
    return 1
  fi
  local extract_dir="$1"
  if [[ ! -d "${extract_dir}" ]]; then
    log_error "Extract dir not found: ${extract_dir}"
    return 1
  fi

  local manifests_zips=()
  local contract_zips=()
  local on_behalf_zips=()
  while IFS= read -r -d '' zip; do
    case "${zip}" in
      *-manifests.zip)                manifests_zips+=("${zip}") ;;
      *-contract.zip)                 contract_zips+=("${zip}") ;;
      *-cluster-scoped-resources.zip) on_behalf_zips+=("${zip}") ;;
    esac
  done < <(find "${extract_dir}" -type f -name '*.zip' -print0)

  if [[ ${#manifests_zips[@]} -ne 1 ]]; then
    log_error "Expected exactly one *-manifests.zip in ${extract_dir}, found ${#manifests_zips[@]}"
    return 1
  fi
  if [[ ${#contract_zips[@]} -ne 1 ]]; then
    log_error "Expected exactly one *-contract.zip in ${extract_dir}, found ${#contract_zips[@]}"
    return 1
  fi

  # Optional: only env children that delegate cluster-scoped resources
  # upwards carry one, so zero is the normal case. More than one means two
  # projects published into the same artifact, which is a packaging bug.
  if [[ ${#on_behalf_zips[@]} -gt 1 ]]; then
    log_error "Expected at most one *-cluster-scoped-resources.zip in ${extract_dir}, found ${#on_behalf_zips[@]}"
    return 1
  fi

  CONTENT_MANIFESTS_ZIP="${manifests_zips[0]}"
  CONTENT_CONTRACT_ZIP="${contract_zips[0]}"
  CONTENT_ON_BEHALF_ZIP="${on_behalf_zips[0]:-}"
}

# Unzip a child's delegated cluster-scoped zip into the run-platform's
# collection dir, from which kubernetes-run-package stages it into the RP
# deploy image at /kd/cluster-scoped-on-behalf. The zip has a single
# <project>/ root (the manifests-zip convention), and that dir name IS the
# per-child partition the deploy side applies from.
#
# Usage: content_collect_on_behalf <on-behalf-zip> <unzipped-dir> <project>
content_collect_on_behalf() {
  if [[ $# -ne 3 ]]; then
    log_error "content_collect_on_behalf requires exactly 3 arguments, got $#"
    return 1
  fi
  local zip="$1"
  local unzipped_dir="$2"
  local project="$3"

  local dest="${OUTPUT_SUB_PATH}/run-platform/cluster-scoped-on-behalf"
  if [[ -e "${dest}/${project}" ]]; then
    log_error "Delegated cluster-scoped set for ${project} already collected in ${dest}"
    return 1
  fi

  mkdir -p "${unzipped_dir}" "${dest}"
  unzip -q "${zip}" -d "${unzipped_dir}"
  if [[ ! -d "${unzipped_dir}/${project}" ]]; then
    log_error "Delegated cluster-scoped zip has no ${project}/ root: ${zip}"
    return 1
  fi
  cp -R "${unzipped_dir}/${project}" "${dest}/${project}"

  local count
  count=$(find "${dest}/${project}" -type f -name '*.yaml' | grep -c . || true)
  log "  Collected ${count} delegated cluster-scoped manifest(s) from ${project}"
}

# Unzip a manifests zip into <unzipped-dir> (audit trail) and cp the
# project subdir into <out-manifests-dir>. The zip contains a single
# top-level <project>/ directory which becomes a sibling of any
# previously staged bundle. Sets CONTENT_PROJECT_NAME.
#
# Usage: content_unzip_manifests <manifests-zip> <unzipped-dir> <out-manifests-dir>
content_unzip_manifests() {
  if [[ $# -ne 3 ]]; then
    log_error "content_unzip_manifests requires exactly 3 arguments, got $#"
    return 1
  fi
  local zip="$1"
  local unzipped_dir="$2"
  local out_dir="$3"
  if [[ ! -f "${zip}" ]]; then
    log_error "Manifests zip not found: ${zip}"
    return 1
  fi

  local project
  project=$(unzip -Z1 "${zip}" 2>/dev/null | head -1 | cut -d/ -f1)
  if [[ -z "${project}" ]]; then
    log_error "Could not determine project name from ${zip}"
    return 1
  fi

  mkdir -p "${out_dir}"
  if [[ -e "${out_dir}/${project}" ]]; then
    log_error "Project ${project} already staged in ${out_dir}"
    return 1
  fi

  mkdir -p "${unzipped_dir}"
  unzip -q "${zip}" -d "${unzipped_dir}"

  cp -R "${unzipped_dir}/${project}" "${out_dir}/${project}"
  CONTENT_PROJECT_NAME="${project}"
}

# Unzip a contract zip into <unzipped-dir> (audit trail) and cp its pieces
# into the per-project layout:
#   contract.yaml -> <out-contracts-dir>/<project>/contract.yaml
#   defaults/*    -> <out-defaults-dir>/<project>/*
#
# <unzipped-dir> may already contain unzipped manifests-zip output (the
# orchestrator unzips both into the same audit dir); the contract zip's
# top-level entries (contract.yaml and optional defaults/) do not collide
# with the manifests zip's <project>/ subdir.
#
# Usage: content_unzip_contract <contract-zip> <unzipped-dir> <out-contracts-dir> <out-defaults-dir> <project>
content_unzip_contract() {
  if [[ $# -ne 5 ]]; then
    log_error "content_unzip_contract requires exactly 5 arguments, got $#"
    return 1
  fi
  local zip="$1"
  local unzipped_dir="$2"
  local out_contracts_dir="$3"
  local out_defaults_dir="$4"
  local project="$5"
  if [[ ! -f "${zip}" ]]; then
    log_error "Contract zip not found: ${zip}"
    return 1
  fi
  if [[ -z "${project}" ]]; then
    log_error "project name is required"
    return 1
  fi

  mkdir -p "${unzipped_dir}"
  unzip -q "${zip}" -d "${unzipped_dir}"

  if [[ ! -f "${unzipped_dir}/contract.yaml" ]]; then
    log_error "contract.yaml not found inside ${zip}"
    return 1
  fi

  mkdir -p "${out_contracts_dir}/${project}"
  cp "${unzipped_dir}/contract.yaml" "${out_contracts_dir}/${project}/contract.yaml"

  if [[ -d "${unzipped_dir}/defaults" ]]; then
    mkdir -p "${out_defaults_dir}/${project}"
    local src rel dest
    while IFS= read -r -d '' src; do
      rel="${src#"${unzipped_dir}/defaults/"}"
      dest="${out_defaults_dir}/${project}/${rel}"
      mkdir -p "$(dirname "${dest}")"
      cp "${src}" "${dest}"
    done < <(find "${unzipped_dir}/defaults" -type f -print0)
  fi
}

# Validate a staged bundle against its declared contract: contract conforms to
# its schema; defaults filenames match the contract's declared name style;
# every defaults file maps to a required token; every unresolved token in the
# manifests is declared as required by the contract. Catches malformed or
# foreign bundles before the product/environment build operates on their
# innards.
#
# Usage: content_validate_bundle <project> <out-contracts-dir> <out-defaults-dir> <out-manifests-dir>
content_validate_bundle() {
  if [[ $# -ne 4 ]]; then
    log_error "content_validate_bundle requires exactly 4 arguments, got $#"
    return 1
  fi
  local project="$1"
  local out_contracts_dir="$2"
  local out_defaults_dir="$3"
  local out_manifests_dir="$4"

  local contract_file="${out_contracts_dir}/${project}/contract.yaml"
  local defaults_dir="${out_defaults_dir}/${project}"
  local manifests_dir="${out_manifests_dir}/${project}"

  if [[ ! -f "${contract_file}" ]]; then
    log_error "Bundle ${project}: contract.yaml not found at ${contract_file}"
    return 1
  fi
  if [[ ! -d "${manifests_dir}" ]]; then
    log_error "Bundle ${project}: manifests directory not found at ${manifests_dir}"
    return 1
  fi

  # Validate against the contract schema this build of kaptain ships, mirroring
  # how KaptainPM.yaml is validated. The version file is the single source of
  # truth; older bundles whose payload still satisfies the current schema keep
  # working, ones that don't fail with a clear validation error.
  local schema_dir schema_version schema_file
  schema_dir="${CONTENT_RESOLVE_SCHEMAS_DIR}/manifests-contract"
  schema_version=$(cat "${schema_dir}/version")
  schema_file="${schema_dir}/spec-manifests-contract-schema-${schema_version}.json"
  if [[ ! -f "${schema_file}" ]]; then
    log_error "Bundle ${project}: schema not found: ${schema_file}"
    return 1
  fi
  if ! "${SCHEMA_VALIDATION_COMMAND}" "${schema_file}" "${contract_file}"; then
    log_error "Bundle ${project}: contract.yaml does not validate against schema ${schema_version}"
    return 1
  fi

  local bundle_name_style bundle_delim_style
  bundle_name_style=$(yq -r '.tokens.nameStyle // ""' "${contract_file}")
  bundle_delim_style=$(yq -r '.tokens.delimiterStyle // ""' "${contract_file}")
  if [[ -z "${bundle_name_style}" || -z "${bundle_delim_style}" ]]; then
    log_error "Bundle ${project}: contract.yaml is missing tokens.nameStyle or tokens.delimiterStyle"
    return 1
  fi

  local has_defaults="false"
  if [[ -d "${defaults_dir}" ]] \
     && [[ -n "$(find "${defaults_dir}" -type f 2>/dev/null)" ]]; then
    has_defaults="true"
  fi

  # Defaults filenames must pass the contract's declared name style validator.
  # Catches producers that lied about their style or hand-edited the bundle.
  if [[ "${has_defaults}" == "true" ]]; then
    local validator_script="${CONTENT_RESOLVE_PLUGINS_DIR}/token-name-validators/${bundle_name_style}"
    if [[ ! -x "${validator_script}" ]]; then
      log_error "Bundle ${project}: token-name validator not found for style ${bundle_name_style}"
      return 1
    fi
    if ! "${validator_script}" "${defaults_dir}"; then
      log_error "Bundle ${project}: one or more defaults filenames do not match the contract's declared name style ${bundle_name_style}"
      return 1
    fi
  fi

  local required_tokens
  required_tokens=$(yq -r '.config.required // [] | .[]' "${contract_file}")

  # Every defaults file's relative path must appear in .config.required.
  if [[ "${has_defaults}" == "true" ]]; then
    local orphans=()
    local default_file rel
    while IFS= read -r -d '' default_file; do
      rel="${default_file#"${defaults_dir}/"}"
      if [[ -z "${required_tokens}" ]] || ! grep -qxF "${rel}" <<< "${required_tokens}"; then
        orphans+=("${rel}")
      fi
    done < <(find "${defaults_dir}" -type f -print0)
    if [[ ${#orphans[@]} -gt 0 ]]; then
      log_error "Bundle ${project}: defaults file(s) not declared in contract .config.required:"
      for rel in "${orphans[@]}"; do
        log_error "  ${rel}"
      done
      return 1
    fi
  fi

  # Every unresolved token actually present in the manifests must appear in
  # .config.required. Producer claims to enumerate everything; verify by scan.
  #
  # Except the deploy-time context family. Kaptain itself writes
  # ${Environment}, ${ProductName} and their siblings into every bundle's
  # metadata labels and lineage data, and they are resolved by the product or
  # environment build that finally deploys the bundle (kubernetes-product-
  # aggregate and kubernetes-run-substitute emit them as builtins). No producer
  # can declare them in a contract, because no producer has values for them;
  # requiring it rejected every Kaptain-built bundle imported as a template.
  # Exactly this family is exempt, in the bundle's own naming style; any other
  # undeclared token still fails.
  local deploy_time_tokens="" deploy_time_name
  for deploy_time_name in ENVIRONMENT ENVIRONMENT_NAME ENVIRONMENT_SHORT_NAME ENVIRONMENT_TYPE \
    PRODUCT_NAME PRODUCT_SHORT_NAME; do
    deploy_time_tokens+="$(convert_token_name "${bundle_name_style}" "${deploy_time_name}")"$'\n'
  done
  local unresolved_tokens
  unresolved_tokens=$("${CONTENT_RESOLVE_UTIL_DIR}/scan-unresolved-tokens" \
    "${bundle_delim_style}" "${bundle_name_style}" "${manifests_dir}")
  if [[ -n "${unresolved_tokens}" ]]; then
    local missing=()
    local token
    while IFS= read -r token; do
      [[ -z "${token}" ]] && continue
      grep -qxF "${token}" <<< "${deploy_time_tokens}" && continue
      if [[ -z "${required_tokens}" ]] || ! grep -qxF "${token}" <<< "${required_tokens}"; then
        missing+=("${token}")
      fi
    done <<< "${unresolved_tokens}"
    if [[ ${#missing[@]} -gt 0 ]]; then
      log_error "Bundle ${project}: unresolved token(s) present in manifests but not declared in contract .config.required:"
      for token in "${missing[@]}"; do
        log_error "  ${token}"
      done
      return 1
    fi
  fi
}

# Resolve every entry in the flavour's spec field (.spec.contents[] for
# content, .spec.templates[] for templates) of <kaptainpm-file>, fetch the
# corresponding -manifests OCI image, and stage the unzipped manifests,
# contract, and defaults into the env-set CONTENT_* dirs (set at source time
# based on CONTENT_FLAVOUR).
#
# Owns the lifecycle of CONTENT_BASE: rm -rf and recreate the full per-flavour
# tree, so calling this is destructive to anything previously staged for the
# same flavour. Two flavours stage under separate bases and do not interfere.
#
# OCI image extraction lands in ${CONTENT_EXTRACT_DIR}/<artifact-slug>/ and
# both zips are unzipped into ${CONTENT_UNZIPPED_DIR}/<artifact-slug>/. Both
# are kept after the run as the audit trail.
#
# Writes two summary files at ${CONTENT_BASE}:
#   ${CONTENT_LIST_FILE}      - verbatim spec entries, one '- <entry>' per line
#                               (valid YAML sequence and valid markdown bullets)
#   ${CONTENT_RESOLVED_FILE}  - resolved OCI URIs, one '- <uri>' per line
# Both files are truncated and rewritten on every call. Empty spec field
# produces empty files (consumers can rely on the files always existing).
#
# Usage: content_resolve_all <kaptainpm-file>
content_resolve_all() {
  if [[ $# -ne 1 ]]; then
    log_error "Usage: content_resolve_all <kaptainpm-file>"
    return 1
  fi
  local kaptainpm_file="$1"

  if [[ ! -f "${kaptainpm_file}" ]]; then
    log_error "KaptainPM file not found: ${kaptainpm_file}"
    return 1
  fi

  if ! command -v yq >/dev/null 2>&1; then
    log_error "yq is required for content_resolve_all"
    return 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    log_error "unzip is required for content_resolve_all"
    return 1
  fi

  # Reject duplicate refs at the spec level before any fetch/extract work.
  # 'name' mode collapses on the bare last-path segment because two refs that
  # resolve to the same bundle/project metadata.name collide at staging
  # regardless of where they were pulled from.
  assert_unique_artifact_refs "${kaptainpm_file}" \
    "${CONTENT_RESOLVE_SPEC_EXPR}" \
    "spec.${CONTENT_FLAVOUR}" name

  rm -rf "${CONTENT_BASE}"
  mkdir -p "${CONTENT_MANIFESTS_DIR}" "${CONTENT_DEFAULTS_DIR}" "${CONTENT_CONTRACTS_DIR}" \
           "${CONTENT_EXTRACT_DIR}" "${CONTENT_UNZIPPED_DIR}"

  : > "${CONTENT_LIST_FILE}"
  : > "${CONTENT_RESOLVED_FILE}"

  local entries
  entries=$(yq eval "${CONTENT_RESOLVE_SPEC_EXPR}" "${kaptainpm_file}" 2>/dev/null || true)
  if [[ -z "${entries}" || "${entries}" == "null" ]]; then
    log "No ${CONTENT_FLAVOUR} entries to resolve"
    return 0
  fi

  local summary_entry
  while IFS= read -r summary_entry; do
    [[ -z "${summary_entry}" ]] && continue
    printf -- '- %s\n' "${summary_entry}" >> "${CONTENT_LIST_FILE}"
  done <<< "${entries}"

  local total
  total=$(echo "${entries}" | grep -c .)
  log "${CONTENT_FLAVOUR} lists ${total} entr$([[ ${total} -eq 1 ]] && echo y || echo ies):"
  while IFS= read -r summary_entry; do
    [[ -z "${summary_entry}" ]] && continue
    log "  ${summary_entry}"
  done <<< "${entries}"
  log ""

  local entry_index=0
  local entry
  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    entry_index=$((entry_index + 1))
    log "Resolving ${CONTENT_FLAVOUR} entry ${entry_index}: ${entry}"

    # Resolve to the concrete OCI URI. Land the resolved-uri file at a
    # known per-entry path, then move it into the slug-named extract dir
    # once we know the slug. Keeping it makes the audit trail show what
    # the entry actually resolved to at the moment of the build.
    local resolve_seed="${CONTENT_EXTRACT_DIR}/resolved-entry-${entry_index}.uri"
    "${CONTENT_RESOLVE_UTIL_DIR}/artifact-resolve" "${entry}" "${resolve_seed}" manifests || return $?
    local resolved_uri
    resolved_uri=$(cat "${resolve_seed}")
    log "  Resolved: ${resolved_uri}"

    printf -- '- %s\n' "${resolved_uri}" >> "${CONTENT_RESOLVED_FILE}"

    # Auto-builtin tokens. The resolved URI's tag names the manifests OCI
    # (we asked artifact-resolve for the 'manifests' variant above); the
    # release version is that tag with the variant suffix we requested
    # stripped, so VERSION stays spec-shaped and comparable while
    # MANIFESTS_DOCKER_TAG records the artifact tag verbatim.
    local resolved_tag="${resolved_uri##*:}"
    local resolved_version="${resolved_tag%-manifests}"
    log "  Auto-builtin tokens for ${CONTENT_FLAVOUR}:"
    emit_builtin_tokens_for_entry "${entry}" "${resolved_version}" "${CONTENT_FLAVOUR}" "${resolved_tag}"

    local slug
    slug=$(content_artifact_slug "${resolved_uri}")
    local extract_dir="${CONTENT_EXTRACT_DIR}/${slug}"
    local unzipped_dir="${CONTENT_UNZIPPED_DIR}/${slug}"
    mkdir -p "${extract_dir}" "${unzipped_dir}"
    mv "${resolve_seed}" "${extract_dir}/resolved-uri"

    "${CONTENT_RESOLVE_UTIL_DIR}/extract-oci-image" "${resolved_uri}" "${extract_dir}" || return $?

    content_find_zips "${extract_dir}" || return $?
    content_unzip_manifests "${CONTENT_MANIFESTS_ZIP}" "${unzipped_dir}" "${CONTENT_MANIFESTS_DIR}" || return $?
    local project="${CONTENT_PROJECT_NAME}"
    content_unzip_contract "${CONTENT_CONTRACT_ZIP}" "${unzipped_dir}" \
      "${CONTENT_CONTRACTS_DIR}" "${CONTENT_DEFAULTS_DIR}" "${project}" || return $?

    content_validate_bundle "${project}" "${CONTENT_CONTRACTS_DIR}" "${CONTENT_DEFAULTS_DIR}" "${CONTENT_MANIFESTS_DIR}" || return $?

    # Presence-driven, no flag: a child that delegated its cluster-scoped
    # resources ships the zip, and only an RP has the cluster credentials
    # to apply what it collects.
    if [[ -n "${CONTENT_ON_BEHALF_ZIP}" && "${CONTENT_FLAVOUR}" == "run-platform" ]]; then
      content_collect_on_behalf "${CONTENT_ON_BEHALF_ZIP}" "${unzipped_dir}" "${project}" || return $?
    fi

    log "  Staged ${project}"
    log ""
  done <<< "${entries}"

  log "Resolved ${entry_index} ${CONTENT_FLAVOUR} entr$([[ ${entry_index} -eq 1 ]] && echo y || echo ies)"
}
