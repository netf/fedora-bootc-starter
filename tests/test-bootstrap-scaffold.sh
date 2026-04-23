#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_matches() {
    local path="$1"
    local expected="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" == "$expected" ]] || fail "unexpected contents in $path"
}

assert_file_contains() {
    local path="$1"
    local needle="$2"

    [[ -f "$path" ]] || fail "missing file: $path"

    local actual
    actual="$(<"$path")"
    [[ "$actual" == *"$needle"* ]] || fail "expected $path to contain: $needle"
}

test_netf_bootstrap_service() {
    local expected
    expected="$(cat <<'EOF'
[Unit]
Description=Piotr first-boot bootstrap (LUKS enrollment, firmware, EC tuning)
After=systemd-user-sessions.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/bootstrap/.all.done

[Service]
Type=oneshot
ExecStart=/usr/share/bootstrap/run-all.sh --interactive
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
)"

    assert_file_matches "$REPO_ROOT/files/usr/lib/systemd/system/netf-bootstrap.service" "$expected"
}

test_common_library() {
    local path="$REPO_ROOT/bootstrap/lib/common.sh"

    assert_file_contains "$path" "set -euo pipefail"
    assert_file_contains "$path" "log()  { printf '\\e[1;34m[bootstrap]\\e[0m %s\\n' \"\$*\" >&2; }"
    assert_file_contains "$path" "require_root() {"
    assert_file_contains "$path" "is_framework_laptop() {"
    assert_file_contains "$path" "is_vm() {"
    assert_file_contains "$path" "has_tpm2() {"
    assert_file_contains "$path" "has_yubikey() {"
    assert_file_contains "$path" "has_fingerprint_reader() {"
    assert_file_contains "$path" "has_encrypted_root() {"
    assert_file_contains "$path" "luks_device() {"
    assert_file_contains "$path" "crypt_mapper_name() {"
    assert_file_contains "$path" "has_token() {"
    assert_file_contains "$path" "marker_done()  { [[ -f \"/var/lib/bootstrap/.\${1}.done\" ]]; }"
    assert_file_contains "$path" "marker_write() { mkdir -p /var/lib/bootstrap && touch \"/var/lib/bootstrap/.\${1}.done\"; }"
}

test_sanity_script() {
    local path="$REPO_ROOT/bootstrap/00-sanity.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && exit 0"
    assert_file_contains "$path" "log \"hostname: \$(hostname)\""
    assert_file_contains "$path" "log \"kernel:   \$(uname -r)\""
    assert_file_contains "$path" "for tool in systemd-cryptenroll cryptsetup fwupdmgr; do"
    assert_file_contains "$path" "for tool in tpm2_pcrread ykman fprintd-enroll framework_tool; do"
    assert_file_contains "$path" "if is_framework_laptop; then"
    assert_file_contains "$path" "elif is_vm; then"
    assert_file_contains "$path" "marker_write \"00-sanity\""
}

test_firmware_update_script() {
    local path="$REPO_ROOT/bootstrap/05-firmware-update.sh"

    assert_file_contains "$path" "source /usr/share/bootstrap/lib/common.sh"
    assert_file_contains "$path" "require_root"
    assert_file_contains "$path" "[[ \"\${1:-}\" == \"--check\" ]] && CHECK=1"
    assert_file_contains "$path" "if is_vm; then"
    assert_file_contains "$path" "skip \"running in a VM - no real firmware to update\""
    assert_file_contains "$path" "fwupdmgr refresh --force >/dev/null 2>&1 || warn \"fwupd refresh failed (no network?)\""
    assert_file_contains "$path" "PENDING=\$(fwupdmgr get-updates 2>/dev/null"
    assert_file_contains "$path" "if [[ \$PENDING -eq 0 ]]; then"
    assert_file_contains "$path" "if [[ \$CHECK -eq 1 ]]; then"
    assert_file_contains "$path" "fwupdmgr update -y --no-reboot-check || warn \"some updates deferred to next boot\""
    assert_file_contains "$path" "marker_write \"05-firmware\""
}

test_netf_bootstrap_service
test_common_library
test_sanity_script
test_firmware_update_script

echo "PASS: bootstrap-scaffold"
