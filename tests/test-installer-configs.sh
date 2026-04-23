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

assert_toml_parses() {
    local path="$1"

    python3 -c "import tomllib; tomllib.load(open('$path', 'rb'))" >/dev/null \
        || fail "invalid TOML: $path"
}

test_config_toml() {
    local path="$REPO_ROOT/config.toml"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_toml_parses "$path"
    assert_file_contains "$path" "[customizations.installer.kickstart]"
    assert_file_contains "$path" "keyboard --xlayouts='pl'"
    assert_file_contains "$path" "timezone Europe/Warsaw --utc"
    assert_file_contains "$path" "part / --grow --fstype=btrfs --encrypted --luks-version=luks2 --pbkdf=argon2id --passphrase=installer-temp-change-me"
    assert_file_contains "$path" "user --name=netf --groups=wheel --iscrypted"
    assert_file_contains "$path" "disable = [\"org.fedoraproject.Anaconda.Modules.Users\"]"
    assert_file_contains "$path" "volume_id = \"FEDORA-BOOTC-STARTER\""
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_config_toml)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: installer-configs"
