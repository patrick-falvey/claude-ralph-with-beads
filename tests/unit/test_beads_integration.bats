#!/usr/bin/env bats
# Unit tests for beads (bd) integration
# TDD: Tests for task source abstraction and lifecycle management

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up environment
    export PROMPT_FILE="PROMPT.md"
    export LOG_DIR="logs"
    export DOCS_DIR="docs/generated"
    export STATUS_FILE="status.json"
    export EXIT_SIGNALS_FILE=".exit_signals"
    export CALL_COUNT_FILE=".call_count"
    export TIMESTAMP_FILE=".last_reset"
    export CLAUDE_SESSION_FILE=".claude_session_id"
    export RALPH_SESSION_FILE=".ralph_session"
    export CLAUDE_MIN_VERSION="2.0.76"
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_USE_CONTINUE="true"

    # Beads integration configuration
    export BEADS_DIR=".beads"
    export BEADS_CMD="bd"
    export FIX_PLAN_FILE="@fix_plan.md"
    export CURRENT_TASK_FILE=".ralph_current_task"

    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create sample project files
    create_sample_prompt
    create_sample_fix_plan "@fix_plan.md" 10 3

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/beads_integration.sh"

    # Define color variables for log_status
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    NC='\033[0m'

    # Define log_status function for tests
    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message"
    }
    export -f log_status
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# DETECTION FUNCTIONS
# =============================================================================

@test "beads_available returns false when .beads directory missing" {
    run beads_available
    [ "$status" -eq 1 ]
}

@test "beads_available returns false when bd command not found" {
    mkdir -p "$BEADS_DIR"
    # Mock bd command to not exist
    BEADS_CMD="nonexistent_command_xyz"
    run beads_available
    [ "$status" -eq 1 ]
}

@test "fix_plan_available returns true when @fix_plan.md exists" {
    run fix_plan_available
    [ "$status" -eq 0 ]
}

@test "fix_plan_available returns false when @fix_plan.md missing" {
    rm -f "@fix_plan.md"
    run fix_plan_available
    [ "$status" -eq 1 ]
}

@test "get_task_source returns fix_plan.md when beads unavailable" {
    run get_task_source
    [ "$status" -eq 0 ]
    [ "$output" = "fix_plan.md" ]
}

