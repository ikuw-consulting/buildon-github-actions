#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

# assemble-workflows.bash - Generate workflow files from templates
#
# Reads templates from src/workflow-templates/ and replaces INJECT markers
# with content from src/steps-common/, writing results to .github/workflows/
#
# Chunks are written with 0-based indentation and the generator applies
# the correct indentation based on the INJECT marker's position.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEMPLATES_DIR="$REPO_ROOT/src/workflow-templates"
STEPS_DIR="$REPO_ROOT/src/steps-common"
INPUTS_DIR="$REPO_ROOT/src/inputs"
OUTPUT_DIR="$REPO_ROOT/.github/workflows"
DOCS_DIR="$REPO_ROOT/docs"
README="$REPO_ROOT/README.md"
ACTION_TEMPLATES_DIR="$REPO_ROOT/src/action-templates"
ACTIONS_DIR="$REPO_ROOT/src/actions"

# Strip SPDX header (first 3 lines: SPDX, Copyright, blank) from chunk content
strip_spdx_header() {
  tail -n +4
}

# Indent all lines of input by given prefix
indent_chunk() {
  local indent="$1"
  local first=true
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$first" == true ]]; then
      # First line: just output without extra indent (marker position provides it)
      echo "$line"
      first=false
    else
      # Subsequent lines: add indent prefix if line is non-empty
      if [[ -n "$line" ]]; then
        echo "${indent}${line}"
      else
        echo ""
      fi
    fi
  done
}

