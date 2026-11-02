#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# assert-resource-envelopes.bash - Reject an application bundle whose
# containers carry no CPU and memory requests and limits.
#
# A cluster has a finite amount of CPU and memory, and a container with no
# memory limit does not degrade itself - it takes memory the kubelet then
# reclaims from a neighbour. On a small cluster that neighbour belongs to
# someone else's product. So the budget is not advice: a container without one
# is not deployable, and the earliest place the whole deployable set is visible
# at once is the product aggregate.
#
# WHY HERE AND NOT AT THE COMPONENT BUILD
#
# A component build sees only its own manifests, and a component may legitimately
# be built and published without ever being deployed. The product is the first
# level that says "these containers run together", so it is the level that can
# be held to "every container that runs carries a budget". It is also the level
# a consumer pins, which makes the failure land on the person composing the
# product rather than on whoever happens to touch a component next.
#
# WHY THE STAGED MANIFESTS AND NOT THE KaptainPM.yaml
#
# Reading spec.main.workload.container.resources out of each component's
# manifest would check only components that let the workload generator write
# their Deployment. Every component that sets `workload: { type: none }` and
# hand-writes its manifests - which is most of the ones that need checking -
# would pass while shipping no budget at all. The staged manifest tree is what
# actually reaches a cluster, so it is what gets checked, whichever route it
# came by.
#
# UNRESOLVED TOKENS ARE FINE, AND DELIBERATELY SO
#
# This runs before substitution, so a value may still be `${ApiMemoryLimit}`.
# That passes: the component declared a budget and named the knob, which is
# exactly the intent. The check is presence, never magnitude - the magnitudes
# are the envelope table's business, and they are an environment's to set.
#
# Two consequences of checking pre-substitution YAML, both deliberate:
#   - A token that stands in for a whole requests or resources block
#     (`resources: {{Resources}}`) reads as a map with no cpu or memory key
#     and so fails. A bundle that hides its budget behind one token cannot be
#     audited here, and "cannot be audited" is reported rather than assumed
#     compliant.
#   - A token delimiter style that makes the manifest unparseable as YAML
#     (ognl's `%{Name}`) fails with that said plainly, rather than being
#     skipped. A manifest nothing can parse is not one anybody can review.
#
# SCOPE
#
# Application bundles only - a contract kind under
# RESOURCE_ENVELOPE_APPLICATION_KIND_PREFIX. Vendor and resource bundles are
# third-party manifests the consuming project did not write and often cannot
# change without a repackage, so failing a product for them would make the
# check unlandable. That is a stated gap, not an oversight: a vendor bundle's
# budget is set where it is adopted.
#
# Required tools: yq, find
#
# Required functions in scope: log, log_error (from log.bash)

# The contract kind prefix that marks a bundle as an application. The contract's
# kind mirrors the BUILD_KIND of the pipeline that published it, so this matches
# kubernetes-app-docker-dockerfile, kubernetes-app-manifests-only and every
# other app kind without naming them one by one.
RESOURCE_ENVELOPE_APPLICATION_KIND_PREFIX="kubernetes-app-"

# The four fields a container must declare. Named here so the yq program below
# and the message a build author reads cannot drift apart.
RESOURCE_ENVELOPE_REQUIRED_FIELDS=(requests.cpu requests.memory limits.cpu limits.memory)

