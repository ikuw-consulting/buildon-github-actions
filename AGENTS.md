# buildon-github-actions

Reusable GitHub Actions library wrapping `kaptain-build-scripts` for CI/CD pipelines with quality enforcement and automatic versioning.

## Rules

0. Never use a tool from a docker image when a local one is available, and never ever use `:latest` on any docker image.
1. No git operations that change state locally or remotely in this repo: no fetch, pull, push, commit, add, rm, mv, stash, checkout of a different branch, etc. Use normal commands to manipulate the working tree only.
2. Only run targetted local bats tests for `src/scripts` and `src/tests` changes. Full test runs using `.github/bin/run-tests.bash` take a long time and also rebuild all generated files.
3. For changes that touch only `src/action-templates/`, `src/steps-common/`, `src/workflow-templates/`, or `src/inputs/`, the user must run `src/bin/assemble-workflows.bash` to regen before committing.
4. Do not run `src/bin/assemble-workflows.bash` for non-script changes until the user has reviewed and approved. They will usually run it themselves. Regenerating before approval wastes cycles and muddies diffs.
5. `examples/` and most of `README.md` are not currently generated (but should be). Maintain them alongside any related script, template, or action change.
6. Always re-read files before editing them with bash commands. Don't rely on cached content — the user may have made manual changes.
7. Before running `src/bin/assemble-workflows.bash`, check it isn't already running (`ps aux | grep assemble-workflows`).

## Project Structure

```
.github/
  bin/run-tests.bash                       # Full test suite runner (10 min — don't run by default)
  workflows/                               # Generated: reusable workflows callable by consumers
src/
  action-templates/                        # Source: per-action templates with INJECT-INPUT markers
  actions/                                 # Generated: composite actions wrapping scripts for GitHub
  bin/assemble-workflows.bash              # Assembler: templates + steps-common + inputs → actions + workflows
  inputs/                                  # Source: input definitions injected into action templates
  schemas/                                 # Source: JSON schemas (KaptainPM.yaml, manifests contract, etc.)
  scripts/
    defaults/                              # Default env var values
    generators/                            # Kubernetes manifest generators
    lib/                                   # Shared bash libraries (sourced by other scripts)
    main/                                  # CI entrypoint scripts (run from action.yaml)
    plugins/                               # Pluggable providers (artifact-exists, repo providers, etc.)
    reference/                             # Local-mode equivalents of workflow templates (same execution order)
    util/                                  # One-shot utilities
  steps-common/                            # Source: reusable step blocks injected into workflow templates
  test/                                    # BATS tests + mock helpers (helpers.bash)
  workflow-templates/                      # Source: per-workflow templates with INJECT and INJECT-COMMON markers
examples/                                  # Hand-maintained usage examples for consumers
docs/                                      # Generated: per-workflow input docs
```

## Generation Pipeline

The repo has three source layers that assemble into two generated layers.

### Source (hand-edited)

- `src/action-templates/<name>.yaml` — one per composite action, with `# INJECT-INPUT:` markers.
- `src/inputs/<group>.yaml` — named groups of inputs to inject into action templates.
- `src/steps-common/<name>.yaml` — reusable step blocks (setup, post-build hooks, generators).
- `src/workflow-templates/<name>.yaml` — one per reusable workflow, with `# INJECT:` and `# INJECT-COMMON:` markers.
- `src/scripts/**` — all CI-agnostic logic. No `GITHUB_*` env vars, no `gh` CLI calls. The action layer maps GitHub context onto the generic env vars the scripts expect.

### Generated (never hand-edit)

- `src/actions/<name>/action.yaml` — assembled from action template + inputs.
- `.github/workflows/*.yaml` — assembled from workflow template + steps-common + action inputs.
- `docs/` — secrets and outputs per workflow
- `README.md` but only sections marked by comments like `<!-- WORKFLOW-DOCS-START -->`
- `examples/` but only the workflow version references

### INJECT markers

| Marker | Used in | Effect |
|---|---|---|
| `# INJECT-INPUT: <group>` | action templates | Inline an input group from `src/inputs/<group>.yaml` |
| `# INJECT-OUTPUTS: <script> <step-id>` | action templates | Declare every output `src/scripts/main/<script>` can export (its `MAPPINGS` table plus literal `output_var` names), each read from the step with that id |
| `# INJECT: <step-name>` | workflow templates | Inline a step block from `src/steps-common/<step-name>.yaml` |
| `# INJECT-COMMON: <name>` | workflow templates | Inline a common fragment |

### Reference scripts = workflow templates

`src/workflow-templates/<name>.yaml` are GH actions equivalents of `src/scripts/reference/<name>` They run the same steps in the same order — one driven by the GitHub Actions runner, one by the user's shell or other build system without a step concept/structure. When editing one, consider whether the other needs a matching change.

### Inlined-step drift

`spec-check-filter-release` has steps inlined in the workflow template rather than pulled from `steps-common/`. Watch for drift when updating the shared steps.

## Scripts — CI portability

Scripts under `src/scripts/` must not reference GitHub-specific constructs:
- No `GITHUB_*` env vars directly (actions set generic vars like `PR_BRANCH`, `TARGET_BRANCH`).
- No `gh` CLI calls in the `main/` entrypoints — isolate any GitHub API use to a thin wrapper that can be stubbed.
- Output variables go through `src/scripts/lib/output-var.bash` (writes `name=value` to `$GITHUB_OUTPUT`). Composite-action wrappers must declare an `outputs:` block mapping to the inner step's outputs — inner-step `$GITHUB_OUTPUT` writes do NOT propagate automatically.

