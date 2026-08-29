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

@test "consume: short-first emits both references, org-local first" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro" short-first
  [ "$status" -eq 0 ]

  expected='
### How to Consume

**From any project using `ghcr.io/keelson-pro`**

```
keelson:[1.8.4]
```

**From any org, registry or platform**

```
ghcr.io/keelson-pro/keelson/keelson:[1.8.4]
```

The brackets pin that exact version. A range such as `[1.8.4,2.0.0)` works in the same place but results in a slower and less secure build.'
  [ "$output" = "$expected" ]
}

@test "consume: full-first emits both references, fully qualified first" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro" full-first
  [ "$status" -eq 0 ]

  expected='
### How to Consume

**From any org, registry or platform**

```
ghcr.io/keelson-pro/keelson/keelson:[1.8.4]
```

**From any project using `ghcr.io/keelson-pro`**

```
keelson:[1.8.4]
```

The brackets pin that exact version. A range such as `[1.8.4,2.0.0)` works in the same place but results in a slower and less secure build.'
  [ "$output" = "$expected" ]
}

@test "consume: short-only emits one unlabelled reference" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro" short-only
  [ "$status" -eq 0 ]

  expected='
### How to Consume

```
keelson:[1.8.4]
```

The brackets pin that exact version. A range such as `[1.8.4,2.0.0)` works in the same place but results in a slower and less secure build.'
  [ "$output" = "$expected" ]
}

@test "consume: full-only emits one unlabelled reference" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro" full-only
  [ "$status" -eq 0 ]

  expected='
### How to Consume

```
ghcr.io/keelson-pro/keelson/keelson:[1.8.4]
```

The brackets pin that exact version. A range such as `[1.8.4,2.0.0)` works in the same place but results in a slower and less secure build.'
  [ "$output" = "$expected" ]
}

@test "consume: forms defaults to short-only when omitted" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro"
  [ "$status" -eq 0 ]
  [[ "$output" == *'keelson:[1.8.4]'* ]]
  [[ "$output" != *"ghcr.io"* ]]
  [[ "$output" != *"**"* ]]
}

@test "consume: forms defaults to short-only when passed empty" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"ghcr.io"* ]]
}

@test "consume: empty namespace drops the slash from the label" {
  run "$FRS" consume "layer-foo" "1.3.2" "ghcr.io" "" short-first
  [ "$status" -eq 0 ]
  [[ "$output" == *'**From any project using `ghcr.io`**'* ]]
  [[ "$output" != *'`ghcr.io/`'* ]]
  [[ "$output" == *'ghcr.io/layer/layer-foo:[1.3.2]'* ]]
}

@test "consume: range upper bound is next major with the same part count" {
  run "$FRS" consume "keelson" "5" "ghcr.io" "keelson-pro"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`[5,6)`'* ]]

  run "$FRS" consume "keelson" "2.4" "ghcr.io" "keelson-pro"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`[2.4,3.0)`'* ]]

  run "$FRS" consume "keelson" "1.2.3.4" "ghcr.io" "keelson-pro"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`[1.2.3.4,2.0.0.0)`'* ]]

  run "$FRS" consume "keelson" "10.9.9" "ghcr.io" "keelson-pro"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`[10.9.9,11.0.0)`'* ]]
}

@test "consume: full reference validates as a full reference" {
  run "$FRS" consume "quality-strict" "1.0.7" "ghcr.io" "kube-kaptain" full-only
  [ "$status" -eq 0 ]

  # Pull the reference back out of the notes and feed it to the resolver's
  # parser as a consumer would. The pre-fix output dropped the prefix path
  # segment and failed this validation outright.
  full_reference=$(echo "$output" | grep '^ghcr\.io')
  [ "$full_reference" = 'ghcr.io/kube-kaptain/quality/quality-strict:[1.0.7]' ]

  run bash -c "
    source '$PROJECT_ROOT/src/scripts/defaults/platform.bash'
    source '$LIB_DIR/log.bash'
    source '$LIB_DIR/docker-ref-expand.bash'
    docker_ref_expand '${full_reference%:*}:1.0.7'
    echo \"\${DOCKER_REF_FORM} \${DOCKER_REF_FULL_NAME}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'full ghcr.io/kube-kaptain/quality/quality-strict'* ]]
}

@test "consume: fails on unknown forms value" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro" both
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown forms value 'both'"* ]]
}

@test "consume: fails on missing arguments" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io"
  [ "$status" -ne 0 ]
}

@test "consume: fails on too many arguments" {
  run "$FRS" consume "keelson" "1.8.4" "ghcr.io" "keelson-pro" short-first extra
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
