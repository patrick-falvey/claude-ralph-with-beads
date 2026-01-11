#!/usr/bin/env bats
# Unit tests for portable_timeout function
# Ensures cross-platform timeout functionality works on macOS and Linux

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    # Source date_utils for portable_timeout
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"

    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# Basic functionality tests

@test "portable_timeout executes command successfully" {
    run portable_timeout 5s echo "hello"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "hello" ]]
}

@test "portable_timeout returns command exit code" {
    run portable_timeout 5s bash -c 'exit 42'
    [[ "$status" -eq 42 ]]
}

@test "portable_timeout handles seconds suffix" {
    run portable_timeout 2s echo "seconds"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "seconds" ]]
}

@test "portable_timeout handles minutes suffix" {
    run portable_timeout 1m echo "minutes"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "minutes" ]]
}

@test "portable_timeout handles no suffix (defaults to seconds)" {
    run portable_timeout 2 echo "no suffix"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "no suffix" ]]
}

@test "portable_timeout passes multiple arguments to command" {
    run portable_timeout 5s echo "arg1" "arg2" "arg3"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "arg1 arg2 arg3" ]]
}

# Timeout behavior tests

@test "portable_timeout terminates long-running command" {
    # This test verifies timeout actually works
    # Command sleeps for 10 seconds but timeout is 1 second
    run portable_timeout 1s sleep 10
    # Exit code 124 indicates timeout
    [[ "$status" -eq 124 ]]
}

@test "portable_timeout returns 124 on timeout" {
    run portable_timeout 1s bash -c 'sleep 10; echo "should not see this"'
    [[ "$status" -eq 124 ]]
    # Output should be empty since command was killed
    [[ -z "$output" || "$output" != *"should not see this"* ]]
}

# Error handling tests

@test "portable_timeout rejects invalid duration format" {
    run portable_timeout "abc" echo "test"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid duration format"* ]]
}

@test "portable_timeout rejects negative duration" {
    run portable_timeout "-5s" echo "test"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid duration format"* ]]
}

@test "portable_timeout rejects empty duration" {
    run portable_timeout "" echo "test"
    [[ "$status" -ne 0 ]]
}

# Integration tests

@test "portable_timeout works with complex bash commands" {
    run portable_timeout 5s bash -c 'for i in 1 2 3; do echo $i; done'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1"* ]]
    [[ "$output" == *"2"* ]]
    [[ "$output" == *"3"* ]]
}

@test "portable_timeout works with pipes in bash -c" {
    run portable_timeout 5s bash -c 'echo "hello world" | wc -w'
    [[ "$status" -eq 0 ]]
    # wc -w output varies but should contain 2
    [[ "$output" == *"2"* ]]
}

@test "portable_timeout preserves stdout and stderr" {
    run portable_timeout 5s bash -c 'echo "stdout"; echo "stderr" >&2'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stdout"* ]]
    [[ "$output" == *"stderr"* ]]
}

@test "portable_timeout function is exported" {
    # Verify the function is available after sourcing
    run bash -c 'source '"${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"' && type portable_timeout'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"function"* ]]
}
