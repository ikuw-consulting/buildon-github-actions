#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# env-content-scan.bash - Walk a substituted env workload tree and emit
# content-data.yaml per EnvContentData.md.
#
# Reads the kaptain.org/* provenance annotations injected onto every
# resource at package-prepare time, groups by kaptain.org/project-name,
# and emits a YAML document of:
#
#   apiVersion: kaptain.org/content-data/1
#   kind: environment | run-platform
#   name: <env or RP name>
#   version: <env or RP version>
#   children:
#     - kind: app|bundle|product
#       name: <project-name>
#       version: <kaptain.org/version>
#       versionSpec: <kaptain.org/version-spec>
#       origin:
#         url: <kaptain.org/origin-url>
#         revision: <kaptain.org/origin-revision>
#         registry: <kaptain.org/origin-registry>
#       workloads:
#         - name: <metadata.name>            (post-substitution + checksum)
#           kind: <Deployment|Job|...>
#           namespace: <metadata.namespace || "">
#           sourcePath: <path-rel-to-tree>
#
# Run AFTER the resource-checksum pass so the workload names are the
# final, suffixed ones that will deploy.
#
# Function:
#   env_content_scan_tree <tree> <doc-kind> <name> <version> <out-file>
#       <doc-kind> is the content-data top-level kind: "environment"
#       for env builds, "run-platform" for run-platform builds.
#
# Required tools: yq 4, find.

# Workload kinds that populate children[].workloads. Per EnvContentData.md
# §3 "Workload kind allowlist". Extend here when new workload CRDs are
# adopted (Rollout, etc.).
ENV_CONTENT_SCAN_WORKLOAD_KINDS_REGEX='^(Deployment|StatefulSet|DaemonSet|ReplicaSet|Job|CronJob|Pod)$'

# Classify a child project by its name. Heuristic-only; refine with an
# explicit kaptain.org/build-kind annotation when one becomes reliable
# across all build flows.
env_content_scan_classify_child() {
  local name="$1"
  case "${name}" in
    product-*|*-product) echo "product" ;;
    vendor-*|bundle-*)   echo "bundle" ;;
    *)                   echo "app" ;;
  esac
}

# Read a kaptain.org/<key> annotation from a manifest doc. Echoes empty
# string when missing or null.
env_content_scan_anno() {
  local file="$1" doc_index="$2" key="$3"
  local val
  val=$(yq "select(di == ${doc_index}) | .metadata.annotations.\"kaptain.org/${key}\" // \"\"" "${file}" 2>/dev/null)
  [[ "${val}" == "null" ]] && val=""
  echo "${val}"
}

# Append a YAML-escaped scalar field, omitting the line entirely when
# value is empty. Indented by <indent> spaces.
env_content_scan_emit_field() {
  local out="$1" indent="$2" key="$3" value="$4"
  [[ -z "${value}" ]] && return 0
  printf '%*s%s: %s\n' "${indent}" '' "${key}" "${value}" >> "${out}"
}