# Append && success() to if: conditions that don't already have a status check function
append_success_to_conditions() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Match lines with "if:" followed by a condition
    if [[ "$line" =~ ^([[:space:]]*if:[[:space:]]*)(.+)$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      local condition="${BASH_REMATCH[2]}"
      # Only append if no status check function already present
      if [[ ! "$condition" =~ (success|failure|always|cancelled)\(\) ]]; then
        echo "${prefix}${condition} && success()"
      else
        echo "$line"
      fi
    else
      echo "$line"
    fi
  done
}

# Parse parameter value from params string: name="value" or name='value'
parse_param() {
  local params="$1"
  local param_name="$2"
  local value=""

  # Match name="value" or name='value'
  if [[ "$params" =~ ${param_name}=\"([^\"]+)\" ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ "$params" =~ ${param_name}=\'([^\']+)\' ]]; then
    value="${BASH_REMATCH[1]}"
  fi

  echo "$value"
}

# Escape special sed replacement characters (& \ and | since | is our delimiter)
escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&\|]/\\&/g'
}

# Generate github-check-start step from template
# Uses sed for substitution (bash parameter expansion escaping differs between versions)
generate_check_start() {
  local check_name="$1"
  local check_id="$2"
  local condition="$3"
  local job_name="$4"
  local template_file="$STEPS_DIR/github-check-start.yaml"

  if [[ ! -f "$template_file" ]]; then
    echo "ERROR: Template not found: $template_file" >&2
    exit 1
  fi

  # Format check name with job prefix if available
  local full_check_name="$check_name"
  if [[ -n "$job_name" ]]; then
    full_check_name="${job_name} → ${check_name}"
  fi

  # Escape values for sed replacement
  local safe_name safe_full_name safe_id safe_if_line
  safe_name=$(escape_sed_replacement "$check_name")
  safe_full_name=$(escape_sed_replacement "$full_check_name")
  safe_id=$(escape_sed_replacement "$check_id")

  # Use marker for optional if line - delete the line if no condition
  # Conditional checks need && success() to prevent running after earlier failures
  if [[ -n "$condition" ]]; then
    safe_if_line="  if: $(escape_sed_replacement "$condition") \&\& success()"
  else
    safe_if_line="__DELETE_THIS_LINE__"
  fi

  cat "$template_file" \
    | strip_spdx_header \
    | sed "s|\${CHECK_NAME}|$safe_name|g" \
    | sed "s|\${CHECK_FULL_NAME}|$safe_full_name|g" \
    | sed "s|\${CHECK_ID}|$safe_id|g" \
    | sed "s|\${CHECK_IF_LINE}|$safe_if_line|g" \
    | grep -v "__DELETE_THIS_LINE__"
}

# Generate github-check-end steps from template
# Uses sed for substitution (bash parameter expansion escaping differs between versions)
generate_check_end() {
  local check_name="$1"
  local check_id="$2"
  local condition="$3"
  local job_name="$4"
  local template_file="$STEPS_DIR/github-check-end.yaml"

  if [[ ! -f "$template_file" ]]; then
    echo "ERROR: Template not found: $template_file" >&2
    exit 1
  fi

  # Format check name with job prefix if available
  local full_check_name="$check_name"
  if [[ -n "$job_name" ]]; then
    full_check_name="${job_name} → ${check_name}"
  fi

  # Escape values for sed replacement
  local safe_name safe_full_name safe_id safe_pass safe_fail
  safe_name=$(escape_sed_replacement "$check_name")
  safe_full_name=$(escape_sed_replacement "$full_check_name")
  safe_id=$(escape_sed_replacement "$check_id")

  # Guard: pass/fail conditions check that start step ran (prevents cascade failures from API issues)
  local check_ran_guard="steps.${check_id}.outputs.check-run-id != ''"
  if [[ -n "$condition" ]]; then
    safe_pass="$(escape_sed_replacement "$condition") \&\& success() \&\& ${check_ran_guard}"
    safe_fail="$(escape_sed_replacement "$condition") \&\& failure() \&\& ${check_ran_guard}"
  else
    safe_pass="success() \&\& ${check_ran_guard}"
    safe_fail="failure() \&\& ${check_ran_guard}"
  fi

  cat "$template_file" \
    | strip_spdx_header \
    | sed "s|\${CHECK_NAME}|$safe_name|g" \
    | sed "s|\${CHECK_FULL_NAME}|$safe_full_name|g" \
    | sed "s|\${CHECK_ID}|$safe_id|g" \
    | sed "s|\${CHECK_PASS_CONDITION}|$safe_pass|g" \
    | sed "s|\${CHECK_FAIL_CONDITION}|$safe_fail|g"
}

# Process a single template file
process_template() {
  local template="$1"
  local basename
  basename=$(basename "$template")
  local output="$OUTPUT_DIR/$basename"

  echo "Processing: $basename"

  local workflow_name="${basename%.yaml}"
  local result=""

  # Track current job context for check naming
  local in_jobs_section=false
  local current_job_name=""
  local pending_job_key=""

  # Process line by line to handle INJECT markers with proper indentation
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip kaptain-* metadata fields (used for README generation only)
    if [[ "$line" =~ ^kaptain- ]]; then
      continue
    fi

    # Track when we enter jobs: section
    if [[ "$line" == "jobs:" ]]; then
      in_jobs_section=true
    fi

    # Track job keys (lines like "  job-key:" at 2-space indent under jobs:)
    if [[ "$in_jobs_section" == true && "$line" =~ ^[[:space:]][[:space:]][a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
      pending_job_key="true"
      current_job_name=""  # Reset until we find the name
    fi

    # Capture job name (lines like "    name: Job Name" at 4-space indent)
    if [[ "$pending_job_key" == "true" && "$line" =~ ^[[:space:]][[:space:]][[:space:]][[:space:]]name:[[:space:]]*(.+)$ ]]; then
      current_job_name="${BASH_REMATCH[1]}"
      # Strip surrounding quotes if present
      current_job_name="${current_job_name#\'}"
      current_job_name="${current_job_name%\'}"
      current_job_name="${current_job_name#\"}"
      current_job_name="${current_job_name%\"}"
      pending_job_key=""
    fi

    # Parameterized injection: # INJECT: name(params)
    if [[ "$line" =~ ^([[:space:]]*)#\ INJECT:\ ([a-zA-Z0-9_-]+)\((.+)\)$ ]]; then
      local indent="${BASH_REMATCH[1]}"
      local injection_type="${BASH_REMATCH[2]}"
      local params="${BASH_REMATCH[3]}"

      local chunk=""
      case "$injection_type" in
        github-check-start)
          local check_name check_id condition
          check_name=$(parse_param "$params" "name")
          check_id=$(parse_param "$params" "id")
          condition=$(parse_param "$params" "if")
          chunk=$(generate_check_start "$check_name" "$check_id" "$condition" "$current_job_name")
          ;;
        github-check-end)
          local check_name check_id condition
          check_name=$(parse_param "$params" "name")
          check_id=$(parse_param "$params" "id")
          condition=$(parse_param "$params" "if")
          chunk=$(generate_check_end "$check_name" "$check_id" "$condition" "$current_job_name")
          ;;
        *)
          echo "  ERROR: Unknown parameterized injection type: $injection_type" >&2
          exit 1
          ;;
      esac

      # Apply indentation to generated chunk
      local indented_chunk
      indented_chunk=$(echo "$chunk" | indent_chunk "$indent")
      result+="${indent}${indented_chunk}"
      echo "  Injected: $injection_type (indent: ${#indent} spaces)"

    # INJECT-INPUT is not allowed in workflow templates (config comes from KaptainPM.yaml)
    elif [[ "$line" =~ \#\ INJECT-INPUT: ]]; then
      echo "  ERROR: INJECT-INPUT found in workflow template - inputs are no longer supported" >&2
      echo "  Line: $line" >&2
      exit 1

    # Simple injection: # INJECT: name
    elif [[ "$line" =~ ^([[:space:]]*)#\ INJECT:\ ([a-zA-Z0-9_-]+)$ ]]; then
      local indent="${BASH_REMATCH[1]}"
      local chunk_name="${BASH_REMATCH[2]}"
      local chunk_file="$STEPS_DIR/${chunk_name}.yaml"

      if [[ ! -f "$chunk_file" ]]; then
        echo "  ERROR: Chunk not found: $chunk_file" >&2
        exit 1
      fi

      # Read chunk, strip SPDX header, replace placeholders, append success() to conditions, and apply indentation
      local chunk
      chunk=$(cat "$chunk_file" | strip_spdx_header)
      chunk="${chunk//\$\{WORKFLOW_NAME\}/$workflow_name}"
      chunk=$(echo "$chunk" | append_success_to_conditions)

      # Apply indentation to chunk (first line gets indent, others get indent prepended)
      local indented_chunk
      indented_chunk=$(echo "$chunk" | indent_chunk "$indent")

      result+="${indent}${indented_chunk}"
      echo "  Injected: $chunk_name (indent: ${#indent} spaces)"
    else
      result+="$line"
    fi
    result+=$'\n'
  done < "$template"

  # Write output (remove trailing newline duplication)
  printf '%s' "$result" > "$output"
  echo "  Written: $output"
}

# Process a single action template file
process_action_template() {
  local template="$1"
  local basename
  basename=$(basename "$template" .yaml)
  local output_dir="$ACTIONS_DIR/$basename"
  local output="$output_dir/action.yaml"

  echo "Processing action: $basename"

  mkdir -p "$output_dir"

  local result=""

  # Process line by line to handle INJECT-INPUT markers
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Input injection: # INJECT-INPUT: name
    if [[ "$line" =~ ^([[:space:]]*)#\ INJECT-INPUT:\ ([a-zA-Z0-9_-]+)$ ]]; then
      local indent="${BASH_REMATCH[1]}"
      local input_name="${BASH_REMATCH[2]}"
      local input_file="$INPUTS_DIR/${input_name}.yaml"

      if [[ ! -f "$input_file" ]]; then
        echo "  ERROR: Input file not found: $input_file" >&2
        exit 1
      fi

      # Read input file, strip SPDX header, remove 'type' field, quote unquoted booleans/numbers, and apply indentation
      local chunk
      chunk=$(cat "$input_file" | strip_spdx_header | grep -v '^[[:space:]]*type:' | sed -E "s/^([[:space:]]*default:[[:space:]]*)(true|false|[0-9]+)$/\1'\2'/")

      # Apply indentation to chunk
      local indented_chunk
      indented_chunk=$(echo "$chunk" | indent_chunk "$indent")

      result+="${indent}${indented_chunk}"
      echo "  Injected input: $input_name (indent: ${#indent} spaces)"
    else
      result+="$line"
    fi
    result+=$'\n'
  done < "$template"

  # Write output
  printf '%s' "$result" > "$output"
  echo "  Written: $output"
}

validate_workflow_inputs() {
  echo "Validating each workflow exposes only the 'runner' input..."

  local errors=0

  for workflow in "$OUTPUT_DIR"/*.yaml; do
    [[ -f "$workflow" ]] || continue
    local wf_basename
    wf_basename=$(basename "$workflow")
    # Skip workflows without a corresponding template
    [[ ! -f "$TEMPLATES_DIR/$wf_basename" ]] && continue

    local inputs
    inputs=$(yq '.on.workflow_call.inputs | keys | .[]' "$workflow" 2>/dev/null) || inputs=""

    local has_runner=0
    local extras=()
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if [[ "$name" == "runner" ]]; then
        has_runner=1
      else
        extras+=("$name")
      fi
    done <<< "$inputs"

    if [[ $has_runner -eq 0 ]]; then
      echo "  ERROR: $wf_basename is missing the required 'runner' input" >&2
      errors=$((errors + 1))
    fi
    if [[ ${#extras[@]} -gt 0 ]]; then
      echo "  ERROR: $wf_basename declares disallowed input(s) (only 'runner' is allowed; all other config belongs in KaptainPM.yaml):" >&2
      printf '    %s\n' "${extras[@]}" >&2
      errors=$((errors + 1))
    fi
  done

  if [[ $errors -gt 0 ]]; then
    echo "  FAILED: $errors workflow(s) have an inputs problem - must declare 'runner' and nothing else" >&2
    exit 1
  fi

  echo "  OK: every workflow exposes only the 'runner' input"
}

# Generate secrets table for README
generate_secrets_table() {
  local secrets_file
  secrets_file=$(mktemp)

  # Collect all unique secrets across assembled output files
  for workflow in "$OUTPUT_DIR"/*.yaml; do
    [[ -f "$workflow" ]] || continue
    # Skip workflows without a corresponding template
    [[ ! -f "$TEMPLATES_DIR/$(basename "$workflow")" ]] && continue
    local secrets
    secrets=$(yq '.on.workflow_call.secrets | keys | .[]' "$workflow" 2>/dev/null) || continue

    for secret in $secrets; do
      grep -q "^${secret}	" "$secrets_file" 2>/dev/null && continue
      local description
      description=$(yq ".on.workflow_call.secrets[\"$secret\"].description // \"\"" "$workflow")
      printf '%s\t%s\n' "$secret" "$description" >> "$secrets_file"
    done
  done

  echo "| Secret | Description |"
  echo "|--------|-------------|"
  sort "$secrets_file" | while IFS=$'\t' read -r secret description; do
    echo "| \`$secret\` | $description |"
  done

  rm -f "$secrets_file"
}

# Generate workflow doc file from assembled output
generate_workflow_doc() {
  local wf_name="$1"
  local workflow="$OUTPUT_DIR/${wf_name}.yaml"
  local doc_file="$DOCS_DIR/${wf_name}.md"

  local description
  description=$(yq '.name // ""' "$workflow")

  {
    echo "# ${wf_name}"
    echo ""
    echo "$description"
    echo ""
    echo "## Inputs"
    echo ""
    echo "All configuration comes from KaptainPM.yaml and layers, except secrets."

    # Secrets if any
    local secrets
    secrets=$(yq '.on.workflow_call.secrets | keys | .[]' "$workflow" 2>/dev/null) || true
    if [[ -n "$secrets" ]]; then
      echo ""
      echo "## Secrets"
      echo ""
      echo "| Secret | Description |"
      echo "|--------|-------------|"
      for secret in $secrets; do
        local desc
        desc=$(yq ".on.workflow_call.secrets[\"$secret\"].description // \"\"" "$workflow")
        echo "| \`$secret\` | $desc |"
      done
    fi

    # Outputs if any
    local outputs
    outputs=$(yq '.on.workflow_call.outputs | keys | .[]' "$workflow" 2>/dev/null) || true
    if [[ -n "$outputs" ]]; then
      echo ""
      echo "## Outputs"
      echo ""
      echo "| Output | Description |"
      echo "|--------|-------------|"
      for output in $outputs; do
        local desc
        desc=$(yq ".on.workflow_call.outputs[\"$output\"].description // \"\"" "$workflow")
        echo "| \`$output\` | $desc |"
      done
    fi
  } > "$doc_file"

  echo "  Generated: $doc_file"
}

# Generate workflow links table for README
generate_workflow_links_table() {
  echo "| Workflow | Description | Documentation |"
  echo "|----------|-------------|---------------|"

  for workflow in "$OUTPUT_DIR"/*.yaml; do
    [[ -f "$workflow" ]] || continue
    local wf_basename wf_name description
    wf_basename=$(basename "$workflow")
    # Skip workflows without a corresponding template
    [[ ! -f "$TEMPLATES_DIR/$wf_basename" ]] && continue
    wf_name="${wf_basename%.yaml}"
    description=$(yq '.name // ""' "$workflow")
    echo "| \`$wf_basename\` | $description | [docs/${wf_name}.md](docs/${wf_name}.md) |"
  done
}

# Generate examples table for README
# Extracts description from comment header in each examples/<name>/build.yaml
# Format: line 1-2 SPDX, line 3 empty #, line 4 title, line 5 empty #, lines 6+ description
generate_examples_table() {
  local examples_dir="$REPO_ROOT/examples"

  echo "| Example | Description |"
  echo "|---------|-------------|"

  for build_file in "$examples_dir"/*/build.yaml; do
    [[ -f "$build_file" ]] || continue
    local ex_dir ex_name description
    ex_dir=$(dirname "$build_file")
    ex_name=$(basename "$ex_dir")

    # Extract first description line (line 6 typically has description start)
    description=""
    local line_num=0
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      # Skip first 5 lines (SPDX header + blank + title + blank)
      [[ $line_num -le 5 ]] && continue
      # Stop at line 12 or when we hit non-comment or empty line
      [[ $line_num -gt 12 ]] && break
      # Skip empty comment lines (just "#" or "# ")
      [[ "$line" == "#" ]] && continue
      [[ "$line" == "# " ]] && continue
      # Must be a comment line with content
      [[ ! "$line" =~ ^#\  ]] && break
      # Get the content and use first non-empty line
      local content="${line#\# }"
      if [[ -n "$content" && -z "$description" ]]; then
        description="$content"
        break
      fi
    done < "$build_file"

    # Clean up description - take first sentence
    description="${description%%.*}"
    # Remove trailing colon if present
    description="${description%:}"
    [[ -z "$description" ]] && description="Example workflow"

    echo "| [\`$ex_name\`](examples/$ex_name/README.md) | $description |"
  done

  # Add guides if any exist
  local guides_dir="$examples_dir/guides"
  if [[ -d "$guides_dir" ]]; then
    echo ""
    echo "### Guides"
    echo ""
    echo "| Guide | README | build.yaml | KaptainPM.yaml |"
    echo "|-------|--------|------------|----------------|"

    for guide_dir in "$guides_dir"/*/; do
      [[ -d "$guide_dir" ]] || continue
      local guide_name
      guide_name=$(basename "$guide_dir")
      local base="examples/guides/$guide_name"

      echo "| \`$guide_name\` | [README](${base}/README.md) | [build.yaml](${base}/build.yaml) | [KaptainPM.yaml](${base}/KaptainPM.yaml) |"
    done
  fi
}

# Generate workflows table for README (sorted by kaptain-order)
generate_workflows_table() {
  echo "| Workflow | Description |"
  echo "|----------|-------------|"

  # Collect workflows with order, then sort
  local entries=()
  for workflow in "$TEMPLATES_DIR"/*.yaml; do
    [[ -f "$workflow" ]] || continue
    local wf_basename order description
    wf_basename=$(basename "$workflow")
    order=$(yq '.["kaptain-order"] // 999' "$workflow")
    description=$(yq '.["kaptain-description"] // .name // ""' "$workflow")
    entries+=("$order|$wf_basename|$description")
  done

  # Sort by order and output
  printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -n | while IFS='|' read -r _ name desc; do
    echo "| \`$name\` | $desc |"
  done
}

# Generate actions table for README
generate_actions_table() {
  local actions_dir="$REPO_ROOT/src/actions"

  echo "| Action | Description |"
  echo "|--------|-------------|"

  for action_dir in "$actions_dir"/*/; do
    [[ -d "$action_dir" ]] || continue
    local action_file="$action_dir/action.yaml"
    [[ -f "$action_file" ]] || continue

    local action_name description
    action_name=$(basename "$action_dir")
    description=$(yq '.description // ""' "$action_file")

    echo "| \`$action_name\` | $description |"
  done
}

# Inject content between markers in a file
inject_between_markers() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local content="$4"

  local temp_file
  temp_file=$(mktemp)

  local in_section=false
  local injected=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"$start_marker"* ]]; then
      echo "$line" >> "$temp_file"
      echo "$content" >> "$temp_file"
      in_section=true
      injected=true
    elif [[ "$line" == *"$end_marker"* ]]; then
      echo "$line" >> "$temp_file"
      in_section=false
    elif [[ "$in_section" == false ]]; then
      echo "$line" >> "$temp_file"
    fi
  done < "$file"

  if [[ "$injected" == true ]]; then
    mv "$temp_file" "$file"
  else
    rm -f "$temp_file"
    echo "  WARNING: Markers not found: $start_marker" >&2
  fi
}

# Generate all documentation
generate_docs() {
  echo "Generating documentation..."

  # Clean docs directory for predictable results
  if [[ -d "$DOCS_DIR" ]]; then
    rm "$DOCS_DIR"/*
    echo "  Cleaned docs directory"
  fi

  # Create docs directory
  mkdir -p "$DOCS_DIR"

  # Generate individual workflow docs from assembled output
  for workflow in "$OUTPUT_DIR"/*.yaml; do
    [[ -f "$workflow" ]] || continue
    local wf_basename wf_name
    wf_basename=$(basename "$workflow")
    # Skip workflows without a corresponding template
    [[ ! -f "$TEMPLATES_DIR/$wf_basename" ]] && continue
    wf_name="${wf_basename%.yaml}"
    generate_workflow_doc "$wf_name"
  done

  # Generate and inject examples table
  local examples_table
  examples_table=$(generate_examples_table)
  inject_between_markers "$README" "<!-- EXAMPLES-START -->" "<!-- EXAMPLES-END -->" "$examples_table"
  echo "  Injected: examples table"

  # Generate and inject workflows table
  local workflows_table
  workflows_table=$(generate_workflows_table)
  inject_between_markers "$README" "<!-- WORKFLOWS-START -->" "<!-- WORKFLOWS-END -->" "$workflows_table"
  echo "  Injected: workflows table"

  # Generate and inject actions table
  local actions_table
  actions_table=$(generate_actions_table)
  inject_between_markers "$README" "<!-- ACTIONS-START -->" "<!-- ACTIONS-END -->" "$actions_table"
  echo "  Injected: actions table"

  # Generate and inject secrets table
  local secrets_table
  secrets_table=$(generate_secrets_table)
  inject_between_markers "$README" "<!-- SECRETS-START -->" "<!-- SECRETS-END -->" "$secrets_table"
  echo "  Injected: secrets table"

  # Generate and inject workflow links table
  local links_table
  links_table=$(generate_workflow_links_table)
  inject_between_markers "$README" "<!-- WORKFLOW-DOCS-START -->" "<!-- WORKFLOW-DOCS-END -->" "$links_table"
  echo "  Injected: workflow links table"
}

# Validate that no env: block assigns a GitHub Actions default environment variable.
# The runner injects its own value for these into every step and that value wins, so
# the assignment is silently ignored and the intended value never reaches the script.
# Anything we want to control must use a name we own.
validate_reserved_env_vars() {
  echo "Validating reserved env vars..."

  # GitHub Actions default environment variables, as injected by the runner.
  # GITHUB_TOKEN is deliberately absent: the runner does not set it, so it is ours.
  local reserved_vars="
    CI
    GITHUB_ACTION GITHUB_ACTIONS GITHUB_ACTION_PATH GITHUB_ACTION_REPOSITORY
    GITHUB_ACTOR GITHUB_ACTOR_ID GITHUB_API_URL GITHUB_BASE_REF GITHUB_ENV
    GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_GRAPHQL_URL GITHUB_HEAD_REF
    GITHUB_JOB GITHUB_OUTPUT GITHUB_PATH GITHUB_REF GITHUB_REF_NAME
    GITHUB_REF_PROTECTED GITHUB_REF_TYPE GITHUB_REPOSITORY GITHUB_REPOSITORY_ID
    GITHUB_REPOSITORY_OWNER GITHUB_REPOSITORY_OWNER_ID GITHUB_RETENTION_DAYS
    GITHUB_RUN_ATTEMPT GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_SERVER_URL
    GITHUB_SHA GITHUB_STEP_SUMMARY GITHUB_TRIGGERING_ACTOR GITHUB_WORKFLOW
    GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA GITHUB_WORKSPACE
    RUNNER_ARCH RUNNER_DEBUG RUNNER_NAME RUNNER_OS RUNNER_TEMP RUNNER_TOOL_CACHE
  "

  # Reserved names we assign anyway, each to the exact value the runner already
  # provides, so the assignment is a harmless no-op whichever side wins. A name
  # only belongs here if the value assigned is provably identical to the runner's.
  local allowed_vars="
    GITHUB_REPOSITORY
    GITHUB_SERVER_URL
    GITHUB_WORKFLOW_REF
  "

  local reserved allowed
  reserved=" $(printf '%s' "$reserved_vars" | tr '\n' ' ') "
  allowed=" $(printf '%s' "$allowed_vars" | tr '\n' ' ') "

  local errors=0

  for dir in "$ACTION_TEMPLATES_DIR" "$STEPS_DIR" "$TEMPLATES_DIR"; do
    local dir_label
    dir_label=$(basename "$dir")
    for file in "$dir"/*.yaml; do
      [[ -f "$file" ]] || continue
      local file_basename
      file_basename=$(basename "$file")

      local in_env_block=false
      local env_indent=0
      local line_number=0

      while IFS= read -r line; do
        line_number=$((line_number + 1))

        # Detect start of an env: block
        if [[ "$line" =~ ^([[:space:]]*)env:[[:space:]]*$ ]]; then
          in_env_block=true
          env_indent=${#BASH_REMATCH[1]}
          continue
        fi

        [[ "$in_env_block" == "true" ]] || continue

        # Blank lines do not end the block
        [[ "$line" =~ ^([[:space:]]*)[^[:space:]] ]] || continue

        local line_indent=${#BASH_REMATCH[1]}
        if [[ $line_indent -le $env_indent ]]; then
          in_env_block=false
          continue
        fi

        # Only the key matters here; the assigned value is never read
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*): ]] || continue
        local key="${BASH_REMATCH[1]}"

        if [[ "$reserved" == *" $key "* ]] && [[ "$allowed" != *" $key "* ]]; then
          echo "  ERROR: $dir_label/$file_basename:$line_number assigns reserved env var $key"
          errors=$((errors + 1))
        fi
      done < "$file"
    done
  done

  if [[ $errors -gt 0 ]]; then
    echo "  FAILED: $errors reserved env var assignment(s)"
    echo "  The runner injects its own value for these into every step, so the assignment"
    echo "  is silently ignored. Rename the variable to a name this project owns."
    exit 1
  fi

  echo "  No reserved env vars assigned"
}

# Validate that all action templates and steps-common files that set BUILD_PLATFORM
# also set BUILD_MODE and BUILD_PLATFORM_LOG_PROVIDER. These three must travel together.
validate_build_context_env_vars() {
  echo "Validating build context env vars..."

  local required_vars=("BUILD_PLATFORM" "BUILD_MODE" "BUILD_PLATFORM_LOG_PROVIDER")

  # Files that have no env block and don't call kaptain scripts
  local excluded_files=(
    "github-check-run.yaml"
    "github-release.yaml"
  )

  # Files that have an env block but only use inline bash, not kaptain scripts
  local inline_env_files=(
    "parse-workflow-ref-and-checkout.yaml"
    "github-release-prepare-eks.yaml"
    "github-release-prepare-spec.yaml"
  )

  local errors=0

  for dir in "$ACTION_TEMPLATES_DIR" "$STEPS_DIR"; do
    local dir_label
    dir_label=$(basename "$dir")
    for file in "$dir"/*.yaml; do
      [[ -f "$file" ]] || continue
      local file_basename
      file_basename=$(basename "$file")

      # Skip files that don't need build context
      local skip=false
      for excluded in "${excluded_files[@]}" "${inline_env_files[@]}"; do
        if [[ "$file_basename" == "$excluded" ]]; then
          skip=true
          break
        fi
      done
      [[ "$skip" == "true" ]] && continue

      # Check each env: block individually (multi-step actions have multiple)
      local block_num=0
      local in_env_block=false
      local env_indent=0
      local block_vars=""

      while IFS= read -r line; do
        # Detect start of an env: block
        if [[ "$line" =~ ^([[:space:]]*)env:[[:space:]]*$ ]]; then
          # Flush previous block if any
          if [[ "$in_env_block" == "true" ]]; then
            for var in "${required_vars[@]}"; do
              if [[ "$block_vars" != *"$var"* ]]; then
                echo "  ERROR: $dir_label/$file_basename env block $block_num missing $var"
                errors=$((errors + 1))
              fi
            done
          fi
          block_num=$((block_num + 1))
          in_env_block=true
          env_indent=${#BASH_REMATCH[1]}
          block_vars=""
          continue
        fi

        if [[ "$in_env_block" == "true" ]]; then
          # Check if line is still inside the env block (indented deeper than env:)
          if [[ "$line" =~ ^([[:space:]]*)[^[:space:]] ]]; then
            local line_indent=${#BASH_REMATCH[1]}
            if [[ $line_indent -le $env_indent ]]; then
              # Left the env block - flush it
              for var in "${required_vars[@]}"; do
                if [[ "$block_vars" != *"$var"* ]]; then
                  echo "  ERROR: $dir_label/$file_basename env block $block_num missing $var"
                  errors=$((errors + 1))
                fi
              done
              in_env_block=false
            else
              # Still in env block - collect var names
              block_vars="${block_vars} ${line}"
            fi
          fi
        fi
      done < "$file"

      # Flush final block if file ends inside one
      if [[ "$in_env_block" == "true" ]]; then
        for var in "${required_vars[@]}"; do
          if [[ "$block_vars" != *"$var"* ]]; then
            echo "  ERROR: $dir_label/$file_basename env block $block_num missing $var"
            errors=$((errors + 1))
          fi
        done
      fi
    done
  done

  if [[ $errors -gt 0 ]]; then
    echo "  FAILED: $errors missing build context env var(s)"
    echo "  All env blocks must set BUILD_MODE, BUILD_PLATFORM, and BUILD_PLATFORM_LOG_PROVIDER"
    exit 1
  fi

  echo "  All build context env vars consistent"
}

main() {
  local start_time=$SECONDS
  local section_start

  # Reject reserved env var assignments before doing any work
  validate_reserved_env_vars
  echo

  # Validate build context env vars before doing any work
  validate_build_context_env_vars
  echo

  # Update example versions early; fail fast if examples/ diverged
  section_start=$SECONDS
  "${SCRIPT_DIR}/updateExampleVersions.bash"
  if ! git -C "$REPO_ROOT" diff --quiet -- examples/; then
    echo "ERROR: examples/ have stale references - re-run after committing the update" >&2
    git -C "$REPO_ROOT" diff --name-only -- examples/ >&2
    exit 1
  fi
  echo "Examples updated in $((SECONDS - section_start)) seconds."
  echo

  # Process action templates first
  echo "Assembling actions..."
  echo "  Templates: $ACTION_TEMPLATES_DIR"
  echo "  Output: $ACTIONS_DIR"
  echo

  # Clean and recreate actions directory
  section_start=$SECONDS
  rm -r "$ACTIONS_DIR"
  echo "  Removed existing actions directory"
  mkdir -p "$ACTIONS_DIR"

  # Process all action templates
  local action_count=0
  for template in "$ACTION_TEMPLATES_DIR"/*.yaml; do
    if [[ -f "$template" ]]; then
      process_action_template "$template"
      action_count=$((action_count + 1))
      echo
    fi
  done

  echo "Processed $action_count action(s) in $((SECONDS - section_start)) seconds."
  echo

  echo "Assembling workflows..."
  echo "  Templates: $TEMPLATES_DIR"
  echo "  Steps: $STEPS_DIR"
  echo "  Output: $OUTPUT_DIR"
  echo

  # Clean output directory for predictable results
  # These files are not generated from templates - preserve them
  local preserved_files=(
    "build.yaml"
  )

  if [[ -d "$OUTPUT_DIR" ]]; then
    echo "Cleaning output directory..."
    for file in "$OUTPUT_DIR"/*; do
      [[ -f "$file" ]] || continue
      local basename
      basename=$(basename "$file")
      local preserve=false
      for pf in "${preserved_files[@]}"; do
        if [[ "$basename" == "$pf" ]]; then
          echo "  Keeping ${file}"
          preserve=true
          break
        fi
      done
      if [[ "$preserve" == "false" ]]; then
        echo "  Removing ${file}"
        rm "$file"
      fi
    done
    echo "Removed generated files from $OUTPUT_DIR (preserved: ${preserved_files[*]})"
    echo
  fi

  # Ensure output directory exists
  mkdir -p "$OUTPUT_DIR"

  # Process all templates
  section_start=$SECONDS
  local count=0
  for template in "$TEMPLATES_DIR"/*.yaml; do
    if [[ -f "$template" ]]; then
      process_template "$template"
      count=$((count + 1))
      echo
    fi
  done

  echo "Processed $count template(s) in $((SECONDS - section_start)) seconds."
  echo

  # Validate every workflow exposes exactly the 'runner' input and nothing else
  section_start=$SECONDS
  validate_workflow_inputs
  echo "Validated in $((SECONDS - section_start)) seconds."
  echo

  # Generate documentation
  section_start=$SECONDS
  generate_docs
  echo "Docs generated in $((SECONDS - section_start)) seconds."
  echo

  echo
  echo "Done in $((SECONDS - start_time)) seconds."
}

main "$@"
