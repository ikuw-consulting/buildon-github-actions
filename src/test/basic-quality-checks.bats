#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

bats_require_minimum_version 1.5.0

load helpers

setup() {
  export DEFAULT_BRANCH=main
  export TARGET_BRANCH=main
  export CURRENT_BRANCH=test-branch
  export BUILD_KIND=basic-quality-checks
}

teardown() {
  dump_bats_result
  :
}

@test "passes for clean feature branch" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
  assert_output_contains "All quality checks passed"
}

@test "fails when TARGET_BRANCH not set (non-PR context)" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  unset TARGET_BRANCH
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -ne 0 ]
  assert_output_contains "TARGET_BRANCH"
  assert_output_contains "Is required"
}

@test "fails when run on release branch" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=main
  export TARGET_BRANCH=feature-branch
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 1 ]
  assert_output_contains "should not run on release branches"
}

@test "blocks GitHub default branch names" {
  TEST_REPO=$(clone_fixture "qc-bad-branch-name")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=testuser-patch-1
  export MERGE_CANDIDATE_CREATOR=testuser
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 2 ]
  assert_output_contains "GitHub's default naming pattern"
}

@test "allows branches with slashes by default" {
  TEST_REPO=$(clone_fixture "qc-branch-with-slash")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=feature/something
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
}

@test "blocks slashes when configured" {
  TEST_REPO=$(clone_fixture "qc-branch-with-slash")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=feature/something
  export QC_BLOCK_SLASH_CONTAINING_BRANCHES=true
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 2 ]
  assert_output_contains "contains a slash"
}

@test "blocks Update filename commits" {
  TEST_REPO=$(clone_fixture "qc-update-commit")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 4 ]
  assert_output_contains "GitHub UI default message"
}

@test "blocks Create filename commits" {
  TEST_REPO=$(clone_fixture "qc-create-commit")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 4 ]
  assert_output_contains "GitHub UI default message"
}

@test "blocks Delete filename commits" {
  TEST_REPO=$(clone_fixture "qc-delete-commit")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 4 ]
  assert_output_contains "GitHub UI default message"
}

@test "blocks merge commits" {
  TEST_REPO=$(clone_fixture "qc-merge-commit")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 8 ]
  assert_output_contains "merge commit"
}

@test "blocks unrebased branches" {
  TEST_REPO=$(clone_fixture "qc-not-rebased")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 8 ]
  assert_output_contains "not up to date"
}

@test "blocks Update with extra text (copilot style)" {
  TEST_REPO=$(clone_fixture "qc-update-copilot")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 4 ]
  assert_output_contains "GitHub UI default message"
}

@test "accumulates multiple errors with bit flags" {
  TEST_REPO=$(clone_fixture "qc-multiple-issues")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=testuser-patch-1
  export MERGE_CANDIDATE_CREATOR=testuser
  run "$SCRIPTS_DIR/basic-quality-checks"
  # Should have both FLAG_BAD_BRANCH (2) and FLAG_BAD_COMMIT (4) = 6
  [ "$status" -eq 6 ]
}

@test "validates target branch in PR context" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export TARGET_BRANCH=develop
  run "$SCRIPTS_DIR/basic-quality-checks"
  # FLAG_BAD_SETUP = 16 since develop is not a release branch
  [ "$status" -ne 0 ]
  assert_output_contains "not a release branch"
}

@test "allows configured patch branches as targets" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"
  git checkout main --quiet
  git checkout -b main-1.0.x --quiet
  git checkout fix-something --quiet

  export CURRENT_BRANCH=fix-something
  export TARGET_BRANCH=main-1.0.x
  export ADDITIONAL_RELEASE_BRANCHES="main-1.0.x"
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
}

@test "blocks release branch to release branch PRs" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"
  git checkout main --quiet
  git checkout -b main-1.0.x --quiet

  export CURRENT_BRANCH=main-1.0.x
  export TARGET_BRANCH=main
  export ADDITIONAL_RELEASE_BRANCHES="main-1.0.x"
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 16 ]
  assert_output_contains "Use cherry-pick to move changes between release branches"
}

@test "blocks double hyphens by default" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=fix--something
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 2 ]
  assert_output_contains "double hyphens"
}

