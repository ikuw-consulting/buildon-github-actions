#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for substitute-shell-style-token (in-place string transform API)
#
# The provider mutates a caller-supplied string buffer in place via
# indirect expansion + printf -v. Tests stage a content variable, call
# the function, then assert on the variable. No file I/O involved.

bats_require_minimum_version 1.5.0

load helpers

source "$LIB_DIR/prepare-token-name-and-value.bash"
source "$PLUGINS_DIR/token-substitution-providers/substitute-shell-style-token"

teardown() {
  dump_bats_result
  :
}

@test "substitutes exact variable name" {
  content='name: ${ProjectName}'
  substitute_shell_style_token "ProjectName" "my-app" content
  [ "$content" = "name: my-app" ]
  [ "$SUBSTITUTE_TOKEN_COUNT" -eq 1 ]
}

@test "substitutes lower-kebab token name" {
  content='name: ${project-name}'
  substitute_shell_style_token "project-name" "my-app" content
  [ "$content" = "name: my-app" ]
  [ "$SUBSTITUTE_TOKEN_COUNT" -eq 1 ]
}

@test "leaves other variables untouched" {
  content='name: ${ProjectName}
version: ${Version}'
  substitute_shell_style_token "ProjectName" "my-app" content
  [[ "$content" == *"name: my-app"* ]] || return 1
  [[ "$content" == *'version: ${Version}'* ]]
}

@test "handles values with slashes" {
  content='image: ${DockerImageName}'
  substitute_shell_style_token "DockerImageName" "org/my-image" content
  [ "$content" = "image: org/my-image" ]
}

@test "handles values with commas" {
  content='tags: ${Tags}'
  substitute_shell_style_token "Tags" "tag1,tag2,tag3" content
  [ "$content" = "tags: tag1,tag2,tag3" ]
}

@test "does not substitute partial matches" {
  content='name: ${ProjectNameExtra}'
  substitute_shell_style_token "ProjectName" "my-app" content
  [ "$content" = 'name: ${ProjectNameExtra}' ]
  [ "$SUBSTITUTE_TOKEN_COUNT" -eq 0 ]
}

@test "substitutes multiple occurrences in same buffer" {
  content='name: ${Version}
tag: ${Version}
label: ${Version}'
  substitute_shell_style_token "Version" "1.2.3" content
  [[ "$content" == *"name: 1.2.3"* ]] || return 1
  [[ "$content" == *"tag: 1.2.3"* ]] || return 1
  [[ "$content" == *"label: 1.2.3"* ]] || return 1
  [ "$SUBSTITUTE_TOKEN_COUNT" -eq 3 ]
}

@test "handles nested token path as name" {
  content='value: ${category/sub-var}'
  substitute_shell_style_token "category/sub-var" "nested-value" content
  [ "$content" = "value: nested-value" ]
}

@test "self-referential token does not cause infinite loop" {
  content='name: ${ProjectName}'
  substitute_shell_style_token "ProjectName" '${ProjectName}' content
  [ "$content" = 'name: ${ProjectName}' ]
  [ "$SUBSTITUTE_TOKEN_COUNT" -eq 1 ]
}

@test "empty value substitutes empty string" {
  content='prefix-${EmptyVar}-suffix'
  substitute_shell_style_token "EmptyVar" "" content
  [ "$content" = "prefix--suffix" ]
}

@test "preserves buffer with trailing newline" {
  content=$'with newline: ${Var}\n'
  substitute_shell_style_token "Var" "value" content
  [ "$content" = $'with newline: value\n' ]
}

@test "preserves buffer without trailing newline" {
  content='no newline: ${Var}'
  substitute_shell_style_token "Var" "value" content
  [ "$content" = "no newline: value" ]
}

# Trailing-newline handling now lives in prepare_token_name_and_value
# (called by the router before invoking the provider). These tests
# exercise that helper directly to confirm semantics survive the refactor.

@test "prepare: strips trailing newline from single-line token by default" {
  export CONFIG_VALUE_TRAILING_NEWLINE="strip-for-single-line"
  local tokens_dir
  tokens_dir=$(create_test_dir "tokens")
  printf 'my-value\n' > "$tokens_dir/SingleLine"
  cd "$tokens_dir"

  TOKEN_NAME=""; TOKEN_VALUE=""
  prepare_token_name_and_value "SingleLine"
  [ "$TOKEN_VALUE" = "my-value" ]
}

@test "prepare: preserves trailing newlines in multi-line token" {
  export CONFIG_VALUE_TRAILING_NEWLINE="strip-for-single-line"
  local tokens_dir
  tokens_dir=$(create_test_dir "tokens")
  printf 'line1\nline2\n' > "$tokens_dir/MultiLine"
  cd "$tokens_dir"

  TOKEN_NAME=""; TOKEN_VALUE=""
  prepare_token_name_and_value "MultiLine"
  [ "$TOKEN_VALUE" = $'line1\nline2\n' ]
}

@test "prepare: preserve-all keeps trailing newline on single-line" {
  export CONFIG_VALUE_TRAILING_NEWLINE="preserve-all"
  local tokens_dir
  tokens_dir=$(create_test_dir "tokens")
  printf 'my-value\n' > "$tokens_dir/SingleLine"
  cd "$tokens_dir"

  TOKEN_NAME=""; TOKEN_VALUE=""
  prepare_token_name_and_value "SingleLine"
  [ "$TOKEN_VALUE" = $'my-value\n' ]
}

@test "prepare: always-strip-one-newline strips a single trailing newline" {
  export CONFIG_VALUE_TRAILING_NEWLINE="always-strip-one-newline"
  local tokens_dir
  tokens_dir=$(create_test_dir "tokens")
  printf 'my-value\n' > "$tokens_dir/SingleLine"
  cd "$tokens_dir"

  TOKEN_NAME=""; TOKEN_VALUE=""
  prepare_token_name_and_value "SingleLine"
  [ "$TOKEN_VALUE" = "my-value" ]
}

@test "prepare: always-strip-one-newline strips exactly one of two trailing newlines" {
  export CONFIG_VALUE_TRAILING_NEWLINE="always-strip-one-newline"
  local tokens_dir
  tokens_dir=$(create_test_dir "tokens")
  printf 'my-value\n\n' > "$tokens_dir/DoubleNewline"
  cd "$tokens_dir"

  TOKEN_NAME=""; TOKEN_VALUE=""
  prepare_token_name_and_value "DoubleNewline"
  [ "$TOKEN_VALUE" = $'my-value\n' ]
}
