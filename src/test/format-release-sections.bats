#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Kaptain contributors (Fred Cooke)
#
# Tests for util/format-release-sections - the shared release-notes section
# formatter used by every flavour's github-release steps-common block.

bats_require_minimum_version 1.5.0

load helpers

FRS="$UTIL_DIR/format-release-sections"

setup() {
  WORK=$(create_test_dir "format-release-sections")
}

teardown() {
  dump_bats_result
}

# =============================================================================
# consume
# =============================================================================

@test "consume: emits short and long forms with descriptions and range note" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro"
  [ "$status" -eq 0 ]

  expected='
### How to Consume

* `keelson:[1.8.4]` - same org, registry, and namespace
* `ghcr.io/keelson-pro/keelson/keelson:[1.8.4]` - from a different org or overridden namespace or registry

Optionally use a range instead of the locked version above.'
  [ "$output" = "$expected" ]
}

@test "consume: empty namespace collapses to registry/prefix/name" {
  run "$FRS" consume "layer-foo" "1.3.2" "ghcr.io" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *'`ghcr.io/layer/layer-foo:[1.3.2]`'* ]]
}

@test "consume: long form validates as a full reference" {
  run "$FRS" consume "quality-strict" "1.0.7" "ghcr.io" "kube-kaptain"
  [ "$status" -eq 0 ]

  # Pull the long form back out of the notes and feed it to the resolver's
  # parser as a consumer would. The pre-fix output dropped the prefix path
  # segment and failed this validation outright.
  long_form=$(echo "$output" | sed -n 's/^\* `\(ghcr\.io[^`]*\)`.*/\1/p')
  [ "$long_form" = 'ghcr.io/kube-kaptain/quality/quality-strict:[1.0.7]' ]

  run bash -c "
    source '$PROJECT_ROOT/src/scripts/defaults/platform.bash'
    source '$LIB_DIR/log.bash'
    source '$LIB_DIR/docker-ref-expand.bash'
    docker_ref_expand '${long_form%:*}:1.0.7'
    echo \"\${DOCKER_REF_FORM} \${DOCKER_REF_FULL_NAME}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'full ghcr.io/kube-kaptain/quality/quality-strict'* ]]
}

@test "consume: fails on missing arguments" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io"
  [ "$status" -ne 0 ]
}

@test "consume: fails on empty project name" {
  run "$FRS" consume "" "1.8.4" "ghcr.io" "ns"
  [ "$status" -ne 0 ]
}

@test "consume: fails on empty registry" {
  run "$FRS" consume "keelson" "1.8.4" "" "ns"
  [ "$status" -ne 0 ]
}

# =============================================================================
# list
# =============================================================================

@test "list: emits heading plus file bullets" {
  printf -- '- keelson:[1.8]\n- quality-strict:[2.1]\n' > "${WORK}/templates-list"

  run "$FRS" list "Templates that contributed" "${WORK}/templates-list"
  [ "$status" -eq 0 ]

  expected='
### Templates that contributed
- keelson:[1.8]
- quality-strict:[2.1]'
  [ "$output" = "$expected" ]
}

@test "list: missing file -> emits nothing, succeeds" {
  run "$FRS" list "Contents" "${WORK}/does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list: empty file -> emits nothing, succeeds" {
  : > "${WORK}/empty-list"
  run "$FRS" list "Contents" "${WORK}/empty-list"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list: empty path -> emits nothing, succeeds" {
  run "$FRS" list "Contents" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list: fails on empty heading" {
  run "$FRS" list "" "${WORK}/whatever"
  [ "$status" -ne 0 ]
}

# =============================================================================
# mode routing
# =============================================================================

@test "unknown mode fails with usage" {
  run "$FRS" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown mode"* ]]
}
