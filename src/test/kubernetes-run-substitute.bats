#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for main/kubernetes-run-substitute - the post-substitution gate and
# the IgnoreUnresolved markers that exempt selected residue from it.
#
# The gate itself is unchanged by markers when a tree carries none: any
# unresolved token outside a secret template fails, and inside one it must
# have an encrypted value (env builds) or is deferred (RP builds). The marker
# tests cover the four forms, the specifier narrowing, staleness always being
# fatal regardless of BUILD_MODE, and markers being rejected outright in
# secret templates.
#
# The marker grammar itself is covered by convert-tokens-in-tree.bats, which
# exercises the same parser in lib/token-markers.bash through the other
# family.

bats_require_minimum_version 1.5.0

load helpers

SCRIPT="$SCRIPTS_DIR/kubernetes-run-substitute"

setup() {
  TEST_DIR=$(create_test_dir "kubernetes-run-substitute")
  NORMALISED="${TEST_DIR}/kaptain-out/run-environment/manifests-aggregated"
  mkdir -p "${NORMALISED}" "${TEST_DIR}/src/config" "${TEST_DIR}/src/secrets"

  export GITHUB_OUTPUT="${TEST_DIR}/github-output"
  : > "${GITHUB_OUTPUT}"

  export OUTPUT_SUB_PATH="kaptain-out"
  export PROJECT_NAME="run-env-test"
  export ENVIRONMENT_SHORT_NAME="test"
  export BUILD_MODE="build_server"
  # Isolate the gate: the unreferenced-value check is a separate step with
  # its own policy and would otherwise fail these fixtures for its own reasons.
  export ENV_FAIL_ON_UNREFERENCED_CONFIG_OR_SECRETS="false"

  # prepare-substitution-tokens requires the full version/docker family.
  export VERSION="1.0.0"
  export VERSION_MAJOR="1" VERSION_MINOR="0" VERSION_PATCH="0"
  export VERSION_2_PART="1.0" VERSION_3_PART="1.0.0" VERSION_4_PART="1.0.0.0"
  export VERSION_DNS_SAFE="1-0-0" VERSION_2_PART_DNS_SAFE="1-0"
  export VERSION_3_PART_DNS_SAFE="1-0-0" VERSION_4_PART_DNS_SAFE="1-0-0-0"
  export GIT_TAG="v1.0.0" IS_RELEASE="false"
  export DOCKER_TAG="testtag" DOCKER_IMAGE_NAME="testimage"

  setup_mock_decryption_providers

  cd "${TEST_DIR}"
}

# Write a manifest into the assembled tree the substitute step consumes.
write_manifest() {
  local name="${1}"
  cat > "${NORMALISED}/${name}"
}

IGNORES_TSV="kaptain-out/run-environment/substitution-gate-ignores.tsv"

# =============================================================================
# The gate without markers - unchanged behaviour
# =============================================================================

@test "run-substitute: unresolved token outside a secret template fails" {
  write_manifest plain.yaml << 'EOF'
leftover: ${Unknown}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'Unknown'"
}

@test "run-substitute: a fully resolved tree passes the gate" {
  printf '%s' 'yes' > src/config/Known
  write_manifest plain.yaml << 'EOF'
resolved: ${Known}
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "Gate passed"
}

@test "run-substitute: secret-template token without an encrypted value fails" {
  write_manifest thing.template.yaml << 'EOF'
secret: ${SomeSecret}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'SomeSecret' in a secret template"
}

@test "run-substitute: secret-template token with an encrypted value passes" {
  printf '%s' 'ciphertext' > src/secrets/SomeSecret.age
  write_manifest thing.template.yaml << 'EOF'
secret: ${SomeSecret}
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "Gate passed"
}

@test "run-substitute: an unmarked tree writes no ignores file" {
  write_manifest plain.yaml << 'EOF'
nothing: here
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "${IGNORES_TSV}" ]
}

# =============================================================================
# IgnoreUnresolved markers - suppression
# =============================================================================

@test "run-substitute: bare IgnoreUnresolved suppresses every token on its line" {
  write_manifest plain.yaml << 'EOF'
expected: ${RuntimeThing}-${AlsoRuntime} # IgnoreUnresolved
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "Gate passed"
}

