#!/usr/bin/env bash

# date_utils.sh - Cross-platform date utility functions
# Provides consistent date formatting and arithmetic across GNU (Linux) and BSD (macOS) systems

# Get current timestamp in ISO 8601 format with seconds precision
# Returns: YYYY-MM-DDTHH:MM:SS+00:00 format
get_iso_timestamp() {
    local os_type
    os_type=$(uname)

    if [[ "$os_type" == "Darwin" ]]; then
        # macOS (BSD date)
        # Use manual formatting and add colon to timezone offset
        date -u +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/'
    else
        # Linux (GNU date) - use -u flag for UTC
        date -u -Iseconds
    fi
}

# Get time component (HH:MM:SS) for one hour from now
# Returns: HH:MM:SS format
get_next_hour_time() {
    local os_type
    os_type=$(uname)

    if [[ "$os_type" == "Darwin" ]]; then
        # macOS (BSD date) - use -v flag for date arithmetic
        date -v+1H '+%H:%M:%S'
    else
        # Linux (GNU date) - use -d flag for date arithmetic
        date -d '+1 hour' '+%H:%M:%S'
    fi
}

# Get current timestamp in a basic format (fallback)
# Returns: YYYY-MM-DD HH:MM:SS format
get_basic_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Get current Unix epoch time in seconds
# Returns: Integer seconds since 1970-01-01 00:00:00 UTC
get_epoch_seconds() {
    date +%s
}

# Cross-platform timeout command
# Usage: portable_timeout DURATION COMMAND [ARGS...]
# Duration format: NUMBER followed by optional suffix (s=seconds, m=minutes, h=hours)
# Examples: portable_timeout 30s mycommand arg1 arg2
#          portable_timeout 5m long_running_script
# Returns: Exit code of command, or 124 if timed out
portable_timeout() {
    local duration="$1"
    shift

    # Try gtimeout first (macOS with Homebrew coreutils)
    if command -v gtimeout &>/dev/null; then
        gtimeout "$duration" "$@"
        return $?
    fi

    # Try native timeout (Linux, or installed on macOS)
    if command -v timeout &>/dev/null; then
        timeout "$duration" "$@"
        return $?
    fi

    # Parse duration for perl fallback (convert to seconds)
    local seconds
    if [[ "$duration" =~ ^([0-9]+)([smh])?$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]:-s}"
        case "$unit" in
            s) seconds=$num ;;
            m) seconds=$((num * 60)) ;;
            h) seconds=$((num * 3600)) ;;
        esac
    else
        echo "Error: Invalid duration format: $duration" >&2
        return 1
    fi

    # Perl-based fallback (always available on macOS and Linux)
    # Uses alarm signal for timeout with proper exit code handling
    perl -e '
        use POSIX ":sys_wait_h";
        my $timeout = shift @ARGV;
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            exec @ARGV or die "exec failed: $!";
        }
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm $timeout;
            waitpid($pid, 0);
            alarm 0;
        };
        if ($@ eq "timeout\n") {
            kill "TERM", $pid;
            sleep 1;
            kill "KILL", $pid if kill 0, $pid;
            exit 124;
        }
        exit ($? >> 8);
    ' "$seconds" "$@"
}

# Export functions for use in other scripts
export -f get_iso_timestamp
export -f get_next_hour_time
export -f get_basic_timestamp
export -f get_epoch_seconds
export -f portable_timeout
