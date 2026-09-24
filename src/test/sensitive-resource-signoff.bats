#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for lib/sensitive-resource-signoff.bash.
#
# Covers the canonical-hash strip expression (kaptain.org/, keel.sh/,
# keelson.io/ annotations + version labels do not affect the hash), the
# four failure modes (missing signoff, mismatched checksum, stale signoff,
# malformed signoff), kinds-file loading (versioned data file, replace
# semantics), and the source-path convention (env-root-relative; first
# path segment stripped).

load helpers

setup() {
  TEST_DIR=$(create_test_dir "sensitive-resource-signoff")
  # shellcheck source=src/scripts/lib/sensitive-resource-signoff.bash
  source "${LIB_DIR}/sensitive-resource-signoff.bash"

  # The shipped default sensitive-Kind list (versioned data file).
  KINDS_FILE="${LIB_DIR}/../../data/signoff-kinds/default-1.1.txt"

  MANIFESTS_DIR="${TEST_DIR}/manifests"
  SIGNOFFS_DIR="${TEST_DIR}/signoffs"
  mkdir -p "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes" \
           "${SIGNOFFS_DIR}/some-app/src/kubernetes"
}

# Write a basic Ingress manifest under the assembled tree. The first
# path segment 'run-foo' is the env root - the signoff path strips it.
write_ingress() {
  cat > "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes/ingress.yaml" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
spec:
  rules:
  - host: example.com
EOF
}

write_signoff() {
  local checksum="$1"
  cat > "${SIGNOFFS_DIR}/some-app/src/kubernetes/ingress.yaml" << EOF
sourcePath: some-app/src/kubernetes/ingress.yaml
checksum:   sha256:${checksum}
EOF
}

# =============================================================================
# signoff_canonical_hash - strip expression
# =============================================================================

@test "hash: kaptain.org/ annotations do not affect the hash" {
  local f="${TEST_DIR}/manifest.yaml"
  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
spec:
  rules: []
EOF
  local h1
  h1=$(signoff_canonical_hash "${f}")

  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
  annotations:
    kaptain.org/managed-by: kaptain
    kaptain.org/version: "1.2.3"
spec:
  rules: []
EOF
  local h2
  h2=$(signoff_canonical_hash "${f}")
  [ "${h1}" = "${h2}" ]
}

@test "hash: keel.sh/ and keelson.io/ annotations do not affect the hash" {
  local f="${TEST_DIR}/manifest.yaml"
  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
spec:
  rules: []
EOF
  local h1
  h1=$(signoff_canonical_hash "${f}")

  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
  annotations:
    keel.sh/policy: force
    keelson.io/track: latest
spec:
  rules: []
EOF
  local h2
  h2=$(signoff_canonical_hash "${f}")
  [ "${h1}" = "${h2}" ]
}

@test "hash: kaptain.org/version and app.kubernetes.io/version labels do not affect the hash" {
  local f="${TEST_DIR}/manifest.yaml"
  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
spec:
  rules: []
EOF
  local h1
  h1=$(signoff_canonical_hash "${f}")

  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
  labels:
    kaptain.org/version: "1.0.0"
    app.kubernetes.io/version: "1.0.0"
spec:
  rules: []
EOF
  local h2
  h2=$(signoff_canonical_hash "${f}")
  [ "${h1}" = "${h2}" ]
}

@test "hash: spec content changes do affect the hash" {
  local f="${TEST_DIR}/manifest.yaml"
  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
spec:
  rules:
  - host: a.example.com
EOF
  local h1
  h1=$(signoff_canonical_hash "${f}")

  cat > "${f}" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ing
spec:
  rules:
  - host: b.example.com
EOF
  local h2
  h2=$(signoff_canonical_hash "${f}")
  [ "${h1}" != "${h2}" ]
}

@test "hash: pod-template rollout annotations on workloads do not affect the hash" {
  local f="${TEST_DIR}/manifest.yaml"
  cat > "${f}" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: d
spec:
  template:
    metadata:
      annotations: {}
    spec:
      containers: [{ name: d, image: i }]
EOF
  local h1
  h1=$(signoff_canonical_hash "${f}")

  cat > "${f}" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: d
spec:
  template:
    metadata:
      annotations:
        kaptain.org/cm-checksum: deadbeef
        keel.sh/policy: force
    spec:
      containers: [{ name: d, image: i }]
EOF
  local h2
  h2=$(signoff_canonical_hash "${f}")
  [ "${h1}" = "${h2}" ]
}