@test "run-substitute: IgnoreUnresolved with a specifier still fails on the other token" {
  write_manifest plain.yaml << 'EOF'
partial: ${AlsoRuntime}-${Missed} # IgnoreUnresolved: ${AlsoRuntime}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'Missed'"
  # The named token is gone from the report, including its occurrence inside
  # the marker text itself.
  [[ "$output" != *"unresolved token 'AlsoRuntime'"* ]] || return 1
}

@test "run-substitute: IgnoreUnresolvedAbove covers the line above" {
  write_manifest plain.yaml << 'EOF'
above: ${OneRt}
# IgnoreUnresolvedAbove
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "Gate passed"
}

@test "run-substitute: IgnoreUnresolvedBelow with a specifier covers the named token" {
  write_manifest plain.yaml << 'EOF'
# IgnoreUnresolvedBelow: ${FourRt}
below: ${FourRt}
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "Gate passed"
}

@test "run-substitute: IgnoreUnresolvedLines covers bare numbers and line:token entries" {
  write_manifest plain.yaml << 'EOF'
# IgnoreUnresolvedLines: 2,3:${Third}
whole: ${OneRt}-${TwoRt}
named: ${Third}-${Missed}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'Missed'"
  [[ "$output" != *"unresolved token 'OneRt'"* ]] || return 1
  [[ "$output" != *"unresolved token 'Third'"* ]] || return 1
}

@test "run-substitute: records exemptions in the ignores audit file" {
  write_manifest plain.yaml << 'EOF'
expected: ${RuntimeThing} # IgnoreUnresolved
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "${IGNORES_TSV}" ]
  awk -F'\t' '$1 == "plain.yaml" && $2 == "1" && $3 == "*" { found = 1 } END { exit found ? 0 : 1 }' "${IGNORES_TSV}"
  assert_output_contains "IgnoreUnresolved markers: 1 exemption(s) across 1 file(s)."
}

# =============================================================================
# IgnoreUnresolved markers - stale markers are always fatal
# =============================================================================

@test "run-substitute: a stale marker fails a server build" {
  write_manifest plain.yaml << 'EOF'
gone: value # IgnoreUnresolved
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "holds no token-shaped content"
  assert_output_contains "IgnoreUnresolved marker problem(s)"
}

@test "run-substitute: a stale marker fails a local build too" {
  export BUILD_MODE="local"
  write_manifest plain.yaml << 'EOF'
gone: value # IgnoreUnresolved
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "Marker problems fail every"
}

@test "run-substitute: unresolved tokens fail a local build too" {
  export BUILD_MODE="local"
  write_manifest plain.yaml << 'EOF'
leftover: ${Unknown}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'Unknown'"
}

@test "run-substitute: a secret template without a value names both possible causes" {
  write_manifest thing.template.yaml << 'EOF'
secret: ${SomeSecret}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "no config value supplied it"
  assert_output_contains "no encrypted value at"
}

