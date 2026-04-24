#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

test_readme() {
    local path="$REPO_ROOT/README.md"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "Signed Fedora Kinoite bootc image + unattended installer"
    assert_file_contains "$path" "## Quickstart (day 0, fresh laptop)"
    assert_file_contains "$path" "## Day 2"
    assert_file_contains "$path" "## What's in the image"
    assert_file_contains "$path" "## Development"
    assert_file_contains "$path" "## Known sharp edges"
    assert_file_contains "$path" "## References"
    assert_file_contains "$path" "ghcr.io/netf/fedora-bootc-starter:44"
    assert_file_contains "$path" "cosign verify --key cosign.pub ghcr.io/netf/fedora-bootc-starter:44"
    assert_file_contains "$path" "sbsigntools"
    assert_file_not_contains "$path" "sbctl"
}

test_guide() {
    local path="$REPO_ROOT/guide.md"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "Render encrypted installer config"
    assert_file_contains "$path" "./scripts/render-installer-config.sh > config-ci-rendered.toml"
    assert_file_contains "$path" "--type qcow2 --rootfs btrfs --config /config.toml"
    assert_file_not_contains "$path" "CI variant: no LUKS"
    assert_file_not_contains "$path" "cat > config-ci.toml"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_readme test_guide)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: docs"
