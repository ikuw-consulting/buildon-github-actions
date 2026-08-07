#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for convert-tokens-in-tree utility
#
# Rewrites unresolved tokens in a directory of files from one (delimiter,
# name) scheme to another, in place. Built on the regex/format/canonical
# primitives in lib/token-format.bash.

bats_require_minimum_version 1.5.0

load helpers

CONVERT_SCRIPT="$UTIL_DIR/convert-tokens-in-tree"

setup() {
  TEST_DIR=$(create_test_dir "convert-tokens")
  # The tool requires context-root-relative targets: run from the test dir
  # and pass relative paths, exactly as production callers do.
  export OUTPUT_SUB_PATH="kaptain-out"
  cd "${TEST_DIR}"
}

# =============================================================================
# Argument validation
# =============================================================================

@test "convert-tokens-in-tree: fails with no arguments" {
  run "$CONVERT_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "convert-tokens-in-tree: fails with too few arguments" {
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase
  [ "$status" -ne 0 ]
}

@test "convert-tokens-in-tree: fails with invalid from-delim" {
  mkdir -p "$TEST_DIR/d"
  run "$CONVERT_SCRIPT" bogus PascalCase mustache PascalCase "d"
  [ "$status" -eq 2 ]
}

@test "convert-tokens-in-tree: fails with invalid from-name" {
  mkdir -p "$TEST_DIR/d"
  run "$CONVERT_SCRIPT" shell BogusCase mustache PascalCase "d"
  [ "$status" -eq 2 ]
}

@test "convert-tokens-in-tree: fails with invalid to-delim" {
  mkdir -p "$TEST_DIR/d"
  run "$CONVERT_SCRIPT" shell PascalCase bogus PascalCase "d"
  [ "$status" -eq 2 ]
}

@test "convert-tokens-in-tree: fails with invalid to-name" {
  mkdir -p "$TEST_DIR/d"
  run "$CONVERT_SCRIPT" shell PascalCase mustache BogusCase "d"
  [ "$status" -eq 2 ]
}

@test "convert-tokens-in-tree: fails with nonexistent directory" {
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase nonexistent/dir
  [ "$status" -ne 0 ]
}

# =============================================================================
# No-op: same scheme
# =============================================================================

@test "convert-tokens-in-tree: same scheme is a no-op" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/manifest.yaml" << 'EOF'
apiVersion: v1
kind: Deployment
spec:
  replicas: ${Replicas}
EOF
  before=$(cat "$TEST_DIR/d/manifest.yaml")
  run "$CONVERT_SCRIPT" shell PascalCase shell PascalCase "d"
  [ "$status" -eq 0 ]
  after=$(cat "$TEST_DIR/d/manifest.yaml")
  [ "$before" = "$after" ]
  echo "$output" | grep -q "No conversion needed"
}

# =============================================================================
# No-op: empty directory / no tokens
# =============================================================================

@test "convert-tokens-in-tree: empty directory exits 0 with message" {
  mkdir -p "$TEST_DIR/empty"
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "empty"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No .* tokens found"
}

@test "convert-tokens-in-tree: directory with no tokens leaves files unchanged" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/plain.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: plain
data:
  greeting: hello
EOF
  before=$(cat "$TEST_DIR/d/plain.yaml")
  run "$CONVERT_SCRIPT" shell PascalCase mustache UPPER_SNAKE "d"
  [ "$status" -eq 0 ]
  after=$(cat "$TEST_DIR/d/plain.yaml")
  [ "$before" = "$after" ]
}

# =============================================================================
# Delimiter-only conversion
# =============================================================================

@test "convert-tokens-in-tree: shell -> mustache, PascalCase -> PascalCase" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: ${Replicas}
  template:
    spec:
      containers:
        - image: ${DockerImageName}:${DockerTag}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/deployment.yaml")
  echo "$result" | grep -q "{{ Replicas }}"
  echo "$result" | grep -q "{{ DockerImageName }}"
  echo "$result" | grep -q "{{ DockerTag }}"
  ! echo "$result" | grep -q '\${'
}

@test "convert-tokens-in-tree: shell -> helm preserves token names" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/svc.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ${ServiceName}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase helm PascalCase "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/svc.yaml")
  echo "$result" | grep -q "{{ .Values.ServiceName }}"
}

