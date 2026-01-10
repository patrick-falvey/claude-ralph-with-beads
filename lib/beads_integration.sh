#!/usr/bin/env bash

# beads_integration.sh - Beads (bd) task management integration for Ralph
# Provides abstraction layer for task source: beads when available, @fix_plan.md fallback
# See: https://github.com/steveyegge/beads

# Source date utilities for timestamps
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

BEADS_DIR=".beads"
BEADS_CMD="bd"
FIX_PLAN_FILE="@fix_plan.md"
CURRENT_TASK_FILE=".ralph_current_task"

# =============================================================================
# DETECTION FUNCTIONS
# =============================================================================

# Check if beads is available for this project
# Returns: 0 if beads is available, 1 otherwise
beads_available() {
    [[ -d "$BEADS_DIR" ]] && command -v "$BEADS_CMD" &>/dev/null
}

# Check if @fix_plan.md fallback is available
# Returns: 0 if available, 1 otherwise
fix_plan_available() {
    [[ -f "$FIX_PLAN_FILE" ]]
}

# Get the active task source name for logging
# Returns: "beads" or "fix_plan.md" or "none"
get_task_source() {
    if beads_available; then
        echo "beads"
    elif fix_plan_available; then
        echo "fix_plan.md"
    else
        echo "none"
    fi
}

# =============================================================================
# TASK READING FUNCTIONS
# =============================================================================

# Get count of ready (unblocked, open) tasks
# Returns: Integer count of ready tasks
get_ready_task_count() {
    if beads_available; then
        "$BEADS_CMD" ready --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0"
    elif fix_plan_available; then
        # grep -c returns 1 (error) when no matches, so we capture output and default to 0
        local count
        count=$(grep -c "^- \[ \]" "$FIX_PLAN_FILE" 2>/dev/null) || count=0
        echo "$count"
    else
        echo "0"
    fi
}

# Get the next available task (highest priority, unblocked)
# Returns: JSON object with id and title, or empty if none
get_next_task() {
    if beads_available; then
        local task=$("$BEADS_CMD" ready --json --limit 1 2>/dev/null | jq '.[0] // empty' 2>/dev/null)
        if [[ -n "$task" && "$task" != "null" ]]; then
            echo "$task"
        fi
    elif fix_plan_available; then
        local title=$(grep "^- \[ \]" "$FIX_PLAN_FILE" 2>/dev/null | head -1 | sed 's/^- \[ \] //')
        if [[ -n "$title" ]]; then
            # Return pseudo-JSON for consistency
            echo "{\"id\": \"fix_plan\", \"title\": \"$title\", \"source\": \"fix_plan.md\"}"
        fi
    fi
}

# Get task by ID
# Args: task_id
# Returns: JSON object with task details
get_task_by_id() {
    local task_id=$1

    if [[ -z "$task_id" ]]; then
        return 1
    fi

    if beads_available && [[ "$task_id" != "fix_plan" ]]; then
        "$BEADS_CMD" show "$task_id" --json 2>/dev/null | jq '.[0] // empty' 2>/dev/null
    fi
}

# Check if all tasks are complete
# Returns: 0 if complete, 1 if tasks remain
all_tasks_complete() {
    local count=$(get_ready_task_count)
    [[ "$count" == "0" ]]
}

# =============================================================================
# TASK LIFECYCLE FUNCTIONS
# =============================================================================

# Claim the next available task (mark as in_progress)
# Returns: Task ID if claimed, empty if none available
claim_next_task() {
    local assignee=${1:-"ralph"}

    if ! beads_available; then
        # For fix_plan.md, we don't claim - just return the task title
        local title=$(grep "^- \[ \]" "$FIX_PLAN_FILE" 2>/dev/null | head -1 | sed 's/^- \[ \] //')
        if [[ -n "$title" ]]; then
            echo "fix_plan:$title" > "$CURRENT_TASK_FILE"
            echo "fix_plan"
        fi
        return
    fi

    # Get next ready task
    local next_task=$("$BEADS_CMD" ready --json --limit 1 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)

    if [[ -z "$next_task" || "$next_task" == "null" ]]; then
        return 1
    fi

    # Claim it
    local result=$("$BEADS_CMD" update "$next_task" --status in_progress --assignee "$assignee" --json 2>/dev/null)

    if [[ $? -eq 0 ]]; then
        # Store current task for tracking
        echo "$next_task" > "$CURRENT_TASK_FILE"
        echo "$next_task"
    else
        return 1
    fi
}

