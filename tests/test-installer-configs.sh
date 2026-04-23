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

assert_toml_parses() {
    local path="$1"

    python3 -c "import tomllib; tomllib.load(open('$path', 'rb'))" >/dev/null \
        || fail "invalid TOML: $path"
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

assert_kernel_append_equals() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
import sys
import tomllib

path = sys.argv[1]
expected = sys.argv[2]

with open(path, "rb") as fh:
    data = tomllib.load(fh)

actual = data["customizations"]["kernel"]["append"]
if actual != expected:
    raise SystemExit(f"expected kernel append {expected!r}, got {actual!r}")
PY
}

render_template_fixture() {
    local template_path="$1"
    local output_path="$2"

    python3 - "$template_path" "$output_path" <<'PY'
import pathlib
import sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])

rendered = template_path.read_text()
replacements = {
    "{{INSTALL_LUKS_PASSPHRASE}}": "fixture-passphrase",
    "{{ADMIN_PASSWORD_HASH}}": "$6$fixture$hashed-admin-password",
    "{{EXTRA_USER_BLOCKS}}": """[[customizations.user]]
name = "root"
key = "ssh-ed25519 AAAATEST fixture-root"
""",
    "{{EXTRA_KERNEL_APPEND}}": "console=ttyS0,115200 rd.debug",
}

for needle, replacement in replacements.items():
    rendered = rendered.replace(needle, replacement)

output_path.write_text(rendered)
PY
}

test_config_toml() {
    local path="$REPO_ROOT/config.toml"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_toml_parses "$path"
    assert_file_contains "$path" "[customizations.installer.kickstart]"
    assert_file_contains "$path" "The authoritative source is config.toml.in."
    assert_file_contains "$path" "[customizations.kernel]"
    assert_file_not_contains "$path" "installer-temp-change-me"
}

test_config_ci_toml() {
    local path="$REPO_ROOT/config-ci.toml"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_toml_parses "$path"
    assert_file_contains "$path" "[[customizations.user]]"
    assert_file_contains "$path" "name = \"netf\""
    assert_file_contains "$path" "name = \"root\""
    assert_file_contains "$path" "key = \"{{CI_PUBKEY}}\""
    assert_file_contains "$path" "[customizations.kernel]"
    assert_file_contains "$path" "append = \"console=ttyS0,115200 rd.debug systemd.log_level=debug systemd.log_target=console\""
}

test_config_toml_template() {
    local path="$REPO_ROOT/config.toml.in"
    local rendered_path

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "{{INSTALL_LUKS_PASSPHRASE}}"
    assert_file_contains "$path" "{{ADMIN_PASSWORD_HASH}}"
    assert_file_contains "$path" "{{EXTRA_USER_BLOCKS}}"
    assert_file_contains "$path" "{{EXTRA_KERNEL_APPEND}}"
    assert_file_not_contains "$path" "installer-temp-change-me"

    rendered_path="$(mktemp)"
    render_template_fixture "$path" "$rendered_path"
    assert_toml_parses "$rendered_path"
    assert_file_contains "$rendered_path" "[customizations.installer.kickstart]"
    assert_file_contains "$rendered_path" "part / --grow --fstype=btrfs --encrypted --luks-version=luks2 --pbkdf=argon2id --passphrase=fixture-passphrase"
    assert_file_contains "$rendered_path" "[[customizations.user]]"
}

test_render_installer_config_script() {
    local script_path="$REPO_ROOT/scripts/render-installer-config.sh"
    local rendered_path
    local expected_kernel_append

    [[ -f "$script_path" ]] || fail "missing file: $script_path"
    assert_file_contains "$script_path" "INSTALL_LUKS_PASSPHRASE"
    assert_file_contains "$script_path" "ADMIN_PASSWORD_HASH"

    rendered_path="$(mktemp)"
    expected_kernel_append=$'console=ttyS0,115200 rd.debug rd.break="pre-mount" path=C:\\temp\\logs'
    INSTALL_LUKS_PASSPHRASE="rendered-passphrase" \
    ADMIN_PASSWORD_HASH='$6$fixture$hashed-admin-password' \
    EXTRA_USER_BLOCKS=$'[[customizations.user]]\nname = "root"\nkey = "ssh-ed25519 AAAATEST rendered-root"\n' \
    EXTRA_KERNEL_APPEND="$expected_kernel_append" \
    "$script_path" >"$rendered_path"

    assert_toml_parses "$rendered_path"
    assert_file_contains "$rendered_path" "[customizations.installer.kickstart]"
    assert_file_contains "$rendered_path" "part / --grow --fstype=btrfs --encrypted --luks-version=luks2 --pbkdf=argon2id --passphrase=rendered-passphrase"
    assert_file_contains "$rendered_path" "[[customizations.user]]"
    assert_file_contains "$rendered_path" "[customizations.kernel]"
    assert_kernel_append_equals "$rendered_path" "$expected_kernel_append"
}

test_render_installer_config_script_rejects_unsafe_passphrase() {
    local script_path="$REPO_ROOT/scripts/render-installer-config.sh"

    [[ -f "$script_path" ]] || fail "missing file: $script_path"
    assert_command_fails_contains "unsafe INSTALL_LUKS_PASSPHRASE" \
        env \
        INSTALL_LUKS_PASSPHRASE="rendered passphrase" \
        ADMIN_PASSWORD_HASH='$6$fixture$hashed-admin-password' \
        EXTRA_USER_BLOCKS="" \
        EXTRA_KERNEL_APPEND="console=ttyS0,115200 rd.debug" \
        "$script_path"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(
            test_config_toml_template
            test_render_installer_config_script
            test_render_installer_config_script_rejects_unsafe_passphrase
            test_config_toml
            test_config_ci_toml
        )
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: installer-configs"