# =============================================================================
# Name-only conversion
# =============================================================================

@test "convert-tokens-in-tree: shell PascalCase -> shell UPPER_SNAKE" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: ${Replicas}
  template:
    spec:
      containers:
        - image: ${DockerImageName}:${DockerTag}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase shell UPPER_SNAKE "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/deployment.yaml")
  echo "$result" | grep -q '\${REPLICAS}'
  echo "$result" | grep -q '\${DOCKER_IMAGE_NAME}'
  echo "$result" | grep -q '\${DOCKER_TAG}'
}

@test "convert-tokens-in-tree: shell UPPER_SNAKE -> shell lower-kebab" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/cfg.yaml" << 'EOF'
data:
  a: ${MAX_HEAP_SIZE}
  b: ${USER_HOME}
EOF
  run "$CONVERT_SCRIPT" shell UPPER_SNAKE shell lower-kebab "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/cfg.yaml")
  echo "$result" | grep -q '\${max-heap-size}'
  echo "$result" | grep -q '\${user-home}'
}

# =============================================================================
# Both delimiter + name conversion
# =============================================================================

@test "convert-tokens-in-tree: shell PascalCase -> mustache lower-kebab" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/deployment.yaml" << 'EOF'
spec:
  replicas: ${Replicas}
  resources:
    requests:
      memory: ${MaxHeapSize}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache lower-kebab "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/deployment.yaml")
  echo "$result" | grep -q "{{ replicas }}"
  echo "$result" | grep -q "{{ max-heap-size }}"
}

@test "convert-tokens-in-tree: erb PascalCase -> shell UPPER_SNAKE" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/x.yaml" << 'EOF'
data:
  a: <%= ImageName %>
  b: <%= ImageTag %>
EOF
  run "$CONVERT_SCRIPT" erb PascalCase shell UPPER_SNAKE "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/x.yaml")
  echo "$result" | grep -q '\${IMAGE_NAME}'
  echo "$result" | grep -q '\${IMAGE_TAG}'
}

# =============================================================================
# Nested-path tokens (with /)
# =============================================================================

@test "convert-tokens-in-tree: nested PascalCase -> nested UPPER_SNAKE preserves slashes" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/deployment.yaml" << 'EOF'
spec:
  replicas: ${VendorEnvoyGateway/Replicas}
  resources:
    requests:
      memory: ${VendorEnvoyGateway/Memory}
      cpu: ${VendorEnvoyGateway/Cpu}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase shell UPPER_SNAKE "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/deployment.yaml")
  echo "$result" | grep -q '\${VENDOR_ENVOY_GATEWAY/REPLICAS}'
  echo "$result" | grep -q '\${VENDOR_ENVOY_GATEWAY/MEMORY}'
  echo "$result" | grep -q '\${VENDOR_ENVOY_GATEWAY/CPU}'
}

# =============================================================================
# Repeated tokens within a file
# =============================================================================

@test "convert-tokens-in-tree: replaces every occurrence (not just first)" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/repeats.yaml" << 'EOF'
a: ${ProjectName}
b: ${ProjectName}
c: ${ProjectName}-suffix
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  result=$(cat "$TEST_DIR/d/repeats.yaml")
  count=$(echo "$result" | grep -c "{{ ProjectName }}")
  [ "$count" -eq 3 ]
  ! echo "$result" | grep -q '\${ProjectName}'
}

# =============================================================================
# Multiple files
# =============================================================================

@test "convert-tokens-in-tree: processes nested directory structure" {
  mkdir -p "$TEST_DIR/d/sub/deeper"
  cat > "$TEST_DIR/d/top.yaml" << 'EOF'
top: ${TopVar}
EOF
  cat > "$TEST_DIR/d/sub/mid.yaml" << 'EOF'
mid: ${MidVar}
EOF
  cat > "$TEST_DIR/d/sub/deeper/deep.yaml" << 'EOF'
deep: ${DeepVar}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q "{{ TopVar }}" "$TEST_DIR/d/top.yaml"
  grep -q "{{ MidVar }}" "$TEST_DIR/d/sub/mid.yaml"
  grep -q "{{ DeepVar }}" "$TEST_DIR/d/sub/deeper/deep.yaml"
}

