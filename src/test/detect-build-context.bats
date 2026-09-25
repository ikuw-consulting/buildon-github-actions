#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Kaptain contributors (Fred Cooke)
#
# Tests for lib/detect-build-context.bash target derivation: the local
# guesser. Each test builds a scratch repo (file:// bare origin) in the
# state under test and sources the lib in a clean bash, asserting the
# pretty vars and the TARGET_REF marker.

bats_require_minimum_version 1.5.0

load helpers

DETECT="$LIB_DIR/detect-build-context.bash"

setup() {
  WORK=$(create_test_dir "detect-build-context")
  ORIGIN="${WORK}/origin.git"
  REPO="${WORK}/repo"
  git init --bare -q "${ORIGIN}"
  git clone -q "${ORIGIN}" "${REPO}" 2>/dev/null
  cd "${REPO}"
  git config user.email test@test && git config user.name test
  git checkout -q -b main
  echo x > README.md && git add . && git commit -qm initial
  git push -qu origin main 2>/dev/null
  # Match a real clone: remote HEAD known locally
  git remote set-head origin main
  # The lib respects incoming values - tests must start clean of them
  unset DEFAULT_BRANCH TARGET_BRANCH RELEASE_BRANCH TARGET_REF UPSTREAM_BRANCH \
        KAPTAIN_BRANCH_OVERRIDE KAPTAIN_LOCAL_RELEASE CURRENT_BRANCH 2>/dev/null || true
}

teardown() {
  dump_bats_result
}

# Source the lib in a clean bash and print the derived values
derive() {
  run bash -c "
    log_error() { echo \"ERROR: \$*\" >&2; }
    source '${DETECT}'
    echo \"TARGET=\${TARGET_BRANCH:-}|REF=\${TARGET_REF:-}|RELEASE=\${RELEASE_BRANCH:-}|DEFAULT=\${DEFAULT_BRANCH:-}\"
  "
}

@test "on main: targets origin/main with qualified ref, all three equal" {
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=origin/main|REF=refs/remotes/origin/main|RELEASE=origin/main|DEFAULT=origin/main"* ]]
}

@test "release-line branch with pushed counterpart targets its own line" {
  git checkout -q -b main-1.34
  git push -qu origin main-1.34 2>/dev/null
  git config --unset "branch.main-1.34.remote"
  git config --unset "branch.main-1.34.merge"
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=origin/main-1.34|REF=refs/remotes/origin/main-1.34"* ]]
}

@test "release-line branch UNPUSHED still targets its own line (warn+skip downstream)" {
  git checkout -q -b main-1.35
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=origin/main-1.35|REF=refs/remotes/origin/main-1.35"* ]]
}

@test "feature branch with no config guesses origin/main via remote HEAD" {
  git checkout -q -b feature/omg
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=origin/main|REF=refs/remotes/origin/main"* ]]
}

@test "push -u feature branch: upstream config respected verbatim" {
  git checkout -q -b feature/omg
  git push -qu origin feature/omg 2>/dev/null
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=origin/feature/omg|REF=refs/remotes/origin/feature/omg"* ]]
}

@test "set-upstream-to a different line is the declared target" {
  git checkout -q -b main-1.34 && git push -q origin main-1.34 2>/dev/null && git checkout -q main
  git checkout -q -b feature/omg
  git branch -q --set-upstream-to=origin/main-1.34
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=origin/main-1.34|REF=refs/remotes/origin/main-1.34"* ]]
}

@test "tag upstream: pretty name is the plain tag, ref is refs/tags" {
  git tag 1.34.4 && git push -q origin 1.34.4 2>/dev/null
  git checkout -q -b feature/omg
  git config branch.feature/omg.remote .
  git config branch.feature/omg.merge refs/tags/1.34.4
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=1.34.4|REF=refs/tags/1.34.4"* ]]
}

@test "KAPTAIN_BRANCH_OVERRIDE bare name: remote-prefixed, all three set" {
  git checkout -q -b feature/omg
  export KAPTAIN_BRANCH_OVERRIDE="main-1.34"
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=origin/main-1.34|REF=refs/remotes/origin/main-1.34|RELEASE=origin/main-1.34|DEFAULT=origin/main-1.34"* ]]
}

@test "KAPTAIN_BRANCH_OVERRIDE refs/tags: pretty tag plus tag ref" {
  export KAPTAIN_BRANCH_OVERRIDE="refs/tags/1.34.4"
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=1.34.4|REF=refs/tags/1.34.4"* ]]
}

@test "KAPTAIN_LOCAL_RELEASE: none of the three vars are written" {
  export KAPTAIN_LOCAL_RELEASE="true"
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=|REF=|RELEASE=|DEFAULT="* ]]
}

@test "detached HEAD is a hard error with guidance" {
  git checkout -q --detach HEAD
  derive
  [ "$status" -ne 0 ]
  [[ "$output" == *"Detached HEAD"* ]]
}

@test "no remotes: bootstrap warning, still derives an unresolvable target" {
  git remote remove origin
  git config --unset branch.main.remote 2>/dev/null || true
  git config --unset branch.main.merge 2>/dev/null || true
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"No git remotes configured"* ]] || return 1
  [[ "$output" == *"TARGET=origin/main|REF=refs/remotes/origin/main"* ]]
}

@test "env override of TARGET_BRANCH gets no stale TARGET_REF marker" {
  export TARGET_BRANCH="somewhere/else"
  derive
  [ "$status" -eq 0 ]
  [[ "$output" == *"TARGET=somewhere/else|REF=|"* ]]
}

@test "not a git repository at all: full bootstrap defaults, env contract complete" {
  # Must be OUTSIDE the checkout: create_test_dir nests inside the repo and
  # git would walk up to it. Plain mktemp -d: GNU and BSD disagree on -t.
  NOREPO=$(mktemp -d)
  cd "${NOREPO}"
  run bash -c "
    log_error() { echo \"ERROR: \$*\" >&2; }
    source '${DETECT}'
    echo \"CB=\${CURRENT_BRANCH}|T=\${TARGET_BRANCH}|RN=\${REPOSITORY_NAME}|RO=\${REPOSITORY_OWNER}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not a git repository"* ]] || return 1
  [[ "$output" == *"CB=main|T=origin/main|RN=$(basename "${NOREPO}")|RO="* ]]
}
