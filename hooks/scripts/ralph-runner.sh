#!/bin/bash
# Ralph Specum Runner
# Runs Claude Code in a loop, automatically restarting with fresh context
# when the force-restart mechanism triggers.
#
# Usage: ./ralph-runner.sh "goal description" [options]
#
# Example:
#   ./ralph-runner.sh "Add user auth with JWT" --mode auto --force-restart

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SPEC_DIR="${RALPH_SPEC_DIR:-./spec}"
MAX_RESTARTS="${RALPH_MAX_RESTARTS:-50}"
RESTART_DELAY="${RALPH_RESTART_DELAY:-2}"

log_info()    { echo -e "${BLUE}[ralph-runner]${NC} $1"; }
log_success() { echo -e "${GREEN}[ralph-runner]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[ralph-runner]${NC} $1"; }
log_error()   { echo -e "${RED}[ralph-runner]${NC} $1"; }
log_header()  { echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"; }

# Find restart marker
find_restart_marker() {
    find "$SPEC_DIR" -maxdepth 2 -name ".ralph-restart" -type f 2>/dev/null | head -n 1
}

# Find state file
find_state_file() {
    find "$SPEC_DIR" -maxdepth 2 -name ".ralph-state.json" -type f 2>/dev/null | head -n 1
}

# Check if workflow is complete (no state file = complete or not started)
is_workflow_complete() {
    local state_file=$(find_state_file)
    [[ ! -f "$state_file" ]] && return 0

    local phase=$(jq -r '.phase' "$state_file")
    local task_index=$(jq -r '.taskIndex' "$state_file")
    local total_tasks=$(jq -r '.totalTasks' "$state_file")

    [[ "$phase" == "execution" && "$task_index" -ge "$total_tasks" && "$total_tasks" -gt 0 ]] && return 0
    return 1
}

# Get current status from state
get_status() {
    local state_file=$(find_state_file)
    if [[ -f "$state_file" ]]; then
        local phase=$(jq -r '.phase' "$state_file")
        local task_index=$(jq -r '.taskIndex // 0' "$state_file")
        local total_tasks=$(jq -r '.totalTasks // 0' "$state_file")
        echo "Phase: $phase | Tasks: $task_index/$total_tasks"
    else
        echo "Not started"
    fi
}

# Main
main() {
    local goal="$1"
    shift
    local extra_args="$@"

    if [[ -z "$goal" ]]; then
        echo "Usage: $0 \"goal description\" [--mode auto] [--force-restart] [other options]"
        echo ""
        echo "This script runs Claude Code in a loop, automatically restarting"
        echo "when the --force-restart mechanism triggers a quit."
        echo ""
        echo "Environment variables:"
        echo "  RALPH_SPEC_DIR      Spec directory (default: ./spec)"
        echo "  RALPH_MAX_RESTARTS  Max restart iterations (default: 50)"
        echo "  RALPH_RESTART_DELAY Seconds between restarts (default: 2)"
        exit 1
    fi

    # Ensure --force-restart is included
    if [[ ! "$extra_args" =~ "--force-restart" ]]; then
        extra_args="$extra_args --force-restart"
        log_warn "Adding --force-restart flag (required for this runner)"
    fi

    local restart_count=0
    local initial_prompt="/ralph-specum \"$goal\" $extra_args"

    log_header "RALPH SPECUM RUNNER"
    log_info "Goal: $goal"
    log_info "Options: $extra_args"
    log_info "Max restarts: $MAX_RESTARTS"

    while true; do
        # Safety check
        if [[ $restart_count -ge $MAX_RESTARTS ]]; then
            log_error "Max restarts ($MAX_RESTARTS) reached. Exiting."
            exit 1
        fi

        # Check completion
        if is_workflow_complete && [[ $restart_count -gt 0 ]]; then
            log_success "Workflow complete!"
            exit 0
        fi

        # Determine prompt for this iteration
        local prompt
        local marker=$(find_restart_marker)

        if [[ $restart_count -eq 0 ]]; then
            # First run - use initial prompt
            prompt="$initial_prompt"
            log_header "STARTING CLAUDE (Initial Run)"
        elif [[ -f "$marker" ]]; then
            # Restart with context from marker
            local spec_path=$(jq -r '.specPath' "$marker")
            local instruction=$(jq -r '.instruction' "$marker")

            prompt="Resume the ralph-specum workflow. $instruction

Read the state files first:
1. $spec_path/.ralph-state.json - for current phase/task
2. $spec_path/.ralph-progress.md - for context and learnings
3. $spec_path/tasks.md - for task details

Then run: /ralph-specum:implement"

            rm -f "$marker"
            log_header "RESTARTING CLAUDE (#$restart_count)"
            log_info "Reason: $(jq -r '.reason' "$marker" 2>/dev/null || echo 'continuation')"
        else
            # No marker but not complete - resume from state
            local state_file=$(find_state_file)
            local spec_path=$(jq -r '.specPath' "$state_file")

            prompt="Resume the ralph-specum workflow from $spec_path.

Read the state files and continue:
1. $spec_path/.ralph-state.json
2. $spec_path/.ralph-progress.md

Then run: /ralph-specum:implement"

            log_header "RESTARTING CLAUDE (#$restart_count)"
        fi

        log_info "Status: $(get_status)"
        log_info "Prompt: ${prompt:0:100}..."
        echo ""

        # Run Claude Code
        # Using --dangerously-skip-permissions to avoid prompts in automated context
        # The -p flag runs in print mode (non-interactive with initial prompt)
        if command -v claude &> /dev/null; then
            claude -p "$prompt" || true
        else
            log_error "Claude CLI not found in PATH"
            exit 1
        fi

        restart_count=$((restart_count + 1))

        # Small delay before checking for restart
        log_info "Claude exited. Waiting ${RESTART_DELAY}s before checking status..."
        sleep "$RESTART_DELAY"

        # Check if we should continue
        if is_workflow_complete; then
            log_success "Workflow complete after $restart_count iteration(s)!"
            exit 0
        fi

        local marker=$(find_restart_marker)
        local state_file=$(find_state_file)

        if [[ ! -f "$marker" && ! -f "$state_file" ]]; then
            log_warn "No restart marker or state file found. Workflow may be complete or cancelled."
            exit 0
        fi

        log_info "Restart marker or state found. Continuing loop..."
    done
}

# Handle interrupt
cleanup() {
    log_warn "Interrupted. Cleaning up..."
    exit 130
}
trap cleanup INT TERM

main "$@"