@test "convert-tokens-in-tree: leaves untouched files alone" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/with-tokens.yaml" << 'EOF'
a: ${SomeToken}
EOF
  cat > "$TEST_DIR/d/no-tokens.yaml" << 'EOF'
plain: content
EOF
  before_no_tokens=$(cat "$TEST_DIR/d/no-tokens.yaml")
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q "{{ SomeToken }}" "$TEST_DIR/d/with-tokens.yaml"
  after_no_tokens=$(cat "$TEST_DIR/d/no-tokens.yaml")
  [ "$before_no_tokens" = "$after_no_tokens" ]
}

# =============================================================================
# Trailing newline preservation
# =============================================================================

@test "convert-tokens-in-tree: preserves trailing newline when input has one" {
  mkdir -p "$TEST_DIR/d"
  printf 'value: %s\n' '${Token}' > "$TEST_DIR/d/file.yaml"
  # Confirm the input ends with newline
  [ "$(tail -c1 "$TEST_DIR/d/file.yaml" | od -An -c | tr -d ' ')" = '\n' ]
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  # Output must still end with newline
  [ "$(tail -c1 "$TEST_DIR/d/file.yaml" | od -An -c | tr -d ' ')" = '\n' ]
}

@test "convert-tokens-in-tree: preserves no-trailing-newline when input has none" {
  mkdir -p "$TEST_DIR/d"
  printf 'value: %s' '${Token}' > "$TEST_DIR/d/file.yaml"
  # Confirm the input does NOT end with newline
  [ "$(tail -c1 "$TEST_DIR/d/file.yaml" | od -An -c | tr -d ' ')" = '}' ]
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  # Output must still NOT end with newline
  [ "$(tail -c1 "$TEST_DIR/d/file.yaml" | od -An -c | tr -d ' ')" = '}' ]
}

# =============================================================================
# Round-trip: convert and back
# =============================================================================

@test "convert-tokens-in-tree: round-trip shell PascalCase -> mustache UPPER_SNAKE -> shell PascalCase is identity" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${ProjectName}
b: ${MaxHeapSize}
c: ${VendorEnvoyGateway/Cpu}
EOF
  before=$(cat "$TEST_DIR/d/file.yaml")
  run "$CONVERT_SCRIPT" shell PascalCase mustache UPPER_SNAKE "d"
  [ "$status" -eq 0 ]
  run "$CONVERT_SCRIPT" mustache UPPER_SNAKE shell PascalCase "d"
  [ "$status" -eq 0 ]
  after=$(cat "$TEST_DIR/d/file.yaml")
  [ "$before" = "$after" ]
}

# =============================================================================
# Output messaging
# =============================================================================

@test "convert-tokens-in-tree: reports per-file replacements" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}
b: ${Two}
c: ${One}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Converted 3 token instances in file.yaml"
  echo "$output" | grep -q "Total replacements: 3"
}

# =============================================================================
# Audit trail under OUTPUT_SUB_PATH
# =============================================================================

# Helper: derive the slug for a target dir as the script does.
slug_for() { echo "$1" | tr '/:' '__'; }

@test "convert-tokens-in-tree: leaves mapping.tsv under OUTPUT_SUB_PATH" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}
b: ${Two}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  local slug
  slug=$(slug_for "d")
  local slot="${OUTPUT_SUB_PATH}/convert-tokens-in-tree/token-mappings/${slug}-0"
  [ -d "${slot}" ]
  [ -f "${slot}/mapping.tsv" ]
  # Two tokens, both with a tab separator, mapped from shell ${X} to mustache form.
  [ "$(wc -l < "${slot}/mapping.tsv" | tr -d ' ')" = "2" ]
  awk -F'\t' '$1 == "${One}" { found = 1 } END { exit found ? 0 : 1 }' "${slot}/mapping.tsv"
  awk -F'\t' '$1 == "${Two}" { found = 1 } END { exit found ? 0 : 1 }' "${slot}/mapping.tsv"
  awk -F'\t' '$2 ~ /\{\{[[:space:]]*One[[:space:]]*\}\}/ { found = 1 } END { exit found ? 0 : 1 }' "${slot}/mapping.tsv"
}

