#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

bats_require_minimum_version 1.5.0

load helpers

setup() {
  setup_mock_git
}

teardown() {
  dump_bats_result
  cleanup_test_repo "$TEST_REPO"
  cleanup_mock_git
}

create_note_test_repo() {
  TEST_REPO=$(create_test_repo)
  cd "$TEST_REPO"
  export CURRENT_BRANCH="feature-test-branch"
  export MERGE_CANDIDATE_CREATOR="testuser"
}

@test "writes note with branch and creator" {
  create_note_test_repo

  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -eq 0 ]

  local note
  note=$(git notes --ref=kaptain-change-source show HEAD)
  [[ "$note" == *"merge-candidate-branch: feature-test-branch"* ]] || return 1
  [[ "$note" == *"merge-candidate-creator: testuser"* ]] || return 1
}

@test "writes note without creator when not set" {
  create_note_test_repo
  unset MERGE_CANDIDATE_CREATOR

  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -eq 0 ]

  local note
  note=$(git notes --ref=kaptain-change-source show HEAD)
  [[ "$note" == *"merge-candidate-branch: feature-test-branch"* ]] || return 1
  [[ "$note" != *"merge-candidate-creator"* ]] || return 1
}

@test "fails when CURRENT_BRANCH not set" {
  create_note_test_repo
  unset CURRENT_BRANCH

  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -ne 0 ]
  assert_output_contains "CURRENT_BRANCH"
}

@test "overwrites existing note with force flag" {
  create_note_test_repo

  # Write first note
  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -eq 0 ]

  # Write again with different branch
  export CURRENT_BRANCH="updated-branch"
  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -eq 0 ]

  local note
  note=$(git notes --ref=kaptain-change-source show HEAD)
  [[ "$note" == *"merge-candidate-branch: updated-branch"* ]] || return 1
}

@test "skips when CHANGE_SOURCE_NOTE_ENABLED is false" {
  create_note_test_repo
  export CHANGE_SOURCE_NOTE_ENABLED="false"

  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -eq 0 ]
  assert_output_contains "Change source notes disabled"

  run git notes --ref=kaptain-change-source show HEAD
  [ "$status" -ne 0 ]
}

@test "writes note when CHANGE_SOURCE_NOTE_ENABLED is true" {
  create_note_test_repo
  export CHANGE_SOURCE_NOTE_ENABLED="true"

  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -eq 0 ]

  local note
  note=$(git notes --ref=kaptain-change-source show HEAD)
  [[ "$note" == *"merge-candidate-branch: feature-test-branch"* ]] || return 1
}

@test "succeeds when push fails" {
  create_note_test_repo

  # No remote configured, push will fail but script should succeed
  run "$SCRIPTS_DIR/change-source-note-write"
  [ "$status" -eq 0 ]
  assert_output_contains "Note written to"
}
