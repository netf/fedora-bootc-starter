#!/usr/bin/env bash
# Shared helpers for repo tests. Source from each tests/test-*.sh.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_contains() {
    local path="$1"
    local needle="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" == *"$needle"* ]] || fail "expected $path to contain: $needle"
}

assert_file_not_contains() {
    local path="$1"
    local needle="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" != *"$needle"* ]] || fail "expected $path to not contain: $needle"
}

assert_file_matches() {
    local path="$1"
    local expected="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" == "$expected" ]] || fail "unexpected contents in $path"
}

assert_file_missing() {
    local path="$1"

    [[ ! -e "$path" ]] || fail "expected path to be absent: $path"
}

assert_command_fails_contains() {
    local needle="$1"
    shift

    local output
    if output="$("$@" 2>&1)"; then
        fail "expected command to fail: $*"
    fi

    [[ "$output" == *"$needle"* ]] || fail "expected command failure to contain: $needle"
}

assert_command_succeeds_contains() {
    local needle="$1"
    shift

    local output
    if ! output="$("$@" 2>&1)"; then
        fail "expected command to succeed: $*"
    fi

    [[ "$output" == *"$needle"* ]] || fail "expected command output to contain: $needle"
}