@test "convert-tokens-in-tree: writes target-dir, from-scheme, to-scheme pointers" {
  mkdir -p "$TEST_DIR/d"
  echo 'a: ${One}' > "$TEST_DIR/d/file.yaml"
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  local slug
  slug=$(slug_for "d")
  local slot="${OUTPUT_SUB_PATH}/convert-tokens-in-tree/token-mappings/${slug}-0"
  [ "$(cat "${slot}/target-dir")" = "d" ]
  [ "$(cat "${slot}/from-scheme")" = "shell-PascalCase" ]
  [ "$(cat "${slot}/to-scheme")" = "mustache-PascalCase" ]
}

@test "convert-tokens-in-tree: replacements-by-file.tsv records every touched file with counts" {
  mkdir -p "$TEST_DIR/d/sub"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}
b: ${Two}
c: ${One}
EOF
  echo 'd: ${Two}' > "$TEST_DIR/d/sub/nested.yaml"
  echo 'no tokens here' > "$TEST_DIR/d/untouched.txt"
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  local slug
  slug=$(slug_for "d")
  local rbf="${OUTPUT_SUB_PATH}/convert-tokens-in-tree/token-mappings/${slug}-0/replacements-by-file.tsv"
  [ -f "${rbf}" ]
  awk -F'\t' '$1 == "file.yaml" && $2 == "3" { found = 1 } END { exit found ? 0 : 1 }' "${rbf}"
  awk -F'\t' '$1 == "sub/nested.yaml" && $2 == "1" { found = 1 } END { exit found ? 0 : 1 }' "${rbf}"
  [[ "$(cat "${rbf}")" != *"untouched.txt"* ]] || return 1
}

@test "convert-tokens-in-tree: second invocation against same tree lands at -1" {
  mkdir -p "$TEST_DIR/d"
  echo 'a: ${One}' > "$TEST_DIR/d/file.yaml"
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  # Re-prime the file so the second pass has something to convert.
  echo 'a: ${One}' > "$TEST_DIR/d/file.yaml"
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  local slug
  slug=$(slug_for "d")
  local base="${OUTPUT_SUB_PATH}/convert-tokens-in-tree/token-mappings"
  [ -d "${base}/${slug}-0" ]
  [ -d "${base}/${slug}-1" ]
}

@test "convert-tokens-in-tree: same-scheme no-op leaves no audit dir" {
  mkdir -p "$TEST_DIR/d"
  echo 'a: ${One}' > "$TEST_DIR/d/file.yaml"
  run "$CONVERT_SCRIPT" shell PascalCase shell PascalCase "d"
  [ "$status" -eq 0 ]
  [ ! -d "${OUTPUT_SUB_PATH}/convert-tokens-in-tree" ]
}

teardown() {
  dump_bats_result
}

# =============================================================================
# Context-root-relative target contract
# =============================================================================

@test "convert-tokens-in-tree: rejects absolute target directory" {
  mkdir -p "$TEST_DIR/d"
  echo 'a: ${One}' > "$TEST_DIR/d/file.yaml"
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "$TEST_DIR/d"
  [ "$status" -ne 0 ]
  assert_output_contains "must be relative"
}

@test "convert-tokens-in-tree: rejects target directory with dot-dot segments" {
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d/../d"
  [ "$status" -ne 0 ]
  assert_output_contains "must not contain"
}

# =============================================================================
# DoNotConvert markers - protection
# =============================================================================

@test "convert-tokens-in-tree: bare DoNotConvert protects every token on its line" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
plain: ${One}
both: ${SomeToken}-${OtherToken} # DoNotConvert
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q "plain: {{ One }}" "$TEST_DIR/d/file.yaml"
  grep -q 'both: \${SomeToken}-\${OtherToken} # DoNotConvert' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvert with a specifier protects only the named token" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
some: ${SomeToken}-${OtherToken} # DoNotConvert: ${OtherToken}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  # The named token survives in the payload AND in the marker text itself.
  grep -q 'some: {{ SomeToken }}-\${OtherToken} # DoNotConvert: \${OtherToken}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvert with a comma-separated specifier protects each named token" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}-${Two}-${Three} # DoNotConvert: ${One},${Three}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${One}-{{ Two }}-\${Three} # DoNotConvert: \${One},\${Three}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertAbove protects the line above and its own line" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