## Kaptain Deployment Model

This repo is part of the CI/CD build side. The broader Kaptain system has three layers, all unified under a single `KaptainPM.yaml` schema discriminated by `kind:`:

- **App** — an individual application with its own repo. Build pipelines publish manifests via repo providers (docker image, GitHub release, etc.).
- **Product** — deployable units that reference and aggregate  manifest bundles with a unique version.
- **Environment** — aggregate of apps/bundles/products that builds a deploy image that does the deployment..

## Key Design Decisions

- Scripts use generic env vars (`PR_BRANCH`, `TARGET_BRANCH`); actions map GitHub context onto them.
- Exit code 42 for infrastructure failures (missing target branch, etc.).
- Bit flags for quality-check failures: 1=bad branch, 2=bad commit, 4=merge commit, 8=not rebased, 16=bad target.
- Composite-action outputs must be explicitly declared and mapped — they do not auto-propagate from inner steps.

## Key Variables

- `OUTPUT_SUB_PATH` — where generated manifests and artefacts land under `kaptain-out/`.
- `IMAGE_BUILD_COMMAND` — `docker` or `podman`. Plugins that invoke the container tooling must use this rather than hard-coding either.
- `DOCKER_TARGET_REGISTRY` / `DOCKER_TARGET_NAMESPACE` — used by docker ref expansion in the artifact and artifact-exists plugins.

## Code Style

- Use `.yaml`, not `.yml`.
- All text files end with a trailing newline.
- Prefer single-use inline code over factored helpers. Abstract only when there's a second caller.
- Bash portability — macOS ships bash 3.2, GitHub Actions ubuntu-24.04 has bash 5.x:
  - `((count++))` when `count` is 0 returns exit 1 in bash 5.x and kills the script under `set -e`. Use `count=$((count + 1))` instead.
  - `"${array[@]}"` on an empty array can fail as unbound under `set -u` in older bash. Use `"${array[@]+"${array[@]}"}"` if needed.

## Testing

```bash
cd src/test
bats <specific-file>.bats
```

- Run specific test files only. Never run the full suite (`.github/bin/run-tests.bash`) — it takes ~10 minutes and blocks when given args.
- Tests only cover `src/scripts/`. They do not cover `src/actions/`, `src/steps-common/`, or `src/workflow-templates/` — for those, run `src/bin/assemble-workflows.bash` after approval.
- Mock docker/podman via `src/test/helpers.bash::setup_mock_docker`. Gate behavior with `MOCK_DOCKER_MANIFEST_EXISTS`, `MOCK_DOCKER_PULL_FAILS`, etc.
- Never run the same `.bats` file in parallel with itself — fixtures share state.
- Shellcheck runs as part of the full suite. Match its flags locally: `--external-sources` and the specific `--enable=` flags from `.github/bin/run-tests.bash`.
- Targeted bats runs miss the full suite's repo-wide checks, and CI has failed on them more than once. Before calling a change done:
  - New or edited `.bats` files: run `.github/bin/check-bats-assertions.bash`. A bare `[[ ... ]]` assertion is ignored by `set -e` on bash 3.2; append `|| return 1`.
  - Any change under `src/scripts/`: also run `.github/bin/check-token-patterns.bash` and `.github/bin/check-schema-validator-calls.bash`.
  - Anything added to `src/scripts/defaults/*.bash`: every `hook-*` script that sources that file must export it (`hook-*.bats` "exports all inputs from sourced defaults"). Defaults files are user inputs only. An internal switch is read with `${VAR:-default}` at its use site, not declared in defaults.
  - Changed a defaults file or `src/scripts/lib/`: run every `src/test/hook-*.bats` as well as the obvious suites.

## Bugs Found During Implementation

If you notice a bug while working on a different change, stop and raise it separately. Don't mix it into the current work. The user's typical flow:

1. Stash current changes.
2. Fix the bug on a clean base.
3. Reapply the original changes on top.

Clean diffs make review tractable.

## Skills

- **`branchout` skill** (installed from `branchout-skills`) — always load this so you can work correctly in this ecosystem.
- **Kaptain skills set** at `kaptain/kaptain-skills/skills/` in the kaptain branchout root — prototype-level. Covers kaptain-architecture, kaptain-build, kaptain-build-gh-actions, kaptain-build-quality-checks, kaptain-build-kaptainpm, etc. Useful here but not yet stable.

## Branchout Roots

This repo lives in one of several Branchout projections. Relevant ones:

| Projection | Purpose |
|---|---|
| `kaptain` | This projection. All kaptain build/deploy code, schemas, examples, vendor packages, and test fixtures, etc |
| `kaptain-sample | A suite of fake projects that approximately match a real system. |
| `kaptain-test` | A suite of test projects to validate the scripts and  GH aspects of the system against, locally, in PR, and after merge. |
| `branchout-project` | `~/projects/branchout-project/` | Branchout's own projection. Hosts `branchout-skills` (where the `branchout` skill is developed) and the branchout CLI itself. |

## License Headers

- Scripts and code: `SPDX-License-Identifier: MIT`
- Docs (this file, `*.md`): `SPDX-License-Identifier: CC-BY-SA-4.0`

Both carry `Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)`. See `LICENSE.md` for the full terms.