@test "hash: missing file fails loudly" {
  run signoff_canonical_hash "${TEST_DIR}/does-not-exist.yaml"
  [ "${status}" -ne 0 ]
  assert_output_contains "Manifest file not found"
}

@test "hash: missing argument fails loudly" {
  run signoff_canonical_hash
  [ "${status}" -ne 0 ]
  assert_output_contains "requires exactly 1 argument"
}

# =============================================================================
# signoff_check_tree - end-to-end coverage / integrity
# =============================================================================

@test "tree: matching signoff passes" {
  write_ingress
  local h
  h=$(signoff_canonical_hash "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes/ingress.yaml")
  write_signoff "${h}"

  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -eq 0 ]
  assert_output_contains "Signoff check passed"
}

@test "tree: missing signoff fails with expected-path hint" {
  write_ingress
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -ne 0 ]
  assert_output_contains "Sensitive resource has no signoff"
  assert_output_contains "some-app/src/kubernetes/ingress.yaml"
  assert_output_contains "expected at:"
}

@test "tree: mismatched checksum fails with both expected and actual" {
  write_ingress
  write_signoff "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -ne 0 ]
  assert_output_contains "Signoff checksum mismatch"
  assert_output_contains "expected: sha256:deadbeef"
  assert_output_contains "Re-review and update"
}

@test "tree: stale signoff (no matching resource) fails" {
  # No sensitive manifests at all.
  cat > "${SIGNOFFS_DIR}/some-app/src/kubernetes/ingress.yaml" << 'EOF'
sourcePath: some-app/src/kubernetes/ingress.yaml
checksum:   sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
EOF
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -ne 0 ]
  assert_output_contains "Stale signoff"
  assert_output_contains "some-app/src/kubernetes/ingress.yaml"
}

@test "tree: malformed signoff (missing checksum field) fails" {
  write_ingress
  cat > "${SIGNOFFS_DIR}/some-app/src/kubernetes/ingress.yaml" << 'EOF'
sourcePath: some-app/src/kubernetes/ingress.yaml
EOF
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -ne 0 ]
  assert_output_contains "missing 'checksum' field"
}

@test "tree: non-sensitive resources do not require a signoff" {
  cat > "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes/service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: svc
spec:
  ports: []
EOF
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -eq 0 ]
}

@test "tree: custom kinds file replaces the default list entirely" {
  # Service is not in the default list; Ingress is. With a custom file
  # listing only Service, the Service is flagged and the Ingress is NOT
  # (replace semantics, no merge).
  write_ingress
  cat > "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes/service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: svc
spec:
  ports: []
EOF
  local custom="${TEST_DIR}/custom-kinds.txt"
  cat > "${custom}" << 'EOF'
# custom sensitive kinds - replaces the default list
Service
EOF
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${custom}"
  [ "${status}" -ne 0 ]
  assert_output_contains "Sensitive resource has no signoff"
  assert_output_contains "service.yaml"
  ! grep -q "ingress.yaml" <<< "${output}"
}

@test "tree: missing kinds file fails loudly" {
  write_ingress
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${TEST_DIR}/no-such-kinds.txt"
  [ "${status}" -ne 0 ]
  assert_output_contains "kinds file not found"
}

@test "tree: multi-doc YAML hashed as a single unit" {
  mkdir -p "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes"
  cat > "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes/rbac.yaml" << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: r
rules: []
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: r
subjects: []
EOF
  local h
  h=$(signoff_canonical_hash "${MANIFESTS_DIR}/run-foo/some-app/src/kubernetes/rbac.yaml")
  [ -n "${h}" ]
  mkdir -p "${SIGNOFFS_DIR}/some-app/src/kubernetes"
  cat > "${SIGNOFFS_DIR}/some-app/src/kubernetes/rbac.yaml" << EOF
sourcePath: some-app/src/kubernetes/rbac.yaml
checksum:   sha256:${h}
EOF
  run signoff_check_tree "${MANIFESTS_DIR}" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -eq 0 ]
}

@test "tree: missing manifests dir fails loudly" {
  run signoff_check_tree "${TEST_DIR}/does-not-exist" "${SIGNOFFS_DIR}" "${KINDS_FILE}"
  [ "${status}" -ne 0 ]
  assert_output_contains "Manifests directory not found"
}

@test "tree: missing required arguments fails loudly" {
  run signoff_check_tree "${MANIFESTS_DIR}"
  [ "${status}" -ne 0 ]
  assert_output_contains "Usage: signoff_check_tree"
}

teardown() {
  dump_bats_result
}