# Complete the current or specified task
# Args: task_id (optional, uses current if not provided), reason (optional)
# Returns: 0 on success, 1 on failure
complete_task() {
    local task_id=${1:-$(get_current_task_id)}
    local reason=${2:-"Completed by Ralph loop"}

    if [[ -z "$task_id" ]]; then
        return 1
    fi

    if [[ "$task_id" == "fix_plan" ]]; then
        # For fix_plan.md, we rely on Claude updating the file
        rm -f "$CURRENT_TASK_FILE"
        return 0
    fi

    if ! beads_available; then
        return 1
    fi

    "$BEADS_CMD" close "$task_id" --reason "$reason" --json 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        rm -f "$CURRENT_TASK_FILE"
    fi

    return $result
}

# Get the currently claimed task ID
# Returns: Task ID or empty
get_current_task_id() {
    if [[ -f "$CURRENT_TASK_FILE" ]]; then
        cat "$CURRENT_TASK_FILE" 2>/dev/null
    fi
}

# Release a claimed task without completing (unclaim)
# Args: task_id (optional), reason (optional)
# Returns: 0 on success, 1 on failure
release_task() {
    local task_id=${1:-$(get_current_task_id)}
    local reason=${2:-"Released by Ralph"}

    if [[ -z "$task_id" || "$task_id" == "fix_plan" ]]; then
        rm -f "$CURRENT_TASK_FILE"
        return 0
    fi

    if ! beads_available; then
        rm -f "$CURRENT_TASK_FILE"
        return 0
    fi

    # Set back to open status
    "$BEADS_CMD" update "$task_id" --status open --json 2>/dev/null
    local result=$?

    rm -f "$CURRENT_TASK_FILE"
    return $result
}

# =============================================================================
# TASK CONTEXT FUNCTIONS
# =============================================================================

# Build task context string for Claude
# Returns: Human-readable context about current task state
build_task_context() {
    local source=$(get_task_source)
    local ready_count=$(get_ready_task_count)
    local current_task=$(get_current_task_id)
    local context=""

    context+="Task source: $source. "
    context+="Ready tasks: $ready_count. "

    if [[ -n "$current_task" && "$current_task" != "fix_plan" ]]; then
        local task_title=$("$BEADS_CMD" show "$current_task" --json 2>/dev/null | jq -r '.[0].title // "unknown"' 2>/dev/null)
        context+="Current: $current_task ($task_title). "
    fi

    echo "$context"
}

# Get task list summary for logging
# Returns: Summary string of top tasks
get_task_summary() {
    local limit=${1:-3}

    if beads_available; then
        "$BEADS_CMD" ready --json --limit "$limit" 2>/dev/null | \
            jq -r '.[] | "[\(.priority // 2)] \(.id): \(.title)"' 2>/dev/null | \
            head -n "$limit"
    elif fix_plan_available; then
        grep "^- \[ \]" "$FIX_PLAN_FILE" 2>/dev/null | \
            head -n "$limit" | \
            sed 's/^- \[ \] /[?] fix_plan: /'
    fi
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize beads integration (create state files if needed)
init_beads_integration() {
    local source=$(get_task_source)

    # Clean up stale current task if beads is now unavailable
    # Preserve fix_plan tasks (including "fix_plan:title" format)
    if [[ -f "$CURRENT_TASK_FILE" ]]; then
        local current_task=$(cat "$CURRENT_TASK_FILE" 2>/dev/null)
        # Only remove if it's a beads task (not fix_plan-related) and beads is unavailable
        if [[ "$current_task" != fix_plan* ]] && ! beads_available; then
            rm -f "$CURRENT_TASK_FILE"
        fi
    fi

    echo "$source"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f beads_available
export -f fix_plan_available
export -f get_task_source
export -f get_ready_task_count
export -f get_next_task
export -f get_task_by_id
export -f all_tasks_complete
export -f claim_next_task
export -f complete_task
export -f get_current_task_id
export -f release_task
export -f build_task_context
export -f get_task_summary
export -f init_beads_integration
