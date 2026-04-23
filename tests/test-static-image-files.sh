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

test_motd() {
    local expected
    expected="$(cat <<'EOF'
┌─────────────────────────────────────────────────────────────┐
│  System bootstrap complete. To apply dotfiles:              │
│                                                             │
│    curl -fsLS https://raw.githubusercontent.com/netf/dotfiles/main/install.sh | bash
│                                                             │
│  Or: chezmoi init --apply netf                              │
└─────────────────────────────────────────────────────────────┘
EOF
)"

    assert_file_matches "$REPO_ROOT/files/usr/etc/motd" "$expected"
}

test_motd

echo "PASS: static-image-files"