@test "run-substitute: a secret template without a value fails a local build too" {
  export BUILD_MODE="local"
  write_manifest thing.template.yaml << 'EOF'
secret: ${SomeSecret}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "run-substitute: a marker naming a token that resolved is stale" {
  printf '%s' 'yes' > src/config/Known
  write_manifest plain.yaml << 'EOF'
resolved: ${Known}-${Unknown} # IgnoreUnresolved: ${Known}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  # The gate runs on the substituted tree, so a specifier naming a token that
  # DID resolve was itself rewritten to that token's value and is no longer a
  # token reference. Stale either way, and self-evidently so in the message.
  assert_output_contains "is not a token reference"
}

@test "run-substitute: a marker naming a token absent from the line is stale" {
  write_manifest plain.yaml << 'EOF'
here: ${Present} # IgnoreUnresolved: ${Elsewhere}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "is not present on"
}

@test "run-substitute: IgnoreUnresolvedAbove on the first line fails" {
  write_manifest plain.yaml << 'EOF'
# IgnoreUnresolvedAbove
below: ${OneRt}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "has no line above it"
}

@test "run-substitute: a marker in a secret template is rejected" {
  printf '%s' 'ciphertext' > src/secrets/SomeSecret.age
  write_manifest thing.template.yaml << 'EOF'
secret: ${SomeSecret} # IgnoreUnresolved
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "have no effect in a secret template"
}

# =============================================================================
# Nested token names and encrypted value suffixes
# =============================================================================

@test "run-substitute: unresolved nested token fails the gate" {
  write_manifest plain.yaml << 'EOF'
leftover: ${Vendor/Unknown}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'Vendor/Unknown'"
}

@test "run-substitute: nested secret-template token without a value fails" {
  printf '%s' 'ciphertext' > src/secrets/DbPassword.age
  write_manifest thing.template.yaml << 'EOF'
secret: ${Vendor/DbPassword}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'Vendor/DbPassword' in a secret template"
}

@test "run-substitute: nested secret-template token with a nested value passes" {
  mkdir -p src/secrets/Vendor
  printf '%s' 'ciphertext' > src/secrets/Vendor/DbPassword.sha256.aes256.10k
  write_manifest thing.template.yaml << 'EOF'
secret: ${Vendor/DbPassword}
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "Gate passed"
}

@test "run-substitute: referenced nested config and secret values are not unreferenced" {
  export ENV_FAIL_ON_UNREFERENCED_CONFIG_OR_SECRETS="true"
  mkdir -p src/config/Vendor src/secrets/Vendor
  printf '%s' 'db.internal' > src/config/Vendor/DbHost
  printf '%s' 'ciphertext' > src/secrets/Vendor/DbPassword.age
  write_manifest plain.yaml << 'EOF'
host: ${Vendor/DbHost}
EOF
  write_manifest thing.template.yaml << 'EOF'
secret: ${Vendor/DbPassword}
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx '  - Vendor/DbHost' kaptain-out/run-environment/token-usage.yaml
}

@test "run-substitute: unreferenced values are named by token, nested path kept, suffix dropped" {
  export ENV_FAIL_ON_UNREFERENCED_CONFIG_OR_SECRETS="true"
  mkdir -p src/config/Vendor src/secrets/Vendor
  printf '%s' 'db.internal' > src/config/Vendor/DbHost
  printf '%s' 'ciphertext' > src/secrets/Vendor/DbPassword.age
  write_manifest plain.yaml << 'EOF'
nothing: here
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unreferenced config value 'Vendor/DbHost'"
  assert_output_contains "unreferenced secret value 'Vendor/DbPassword'"
  assert_output_not_contains "DbPassword.age"
  assert_output_contains "2 unreferenced config/secret value(s)"
}

@test "run-substitute: the gate matches tokens in the configured delimiter style" {
  export TOKEN_DELIMITER_STYLE="mustache"
  write_manifest plain.yaml << 'EOF'
leftover: {{ Vendor/Unknown }}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'Vendor/Unknown'"
}

@test "run-substitute: references are counted in the configured delimiter style" {
  export TOKEN_DELIMITER_STYLE="mustache"
  export ENV_FAIL_ON_UNREFERENCED_CONFIG_OR_SECRETS="true"
  mkdir -p src/config/Vendor
  printf '%s' 'db.internal' > src/config/Vendor/DbHost
  write_manifest plain.yaml << 'EOF'
host: {{ Vendor/DbHost }}
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx '  - Vendor/DbHost' kaptain-out/run-environment/token-usage.yaml
}

teardown() {
  dump_bats_result
}

# =============================================================================
# Patches pass through the gate too
# =============================================================================
# run-finalise merges yq patches into their manifests after this gate and
# nothing re-scans the tree, so a patch the gate skipped shipped whatever it
# left unresolved.

@test "run-substitute: an unresolved token in a yq patch fails the gate" {
  printf '%s' 'yes' > src/config/Known
  write_manifest plain.yaml << 'EOF'
resolved: ${Known}
EOF
  write_manifest plain.yaml.yq-merge-yaml-extra << 'EOF'
extra: ${Unknown}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "plain.yaml.yq-merge-yaml-extra: unresolved token 'Unknown'"
}

@test "run-substitute: a patch to a secret template is held to the secret-template rule" {
  write_manifest thing.template.yaml << 'EOF'
kind: Secret
EOF
  write_manifest thing.template.yaml.yq-merge-yaml-extra << 'EOF'
secret: ${PatchedSecret}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  assert_output_contains "unresolved token 'PatchedSecret' in a secret template"
}

@test "run-substitute: a patch to a secret template passes with an encrypted value" {
  printf '%s' 'ciphertext' > src/secrets/PatchedSecret.age
  write_manifest thing.template.yaml << 'EOF'
kind: Secret
EOF
  write_manifest thing.template.yaml.yq-merge-yaml-extra << 'EOF'
secret: ${PatchedSecret}
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_output_contains "Gate passed"
}
