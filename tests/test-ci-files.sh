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

test_build_workflow() {
    local path="$REPO_ROOT/.github/workflows/build.yml"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "name: build"
    assert_file_contains "$path" "workflow_dispatch:"
    assert_file_contains "$path" "FEDORA_VERSION: \${{ inputs.fedora_version || '44' }}"
    assert_file_contains "$path" "lint:"
    assert_file_contains "$path" "build:"
    assert_file_contains "$path" "e2e-vm:"
    assert_file_contains "$path" "uses: hadolint/hadolint-action@v3.3.0"
    assert_file_contains "$path" "uses: sigstore/cosign-installer@v3"
    assert_file_contains "$path" "config-ci-rendered.toml"
    assert_file_contains "$path" "uses: actions/upload-artifact@v4"
    assert_file_contains "$path" "podman login --compat-auth-file \"\$HOME/.docker/config.json\""
    assert_file_contains "$path" "sbverify"
    assert_file_not_contains "$path" "sbctl"
    assert_file_contains "$path" "files/etc/containers/registries.d/"
    assert_file_contains "$path" "/etc/containers/policy.json"
    assert_file_not_contains "$path" "/usr/etc"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_build_workflow)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: ci-files"