@test "allows double hyphens when disabled" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=fix--something
  export QC_BLOCK_DOUBLE_HYPHEN_CONTAINING_BRANCHES=false
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
}

@test "requires branch prefix when enabled" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=my-branch
  export QC_REQUIRE_CONVENTIONAL_BRANCHES=true
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 2 ]
  assert_output_contains "must start with a prefix"
}

@test "allows branch with valid prefix" {
  TEST_REPO=$(clone_fixture "qc-branch-with-slash")
  cd "$TEST_REPO"

  export CURRENT_BRANCH=feature/my-feature
  export QC_REQUIRE_CONVENTIONAL_BRANCHES=true
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
  assert_output_contains "has required prefix"
}

@test "requires conventional commits when enabled" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export QC_REQUIRE_CONVENTIONAL_COMMITS=true
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 4 ]
  assert_output_contains "does not use conventional commit format"
}

@test "blocks conventional commits when enabled" {
  TEST_REPO=$(clone_fixture "qc-conventional-commit")
  cd "$TEST_REPO"

  export QC_BLOCK_CONVENTIONAL_COMMITS=true
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 4 ]
  assert_output_contains "conventional commit format which is not allowed"
}

@test "blocks duplicate commit messages by default" {
  TEST_REPO=$(clone_fixture "qc-duplicate-commits")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 8 ]
  assert_output_contains "Duplicate commit message found 2 times"
  assert_output_contains "Fix the thing"
}

@test "allows duplicate commit messages when disabled" {
  TEST_REPO=$(clone_fixture "qc-duplicate-commits")
  cd "$TEST_REPO"

  export QC_BLOCK_DUPLICATE_COMMIT_MESSAGES=false
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
}

@test "passes when no duplicate commit messages" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
  assert_output_contains "No duplicate commit messages"
}

# =============================================================================
# Local leniency: unresolvable target -> warn and skip content checks only
# =============================================================================

@test "local: unresolvable target warns, skips content checks, name checks still run" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export BUILD_MODE=local
  export TARGET_BRANCH=origin/ghost-line
  export RELEASE_BRANCH=origin/ghost-line
  export DEFAULT_BRANCH=origin/ghost-line
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
  assert_output_contains "does not resolve locally"
  assert_output_contains "Skipped fast-forward check"
}

@test "non-local: unresolvable target stays a hard failure" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export BUILD_MODE=build_server
  export TARGET_BRANCH=origin/ghost-line
  export RELEASE_BRANCH=origin/ghost-line
  export DEFAULT_BRANCH=origin/ghost-line
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 42 ]
  assert_output_contains "not found"
}

@test "TARGET_REF marker is used verbatim for content checks" {
  TEST_REPO=$(clone_fixture "qc-clean")
  cd "$TEST_REPO"

  export BUILD_MODE=local
  export TARGET_BRANCH=origin/main
  export RELEASE_BRANCH=origin/main
  export DEFAULT_BRANCH=origin/main
  export TARGET_REF=refs/remotes/origin/main
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 0 ]
  assert_output_contains "Branch is fast-forward from target"
}

@test "local failure appends git config guidance with real branch name" {
  TEST_REPO=$(clone_fixture "qc-bad-branch-name")
  cd "$TEST_REPO"

  export BUILD_MODE=local
  export CURRENT_BRANCH=testuser-patch-1
  export MERGE_CANDIDATE_CREATOR=testuser
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 2 ]
  assert_output_contains "For local builds, configure this branch"
  assert_output_contains "git config branch.testuser-patch-1.remote"
  assert_output_contains "KAPTAIN_BRANCH_OVERRIDE"
}

@test "non-local failure stays terse - no local guidance" {
  TEST_REPO=$(clone_fixture "qc-bad-branch-name")
  cd "$TEST_REPO"

  export BUILD_MODE=build_server
  export CURRENT_BRANCH=testuser-patch-1
  export MERGE_CANDIDATE_CREATOR=testuser
  run "$SCRIPTS_DIR/basic-quality-checks"
  [ "$status" -eq 2 ]
  if [[ "$output" == *"For local builds"* ]]; then
    echo "guidance leaked into non-local output"
    return 1
  fi
}