# One yq program for every workload kind. Each arm selects the documents of one
# shape and descends to its pod spec; the union is then walked once.
#
# Selecting on the document's own kind first is what keeps a ConfigMap holding
# the word "containers" in its data out of this, and a PersistentVolumeClaim's
# `resources.requests.storage` - which is a claim's size, not a container's
# budget - out with it.
#
# The output is one line per container: name, then one boolean per required
# field, tab separated. Presence is tested with `!= null and != ""` rather than
# `has()` so that a key present with no value, and a key present as an empty
# string, both read as the absence they are. Emitting booleans rather than the
# values keeps @tsv safe when a token has parsed as a map.
RESOURCE_ENVELOPE_YQ_PROGRAM='
(
  (select(.kind == "Pod") | .spec),
  (select(.kind == "Deployment" or .kind == "ReplicaSet" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job") | .spec.template.spec),
  (select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec)
)
| (.initContainers[]?, .containers[]?)
| [ (.name // "" | tostring),
    (.resources.requests.cpu    != null and .resources.requests.cpu    != ""),
    (.resources.requests.memory != null and .resources.requests.memory != ""),
    (.resources.limits.cpu      != null and .resources.limits.cpu      != ""),
    (.resources.limits.memory   != null and .resources.limits.memory   != "") ]
| @tsv
'

# State the rule once, for the caller to log on its way out however many
# containers offended.
#
# Usage: resource_envelope_rules_explain
resource_envelope_rules_explain() {
  log_error "Every container in an application bundle must declare CPU and memory"
  log_error "requests and limits: ${RESOURCE_ENVELOPE_REQUIRED_FIELDS[*]}."
  log_error "Set them in the component's spec.main.workload.container.resources, or"
  log_error "write them into the container's resources block where the manifests are"
  log_error "hand-written. An unresolved token is an acceptable value - the component"
  log_error "has to name the budget, not fix the number."
}

# Walk every manifest in one tree and append an offender line per container
# short of a budget to the RESOURCE_ENVELOPE_OFFENDERS array in the caller's
# scope. Labels are the path relative to <dir>, behind <label-prefix>, so a
# message names the file the way whoever has to fix it knows it.
#
# Manifests only. A modifier file is <manifest>.yaml.<type>-<desc>, so it cannot
# match this glob; it changes a manifest rather than being one, and the tree it
# targets is not final until the environment applies it.
#
# Usage: resource_envelope_check_tree <dir> <label-prefix>
# Returns: 0 always; findings arrive via RESOURCE_ENVELOPE_OFFENDERS
resource_envelope_check_tree() {
  local dir="$1"
  local label_prefix="$2"

  local file
  while IFS= read -r file; do
    resource_envelope_check_manifest "${file}" "${label_prefix}${file#"${dir}"/}"
  done < <(find "${dir}" -mindepth 1 -name '.*' -prune -o -type f -name '*.yaml' -print)
}

# Log whatever RESOURCE_ENVELOPE_OFFENDERS holds under <header>, then the rule.
#
# The single place that turns findings into an exit status, so the two call
# sites - a product's bundles and a run's own manifests - cannot come to
# different verdicts on the same evidence, and a future enforce/report switch
# has one function to land in rather than two.
#
# Usage: resource_envelope_report <header>
# Returns: 0 when there are no offenders, 1 otherwise
resource_envelope_report() {
  local header="$1"

  if [[ ${#RESOURCE_ENVELOPE_OFFENDERS[@]} -eq 0 ]]; then
    return 0
  fi

  log_error "${header}"
  local offender
  for offender in "${RESOURCE_ENVELOPE_OFFENDERS[@]}"; do
    log_error "  ${offender}"
  done
  resource_envelope_rules_explain
  return 1
}

# Walk one manifest file and append an offender line per container short of a
# budget to the RESOURCE_ENVELOPE_OFFENDERS array in the caller's scope.
#
# Usage: resource_envelope_check_manifest <file> <label>
# Returns: 0 always; findings arrive via RESOURCE_ENVELOPE_OFFENDERS
resource_envelope_check_manifest() {
  local file="$1"
  local label="$2"

  local report
  if ! report=$(yq eval -r "${RESOURCE_ENVELOPE_YQ_PROGRAM}" "${file}" 2>&1); then
    RESOURCE_ENVELOPE_OFFENDERS+=("${label}: could not be read as YAML, so its containers' budgets cannot be checked")
    return 0
  fi

  local line name missing
  local requests_cpu requests_memory limits_cpu limits_memory
  while IFS= read -r line; do
    # yq prints a blank line for a document the program matched nothing in, and
    # a '---' between documents. Neither carries a tab, which every data line
    # does, so requiring one is the whole filter.
    [[ "${line}" != *$'\t'* ]] && continue
    IFS=$'\t' read -r name requests_cpu requests_memory limits_cpu limits_memory <<< "${line}"

    missing=""
    [[ "${requests_cpu}" == "true" ]]    || missing="${missing}${missing:+, }requests.cpu"
    [[ "${requests_memory}" == "true" ]] || missing="${missing}${missing:+, }requests.memory"
    [[ "${limits_cpu}" == "true" ]]      || missing="${missing}${missing:+, }limits.cpu"
    [[ "${limits_memory}" == "true" ]]   || missing="${missing}${missing:+, }limits.memory"
    [[ -z "${missing}" ]] && continue

    RESOURCE_ENVELOPE_OFFENDERS+=("${label}: container '${name:-<unnamed>}' is missing ${missing}")
  done <<< "${report}"
}

# assert_resource_envelopes <manifests-dir> <contracts-dir>
#
# <manifests-dir> is the per-bundle staged manifest tree
# (MANIFESTS_ADDITIONAL_SUB_PATH after bundle import); <contracts-dir> holds
# <bundle>/contract.yaml for each of them (CONTENT_CONTRACTS_DIR). The two are
# keyed by the same bundle name, which is how a staged tree is matched to the
# build kind that produced it.
#
# Returns 0 when every container in every application bundle declares all four
# fields, 1 otherwise with every offender logged. Every bundle and every
# manifest is walked before failing, so one build reports the whole backlog
# rather than one file at a time.
assert_resource_envelopes() {
  if [[ $# -ne 2 ]]; then
    log_error "assert_resource_envelopes requires exactly 2 arguments, got $#"
    return 1
  fi
  local manifests_dir="$1"
  local contracts_dir="$2"

  if [[ ! -d "${manifests_dir}" ]]; then
    log_error "assert_resource_envelopes: manifests directory not found: ${manifests_dir}"
    return 1
  fi

  RESOURCE_ENVELOPE_OFFENDERS=()
  local bundle_dir bundle contract kind
  for bundle_dir in "${manifests_dir}"/*; do
    [[ -d "${bundle_dir}" ]] || continue
    bundle=$(basename "${bundle_dir}")
    contract="${contracts_dir}/${bundle}/contract.yaml"

    # No contract is a failure rather than a skip. The contract is the only
    # thing that says what produced a bundle, so without it the check cannot
    # tell an application from a vendor package - and silently not checking is
    # the outcome this whole library exists to prevent.
    if [[ ! -f "${contract}" ]]; then
      RESOURCE_ENVELOPE_OFFENDERS+=("${bundle}: no contract at ${contract}, so the bundle's build kind is unknown")
      continue
    fi

    kind=$(yq -r '.kind // ""' "${contract}")
    if [[ "${kind}" != "${RESOURCE_ENVELOPE_APPLICATION_KIND_PREFIX}"* ]]; then
      log "Bundle ${bundle} is not an application (kind ${kind:-<absent>}); resource envelopes not checked."
      continue
    fi

    log "Bundle ${bundle}: checking resource envelopes (kind ${kind})"
    resource_envelope_check_tree "${bundle_dir}" "${bundle}/"
  done

  resource_envelope_report \
    "Containers in this product's application bundles carry no resource envelope:"
}