# Walk <tree>, build a per-project index of provenance + workloads, emit
# content-data.yaml.
#
# Usage: env_content_scan_tree <tree> <env-name> <env-version> <out-file>
env_content_scan_tree() {
  local tree="$1"
  local doc_kind="$2"
  local name="$3"
  local version="$4"
  local out_file="$5"

  if [[ -z "${tree}" || -z "${doc_kind}" || -z "${name}" || -z "${version}" || -z "${out_file}" ]]; then
    log_error "env_content_scan_tree: usage: <tree> <doc-kind> <name> <version> <out-file>"
    return 1
  fi
  if [[ ! -d "${tree}" ]]; then
    log_error "env_content_scan_tree: tree dir not found: ${tree}"
    return 1
  fi

  # Per-project provenance index. Lines (tab-separated):
  #   project-name \t version \t versionSpec \t url \t revision \t registry
  # First wins (provenance should be consistent across a project's
  # manifests; mismatch warns).
  local provenance_file
  provenance_file=$(mktemp)
  # Workload entries. Lines (tab-separated):
  #   project-name \t kind \t name \t namespace \t sourcePath
  local workloads_file
  workloads_file=$(mktemp)

  local file rel kinds i k project version version_spec url revision registry name namespace
  while IFS= read -r -d '' file; do
    rel="${file#"${tree}/"}"
    kinds=$(yq ea '.kind // "null"' "${file}" 2>/dev/null) || continue
    [[ -z "${kinds}" ]] && continue

    i=0
    while IFS= read -r k; do
      project=$(env_content_scan_anno "${file}" "${i}" "project-name")
      if [[ -n "${project}" ]]; then
        # Record provenance from the first doc we see for this project.
        if ! grep -q "^${project}	" "${provenance_file}" 2>/dev/null; then
          version=$(env_content_scan_anno      "${file}" "${i}" "version")
          version_spec=$(env_content_scan_anno "${file}" "${i}" "version-spec")
          url=$(env_content_scan_anno          "${file}" "${i}" "origin-url")
          revision=$(env_content_scan_anno     "${file}" "${i}" "origin-revision")
          registry=$(env_content_scan_anno     "${file}" "${i}" "origin-registry")
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${project}" "${version}" "${version_spec}" \
            "${url}" "${revision}" "${registry}" >> "${provenance_file}"
        fi

        if [[ "${k}" =~ ${ENV_CONTENT_SCAN_WORKLOAD_KINDS_REGEX} ]]; then
          name=$(yq      "select(di == ${i}) | .metadata.name // \"\""      "${file}")
          namespace=$(yq "select(di == ${i}) | .metadata.namespace // \"\"" "${file}")
          [[ "${namespace}" == "null" ]] && namespace=""
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "${project}" "${k}" "${name}" "${namespace}" "${rel}" >> "${workloads_file}"
        fi
      fi
      i=$((i + 1))
    done <<< "${kinds}"
  done < <(find "${tree}" -type f -name '*.yaml' -print0)

  # Emit the document. Deterministic ordering: projects alphabetical,
  # workloads within a project by (kind, name, sourcePath).
  : > "${out_file}"
  {
    printf 'apiVersion: kaptain.org/content-data/1\n'
    printf 'kind: %s\n' "${doc_kind}"
    printf 'name: %s\n' "${name}"
    printf 'version: %s\n' "${version}"
    printf 'children:\n'
  } >> "${out_file}"

  if [[ ! -s "${provenance_file}" ]]; then
    printf '  []\n' >> "${out_file}"
    rm -f "${provenance_file}" "${workloads_file}"
    return 0
  fi

  local child_kind
  while IFS=$'\t' read -r project version version_spec url revision registry; do
    [[ -z "${project}" ]] && continue
    child_kind=$(env_content_scan_classify_child "${project}")
    {
      printf '  - kind: %s\n' "${child_kind}"
      printf '    name: %s\n' "${project}"
    } >> "${out_file}"
    env_content_scan_emit_field "${out_file}" 4 "version" "${version}"
    env_content_scan_emit_field "${out_file}" 4 "versionSpec" "${version_spec}"
    if [[ -n "${url}" || -n "${revision}" || -n "${registry}" ]]; then
      printf '    origin:\n' >> "${out_file}"
      env_content_scan_emit_field "${out_file}" 6 "url"      "${url}"
      env_content_scan_emit_field "${out_file}" 6 "revision" "${revision}"
      env_content_scan_emit_field "${out_file}" 6 "registry" "${registry}"
    fi
    printf '    workloads:\n' >> "${out_file}"
    local project_workloads
    project_workloads=$(awk -F '\t' -v p="${project}" '$1 == p' "${workloads_file}" \
                          | LC_ALL=C sort -t $'\t' -k 2,2 -k 3,3 -k 5,5)
    if [[ -z "${project_workloads}" ]]; then
      printf '      []\n' >> "${out_file}"
    else
      local w_project w_kind w_name w_ns w_path
      while IFS=$'\t' read -r w_project w_kind w_name w_ns w_path; do
        [[ -z "${w_project}" ]] && continue
        {
          printf '      - name: %s\n' "${w_name}"
          printf '        kind: %s\n' "${w_kind}"
        } >> "${out_file}"
        env_content_scan_emit_field "${out_file}" 8 "namespace"  "${w_ns}"
        env_content_scan_emit_field "${out_file}" 8 "sourcePath" "${w_path}"
      done <<< "${project_workloads}"
    fi
  done < <(LC_ALL=C sort "${provenance_file}")

  rm -f "${provenance_file}" "${workloads_file}"
}
