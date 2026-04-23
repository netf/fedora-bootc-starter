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

test_netf_bootstrap_service

echo "PASS: bootstrap-scaffold"
