#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for lib/assert-resource-envelopes.bash.
#
# Covers the application-kind filter read from each bundle's contract, every
# workload kind's pod-spec path, containers and initContainers, the four
# required fields independently, the non-workload manifests that must not be
# mistaken for workloads, and the report-every-offender behaviour.

bats_require_minimum_version 1.5.0

load helpers

# shellcheck source=src/scripts/lib/assert-resource-envelopes.bash
source "${LIB_DIR}/assert-resource-envelopes.bash"

# Register the made-up Widget custom resource used by the registry cases.
register_widget() {
  RESOURCE_ENVELOPE_CUSTOM_RESOURCES="widgets.example.com/v1|Widget|.spec.resources"
}

setup() {
  RESOURCE_ENVELOPE_CUSTOM_RESOURCES=""
  TEST_DIR=$(create_test_dir "assert-resource-envelopes")
  MANIFESTS_DIR="${TEST_DIR}/additional-manifests"
  CONTRACTS_DIR="${TEST_DIR}/contracts"
  mkdir -p "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
}

# Write a contract for a staged bundle. Kind defaults to an application kind,
# which is what makes the bundle subject to the check at all.
# Usage: write_contract <bundle> [kind]
write_contract() {
  local bundle="$1"
  local kind="${2:-kubernetes-app-docker-dockerfile}"
  mkdir -p "${CONTRACTS_DIR}/${bundle}"
  cat > "${CONTRACTS_DIR}/${bundle}/contract.yaml" << EOF
apiVersion: kaptain.org/manifests-contract/1.3
kind: ${kind}
tokens:
  delimiterStyle: shell
  nameStyle: PascalCase
compatibility:
  automaticConversion: []
  repackageRequired: []
EOF
}

# Write a manifest into a staged bundle's subdir, body from stdin.
# Usage: write_manifest <bundle> <filename> << 'EOF' ... EOF
write_manifest() {
  local bundle="$1"
  local filename="$2"
  mkdir -p "${MANIFESTS_DIR}/${bundle}"
  cat > "${MANIFESTS_DIR}/${bundle}/${filename}"
}

# A container block with all four required fields, indented to sit under a
# containers list at 8 spaces (the Deployment/Job/StatefulSet depth).
full_envelope_container() {
  local name="$1"
  cat << EOF
        - name: ${name}
          image: example:1.0
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
EOF
}

# =============================================================================
# Argument validation
# =============================================================================

@test "rejects wrong arg count" {
  run assert_resource_envelopes only-one
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "requires exactly 2 arguments"
}

@test "rejects a manifests dir that does not exist" {
  run assert_resource_envelopes "${TEST_DIR}/absent" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "manifests directory not found"
}

# =============================================================================
# Nothing staged
# =============================================================================