@test "get_task_source returns none when both sources unavailable" {
    rm -f "@fix_plan.md"
    run get_task_source
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

# =============================================================================
# TASK READING FUNCTIONS (fix_plan.md fallback)
# =============================================================================

@test "get_ready_task_count returns incomplete task count from fix_plan.md" {
    # Create fix_plan with 3 incomplete, 2 complete
    cat > "@fix_plan.md" << 'EOF'
# Tasks
- [ ] Task 1
- [ ] Task 2
- [x] Task 3
- [ ] Task 4
- [x] Task 5
EOF
    run get_ready_task_count
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "get_ready_task_count returns 0 when all tasks complete" {
    cat > "@fix_plan.md" << 'EOF'
# Tasks
- [x] Task 1
- [x] Task 2
EOF
    run get_ready_task_count
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_ready_task_count returns 0 when no task source" {
    rm -f "@fix_plan.md"
    run get_ready_task_count
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_next_task returns first incomplete task from fix_plan.md" {
    cat > "@fix_plan.md" << 'EOF'
# Tasks
- [x] Completed task
- [ ] Next task to do
- [ ] Another task
EOF
    run get_next_task
    [ "$status" -eq 0 ]
    [[ "$output" == *"Next task to do"* ]]
    [[ "$output" == *"fix_plan.md"* ]]
}

@test "get_next_task returns empty when no incomplete tasks" {
    cat > "@fix_plan.md" << 'EOF'
# Tasks
- [x] Completed 1
- [x] Completed 2
EOF
    run get_next_task
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "all_tasks_complete returns true when count is 0" {
    cat > "@fix_plan.md" << 'EOF'
- [x] Done
EOF
    run all_tasks_complete
    [ "$status" -eq 0 ]
}

@test "all_tasks_complete returns false when tasks remain" {
    cat > "@fix_plan.md" << 'EOF'
- [ ] Not done
EOF
    run all_tasks_complete
    [ "$status" -eq 1 ]
}

# =============================================================================
# TASK LIFECYCLE (fix_plan.md fallback)
# =============================================================================

@test "claim_next_task returns fix_plan for fix_plan.md source" {
    cat > "@fix_plan.md" << 'EOF'
- [ ] Some task
EOF
    run claim_next_task "ralph"
    [ "$status" -eq 0 ]
    [ "$output" = "fix_plan" ]
    [ -f "$CURRENT_TASK_FILE" ]
}

@test "claim_next_task creates current task file" {
    cat > "@fix_plan.md" << 'EOF'
- [ ] Task to claim
EOF
    claim_next_task "ralph"
    [ -f "$CURRENT_TASK_FILE" ]
    run cat "$CURRENT_TASK_FILE"
    [[ "$output" == *"fix_plan"* ]]
}

@test "get_current_task_id returns task from file" {
    echo "test-task-123" > "$CURRENT_TASK_FILE"
    run get_current_task_id
    [ "$status" -eq 0 ]
    [ "$output" = "test-task-123" ]
}

@test "get_current_task_id returns empty when no task claimed" {
    rm -f "$CURRENT_TASK_FILE"
    run get_current_task_id
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "complete_task removes current task file for fix_plan" {
    echo "fix_plan" > "$CURRENT_TASK_FILE"
    run complete_task "fix_plan" "Test reason"
    [ "$status" -eq 0 ]
    [ ! -f "$CURRENT_TASK_FILE" ]
}

@test "release_task removes current task file" {
    echo "some-task" > "$CURRENT_TASK_FILE"
    run release_task "some-task" "Test release"
    [ "$status" -eq 0 ]
    [ ! -f "$CURRENT_TASK_FILE" ]
}

@test "release_task with no args uses current task" {
    echo "current-task" > "$CURRENT_TASK_FILE"
    run release_task
    [ "$status" -eq 0 ]
    [ ! -f "$CURRENT_TASK_FILE" ]
}

# =============================================================================
# TASK CONTEXT FUNCTIONS
# =============================================================================

@test "build_task_context includes task source" {
    run build_task_context
    [ "$status" -eq 0 ]
    [[ "$output" == *"Task source: fix_plan.md"* ]]
}

@test "build_task_context includes ready count" {
    cat > "@fix_plan.md" << 'EOF'
- [ ] Task 1
- [ ] Task 2
- [x] Done
EOF
    run build_task_context
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ready tasks: 2"* ]]
}

@test "get_task_summary returns tasks from fix_plan.md" {
    cat > "@fix_plan.md" << 'EOF'
- [ ] First task
- [ ] Second task
- [ ] Third task
EOF
    run get_task_summary 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"First task"* ]]
    [[ "$output" == *"Second task"* ]]
}

# =============================================================================
# INITIALIZATION
# =============================================================================

@test "init_beads_integration returns task source" {
    run init_beads_integration
    [ "$status" -eq 0 ]
    [ "$output" = "fix_plan.md" ]
}

@test "init_beads_integration returns none when no sources" {
    rm -f "@fix_plan.md"
    run init_beads_integration
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "init_beads_integration cleans stale task file when beads unavailable" {
    # Create a task file with non-fix_plan ID (simulating beads was used before)
    echo "beads-task-123" > "$CURRENT_TASK_FILE"

    init_beads_integration

    # Should have removed stale task file since beads is unavailable
    [ ! -f "$CURRENT_TASK_FILE" ]
}

@test "init_beads_integration preserves fix_plan task file" {
    echo "fix_plan:Some task" > "$CURRENT_TASK_FILE"

    init_beads_integration

    # Should preserve fix_plan task files
    [ -f "$CURRENT_TASK_FILE" ]
}

# =============================================================================
# RALPH_LOOP INTEGRATION POINTS
# =============================================================================

@test "beads_integration.sh sources successfully" {
    run source "${BATS_TEST_DIRNAME}/../../lib/beads_integration.sh"
    [ "$status" -eq 0 ]
}

@test "ralph_loop.sh sources beads_integration.sh" {
    grep -q 'source.*beads_integration.sh' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
}

@test "ralph_loop.sh uses get_task_source function" {
    grep -q 'get_task_source' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
}

@test "ralph_loop.sh uses get_ready_task_count function" {
    grep -q 'get_ready_task_count' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
}

@test "ralph_loop.sh uses claim_next_task function" {
    grep -q 'claim_next_task' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
}

@test "ralph_loop.sh uses complete_task function" {
    grep -q 'complete_task' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
}

@test "ralph_loop.sh uses release_task function" {
    grep -q 'release_task' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
}

# =============================================================================
# RESPONSE ANALYZER INTEGRATION
# =============================================================================

@test "response_analyzer extracts TASK_ID from RALPH_STATUS" {
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    cat > test_output.log << 'EOF'
Some output text
---RALPH_STATUS---
STATUS: IN_PROGRESS
TASK_ID: myproject-abc123
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 3
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Continue
---END_RALPH_STATUS---
EOF

    analyze_response "test_output.log" 1 ".test_analysis"

    run jq -r '.analysis.task_id' .test_analysis
    [ "$status" -eq 0 ]
    [ "$output" = "myproject-abc123" ]
}

@test "response_analyzer handles missing TASK_ID gracefully" {
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    cat > test_output.log << 'EOF'
---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 1
EXIT_SIGNAL: false
---END_RALPH_STATUS---
EOF

    analyze_response "test_output.log" 1 ".test_analysis"

    run jq -r '.analysis.task_id' .test_analysis
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# =============================================================================
# TEMPLATE UPDATES
# =============================================================================

@test "PROMPT.md template includes TASK_ID in status block" {
    grep -q 'TASK_ID:' "${BATS_TEST_DIRNAME}/../../templates/PROMPT.md"
}

@test "PROMPT.md template mentions beads integration" {
    grep -qi 'beads\|bd ready' "${BATS_TEST_DIRNAME}/../../templates/PROMPT.md"
}

# =============================================================================
# EDGE CASES
# =============================================================================

@test "handles empty fix_plan.md gracefully" {
    echo "" > "@fix_plan.md"
    run get_ready_task_count
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "handles malformed fix_plan.md gracefully" {
    cat > "@fix_plan.md" << 'EOF'
This is not a valid fix plan
No tasks here
Just random text
EOF
    run get_ready_task_count
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "handles special characters in task titles" {
    cat > "@fix_plan.md" << 'EOF'
- [ ] Task with "quotes" and 'apostrophes'
- [ ] Task with $pecial ch@racters!
EOF
    run get_ready_task_count
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "concurrent access to current task file" {
    # Simulate concurrent writes (basic test)
    echo "task-1" > "$CURRENT_TASK_FILE"
    local task1=$(get_current_task_id)
    echo "task-2" > "$CURRENT_TASK_FILE"
    local task2=$(get_current_task_id)

    [ "$task1" = "task-1" ]
    [ "$task2" = "task-2" ]
}