above: ${AboveTok}
# DoNotConvertAbove
after: ${AfterTok}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'above: \${AboveTok}' "$TEST_DIR/d/file.yaml"
  grep -q "after: {{ AfterTok }}" "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertAbove with a single specifier protects only that token" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
above: ${One}-${Two}
# DoNotConvertAbove: ${One}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'above: \${One}-{{ Two }}' "$TEST_DIR/d/file.yaml"
  grep -q '# DoNotConvertAbove: \${One}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertAbove with a comma-separated specifier protects each named token" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
above: ${One}-${Two}-${Three}
# DoNotConvertAbove: ${One},${Three}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'above: \${One}-{{ Two }}-\${Three}' "$TEST_DIR/d/file.yaml"
  grep -q '# DoNotConvertAbove: \${One},\${Three}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: bare DoNotConvertBelow protects every token on the line below" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertBelow
below: ${One}-${Two}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'below: \${One}-\${Two}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertBelow with a specifier leaves the marker text intact" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertBelow: ${BelowTok}
below: ${BelowTok}-${AlsoHere}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  # Marker lines are excluded from conversion wholesale so they keep pointing
  # at what they were written to point at.
  grep -q '# DoNotConvertBelow: \${BelowTok}' "$TEST_DIR/d/file.yaml"
  grep -q 'below: \${BelowTok}-{{ AlsoHere }}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertBelow with a comma-separated specifier protects each named token" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertBelow: ${One},${Three}
below: ${One}-${Two}-${Three}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'below: \${One}-{{ Two }}-\${Three}' "$TEST_DIR/d/file.yaml"
  grep -q '# DoNotConvertBelow: \${One},\${Three}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: specifier lists tolerate whitespace around entries" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}-${Two}-${Three} # DoNotConvert:  ${One} , ${Three}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${One}-{{ Two }}-\${Three}' "$TEST_DIR/d/file.yaml"
}

# --- DoNotConvertLines: every list shape ---

@test "convert-tokens-in-tree: DoNotConvertLines with a single bare line number" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 2
a: ${One}-${Two}
b: ${Three}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${One}-\${Two}' "$TEST_DIR/d/file.yaml"
  grep -q "b: {{ Three }}" "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertLines with several bare line numbers" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 2,3
a: ${One}
b: ${Two}
c: ${Three}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${One}' "$TEST_DIR/d/file.yaml"
  grep -q 'b: \${Two}' "$TEST_DIR/d/file.yaml"
  grep -q "c: {{ Three }}" "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertLines with a single line:token entry" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 2:${One}
a: ${One}-${Two}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${One}-{{ Two }}' "$TEST_DIR/d/file.yaml"
  grep -q '# DoNotConvertLines: 2:\${One}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertLines with several line:token entries" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 2:${One},3:${Three}
a: ${One}-${Two}
b: ${Three}-${Four}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${One}-{{ Two }}' "$TEST_DIR/d/file.yaml"
  grep -q 'b: \${Three}-{{ Four }}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertLines takes bare numbers and line:token entries" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 2,3:${Second}
first: ${First}
mixed: ${Second}-${Third}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'first: \${First}' "$TEST_DIR/d/file.yaml"
  grep -q 'mixed: \${Second}-{{ Third }}' "$TEST_DIR/d/file.yaml"
  grep -q '# DoNotConvertLines: 2,3:\${Second}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertLines takes line:token before a bare number" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 2:${Second},3
mixed: ${Second}-${Third}
whole: ${Fourth}-${Fifth}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'mixed: \${Second}-{{ Third }}' "$TEST_DIR/d/file.yaml"
  grep -q 'whole: \${Fourth}-\${Fifth}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: DoNotConvertLines tolerates whitespace around entries" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines:  2 , 3:${Third}
a: ${One}-${Two}
b: ${Third}-${Fourth}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${One}-\${Two}' "$TEST_DIR/d/file.yaml"
  grep -q 'b: \${Third}-{{ Fourth }}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: a marker may point at a token in a foreign delimiter style" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