@test "passes when no bundles are staged" {
  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

# =============================================================================
# The happy path
# =============================================================================

@test "passes a Deployment whose container declares all four fields" {
  write_contract alpha
  {
    cat << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
EOF
    full_envelope_container alpha
  } | write_manifest alpha deployment.yaml

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

@test "passes when the declared values are unresolved tokens" {
  write_contract alpha
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
          resources:
            requests:
              cpu: ${AlphaCpuRequest}
              memory: ${AlphaMemoryRequest}
            limits:
              cpu: ${AlphaCpuLimit}
              memory: ${AlphaMemoryLimit}
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

# =============================================================================
# The rule itself
# =============================================================================

@test "fails a container with no resources block at all, naming every field" {
  write_contract alpha
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
          image: example:1.0
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "alpha/deployment.yaml"
  assert_output_contains "container 'alpha'"
  assert_output_contains "requests.cpu"
  assert_output_contains "requests.memory"
  assert_output_contains "limits.cpu"
  assert_output_contains "limits.memory"
}

@test "fails a container that declares requests but no limits" {
  write_contract alpha
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  # Asserted against the offender line, not the whole output: the rule block
  # that follows names all four fields whatever is missing.
  assert_output_contains "is missing limits.cpu, limits.memory"
}

@test "fails a container whose cpu limit alone is missing" {
  write_contract alpha
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "is missing limits.cpu"
  # Nothing follows it on the line, so the other three are not reported.
  assert_output_not_contains "is missing limits.cpu,"
}

@test "fails a field declared as an empty value" {
  write_contract alpha
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
          resources:
            requests:
              cpu: ""
              memory: 256Mi
            limits:
              cpu:
              memory: 512Mi
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "requests.cpu"
  assert_output_contains "limits.cpu"
}

@test "fails an initContainer with no resources, beside a compliant container" {
  write_contract alpha
  {
    cat << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      initContainers:
        - name: migrate
          image: example:1.0
      containers:
EOF
    full_envelope_container alpha
  } | write_manifest alpha deployment.yaml

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "container 'migrate'"
  assert_output_not_contains "container 'alpha'"
}

# =============================================================================
# Workload kinds - every pod-spec path
# =============================================================================

@test "fails a StatefulSet, DaemonSet and Job through the template path" {
  write_contract alpha
  write_manifest alpha workloads.yaml << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sts
spec:
  template:
    spec:
      containers:
        - name: sts-container
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds
spec:
  template:
    spec:
      containers:
        - name: ds-container
---
apiVersion: batch/v1
kind: Job
metadata:
  name: job
spec:
  template:
    spec:
      containers:
        - name: job-container
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "container 'sts-container'"
  assert_output_contains "container 'ds-container'"
  assert_output_contains "container 'job-container'"
}

@test "fails a CronJob through the jobTemplate path" {
  write_contract alpha
  write_manifest alpha cronjob.yaml << 'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: slicer
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "container 'slicer'"
}

@test "fails a bare Pod through the spec path" {
  write_contract alpha
  write_manifest alpha pod.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: oneoff
spec:
  containers:
    - name: oneoff
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "container 'oneoff'"
}

# =============================================================================
# What is not a workload
# =============================================================================

@test "passes manifests that carry no pod spec" {
  write_contract alpha
  write_manifest alpha other.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: alpha
spec:
  ports:
    - name: http
      port: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alpha
data:
  containers: "this key is data, not a pod spec"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: alpha
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

# =============================================================================
# Custom resources that declare a budget the operator turns into a pod
#
# The library knows no custom resource by default. A consuming project registers
# the ones it runs in RESOURCE_ENVELOPE_CUSTOM_RESOURCES as
# <apiVersion>|<kind>|<.dotted.path>; these cases use a made-up
# widgets.example.com/v1 Widget that keeps its budget at spec.resources.
# =============================================================================

@test "fails a registered Widget that declares no spec.resources, naming every field" {
  write_contract alpha
  register_widget
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
spec:
  instances: 1
  storage:
    size: 10Gi
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "alpha/widget.yaml"
  assert_output_contains "widgets.example.com/v1 Widget spec.resources 'alpha-widget'"
  assert_output_contains "requests.cpu"
  assert_output_contains "requests.memory"
  assert_output_contains "limits.cpu"
  assert_output_contains "limits.memory"
}

@test "passes a registered Widget declaring all four fields at spec.resources" {
  write_contract alpha
  register_widget
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
spec:
  instances: 1
  resources:
    requests:
      cpu: 250m
      memory: 1Gi
    limits:
      cpu: "1"
      memory: 1Gi
  storage:
    size: 10Gi
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

@test "fails a registered Widget whose cpu request alone is missing" {
  write_contract alpha
  register_widget
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
spec:
  resources:
    requests:
      memory: 1Gi
    limits:
      cpu: "1"
      memory: 1Gi
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "is missing requests.cpu"
}

# The registry is keyed on apiVersion and kind together, never kind alone: a
# kind name is shared by several operators, and checking spec.resources on one
# that keeps its budget elsewhere would read as a pass while proving nothing.
@test "skips a Widget of an apiVersion the registry does not name" {
  write_contract alpha
  register_widget
  write_manifest alpha other-widget.yaml << 'EOF'
apiVersion: other.example.com/v1
kind: Widget
metadata:
  name: not-ours
spec:
  instances: 1
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

@test "checks a registered custom resource at a nested path" {
  write_contract alpha
  RESOURCE_ENVELOPE_CUSTOM_RESOURCES="widgets.example.com/v1|Widget|.spec.pod.resources"
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
spec:
  pod:
    resources:
      requests:
        cpu: 250m
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "widgets.example.com/v1 Widget spec.pod.resources 'alpha-widget' is missing requests.memory, limits.cpu, limits.memory"
}

@test "ignores comments and blank lines in the registry" {
  write_contract alpha
  RESOURCE_ENVELOPE_CUSTOM_RESOURCES=$'# widgets\n\nwidgets.example.com/v1|Widget|.spec.resources\n'
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
spec: {}
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "Widget spec.resources 'alpha-widget' is missing"
}

# A registry entry is data, not an expression: a path that is not a plain dotted
# path is rejected by name instead of being handed to yq, and a malformed entry
# fails the build rather than silently checking nothing.
@test "rejects a registry entry whose path is not a plain dotted path" {
  write_contract alpha
  RESOURCE_ENVELOPE_CUSTOM_RESOURCES='widgets.example.com/v1|Widget|.spec | del(.)'
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "RESOURCE_ENVELOPE_CUSTOM_RESOURCES entry"
  assert_output_contains "is not <apiVersion>|<kind>|<.dotted.path>"
}

@test "rejects a registry entry with no path" {
  write_contract alpha
  RESOURCE_ENVELOPE_CUSTOM_RESOURCES='widgets.example.com/v1|Widget'
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "RESOURCE_ENVELOPE_CUSTOM_RESOURCES entry"
}

# With nothing registered the library checks workloads only, so a custom
# resource with no budget passes - the registry is opt-in.
@test "checks no custom resource when the registry is empty" {
  write_contract alpha
  write_manifest alpha widget.yaml << 'EOF'
apiVersion: widgets.example.com/v1
kind: Widget
metadata:
  name: alpha-widget
spec: {}
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}


# An unregistered custom kind is skipped, not failed. Failing closed on every
# unrecognised kind would fail an HTTPRoute, a Gateway and a HealthCheckPolicy,
# none of which has a pod budget to declare - so the registry's completeness is
# a review gate, named as one in the library's header, rather than faked here.
@test "skips a custom resource with no registered resources path" {
  write_contract alpha
  write_manifest alpha http-route.yaml << 'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: alpha
spec:
  parentRefs:
    - name: shared
  rules:
    - backendRefs:
        - name: web
          port: 80
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

@test "ignores modifier files beside a manifest" {
  write_contract alpha
  {
    cat << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
EOF
    full_envelope_container alpha
  } | write_manifest alpha deployment.yaml
  write_manifest alpha deployment.yaml.yq-merge-yaml-keelson << 'EOF'
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: alpha
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
}

# =============================================================================
# The application-kind filter
# =============================================================================

@test "skips a bundle whose contract kind is not an application kind" {
  write_contract vendorthing kubernetes-bundle-vendor-helm-rendered
  write_manifest vendorthing deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: operator
spec:
  template:
    spec:
      containers:
        - name: operator
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -eq 0 ] || return 1
  assert_output_contains "not an application"
}

@test "checks every kubernetes-app-* kind" {
  write_contract alpha kubernetes-app-manifests-only
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "container 'alpha'"
}

@test "fails a staged bundle with no contract rather than skipping it" {
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "no contract"
}

# =============================================================================
# Unparseable manifests
# =============================================================================

@test "fails a manifest that cannot be read as YAML, naming the file" {
  write_contract alpha
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: alpha
          resources:
            limits:
              memory: %{MemoryLimit}
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "alpha/deployment.yaml"
  assert_output_contains "could not be read as YAML"
}

# =============================================================================
# Reporting
# =============================================================================

@test "reports every offending container across every bundle before failing" {
  write_contract alpha
  write_contract beta
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha-api
        - name: alpha-worker
EOF
  write_manifest beta deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: beta
spec:
  template:
    spec:
      containers:
        - name: beta-web
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "container 'alpha-api'"
  assert_output_contains "container 'alpha-worker'"
  assert_output_contains "container 'beta-web'"
}

@test "states the rule and where the envelopes live when it fails" {
  write_contract alpha
  write_manifest alpha deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alpha
spec:
  template:
    spec:
      containers:
        - name: alpha
EOF

  run assert_resource_envelopes "${MANIFESTS_DIR}" "${CONTRACTS_DIR}"
  [ "${status}" -ne 0 ] || return 1
  assert_output_contains "spec.main.workload.container.resources"
}