foreign: {{ ShippedAsMustache }}
# DoNotConvertAbove
ours: ${Ours}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase helm PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q "foreign: {{ ShippedAsMustache }}" "$TEST_DIR/d/file.yaml"
  grep -q "ours: {{ .Values.Ours }}" "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: unmarked trees leave no do-not-convert audit file" {
  mkdir -p "$TEST_DIR/d"
  echo 'a: ${One}' > "$TEST_DIR/d/file.yaml"
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  local slug
  slug=$(slug_for "d")
  [ ! -f "${OUTPUT_SUB_PATH}/convert-tokens-in-tree/token-mappings/${slug}-0/do-not-convert.tsv" ]
}

@test "convert-tokens-in-tree: records every protection in the audit trail" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One} # DoNotConvert
b: ${Two}-${Three} # DoNotConvert: ${Two}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  local slug
  slug=$(slug_for "d")
  local excl="${OUTPUT_SUB_PATH}/convert-tokens-in-tree/token-mappings/${slug}-0/do-not-convert.tsv"
  [ -f "${excl}" ]
  awk -F'\t' '$1 == "file.yaml" && $2 == "1" && $3 == "*" { found = 1 } END { exit found ? 0 : 1 }' "${excl}"
  awk -F'\t' '$1 == "file.yaml" && $2 == "2" && $3 == "${Two}" { found = 1 } END { exit found ? 0 : 1 }' "${excl}"
  assert_output_contains "DoNotConvert markers found: 2 protections across 1 file"
}

# =============================================================================
# DoNotConvert markers - stale markers fail the build
# =============================================================================

@test "convert-tokens-in-tree: fails on a line number that does not exist" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 99
a: ${One}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "which does not exist"
}

@test "convert-tokens-in-tree: fails on a named token that is not on the target line" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One} # DoNotConvert: ${Nope}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "is not present on"
}

@test "convert-tokens-in-tree: fails when the target line holds no token-shaped content" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}
plain: value # DoNotConvert
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "holds no token-shaped content"
}

@test "convert-tokens-in-tree: fails on DoNotConvertAbove on the first line" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertAbove
a: ${One}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "has no line above it"
}

@test "convert-tokens-in-tree: fails on DoNotConvertBelow on the last line" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}
# DoNotConvertBelow
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "has no line below it"
}

@test "convert-tokens-in-tree: fails on a second DoNotConvertLines marker in one file" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertLines: 3
# DoNotConvertLines: 3
a: ${One}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "at most one is allowed"
}

@test "convert-tokens-in-tree: a token named after the marker is not a marker" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${DoNotConvertMe}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q "a: {{ DoNotConvertMe }}" "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: a real marker is still found alongside a token named after it" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${DoNotConvertMe}-${Other} # DoNotConvert: ${DoNotConvertMe}
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -eq 0 ]
  grep -q 'a: \${DoNotConvertMe}-{{ Other }} # DoNotConvert: \${DoNotConvertMe}' "$TEST_DIR/d/file.yaml"
}

@test "convert-tokens-in-tree: fails on an unrecognised DoNotConvert marker" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One} # DoNotConvertSomething
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "unrecognised DoNotConvert marker"
}

@test "convert-tokens-in-tree: fails on more than one marker on a line" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One}
b: ${Two} # DoNotConvert DoNotConvertAbove
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "more than one DoNotConvert marker"
}

@test "convert-tokens-in-tree: fails on a specifier that is not a token reference" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
a: ${One} # DoNotConvert: One
EOF
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "is not a token reference"
}

@test "convert-tokens-in-tree: reports every stale marker in one run and converts nothing" {
  mkdir -p "$TEST_DIR/d"
  cat > "$TEST_DIR/d/file.yaml" << 'EOF'
# DoNotConvertAbove
a: ${One}
b: ${Two} # DoNotConvert: ${Nope}
EOF
  before=$(cat "$TEST_DIR/d/file.yaml")
  run "$CONVERT_SCRIPT" shell PascalCase mustache PascalCase "d"
  [ "$status" -ne 0 ]
  assert_output_contains "has no line above it"
  assert_output_contains "is not present on"
  assert_output_contains "Found 2 DoNotConvert marker problems"
  [ "$before" = "$(cat "$TEST_DIR/d/file.yaml")" ]
}
