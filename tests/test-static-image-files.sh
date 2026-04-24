#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

test_motd() {
    local expected
    expected="$(cat <<'EOF'
System bootstrap complete.

Apply dotfiles:
  curl -fsLS https://raw.githubusercontent.com/netf/dotfiles/main/install.sh | bash

Or:
  chezmoi init --apply netf
EOF
)"

    assert_file_matches "$REPO_ROOT/files/etc/motd" "$expected"
    assert_file_missing "$REPO_ROOT/files/usr/etc/motd"
}

test_containers_policy() {
    local path="$REPO_ROOT/files/etc/containers/policy.json"

    [[ -f "$path" ]] || fail "missing file: $path"

    local compact
    compact="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))' "$path")"
    [[ "$compact" == '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"ghcr.io/netf":[{"type":"sigstoreSigned","keyPath":"/etc/containers/pubkey.pem","signedIdentity":{"type":"matchRepository"}}],"quay.io/fedora-ostree-desktops":[{"type":"insecureAcceptAnything"}],"quay.io/centos-bootc":[{"type":"insecureAcceptAnything"}]}}}' ]] || fail "unexpected contents in $path"
    assert_file_missing "$REPO_ROOT/files/usr/etc/containers/policy.json"
}

test_registries_config() {
    local expected
    expected="$(cat <<'EOF'
docker:
  ghcr.io/netf:
    use-sigstore-attachments: true
EOF
)"

    assert_file_matches "$REPO_ROOT/files/etc/containers/registries.d/ghcr-io-netf.yaml" "$expected"
    assert_file_missing "$REPO_ROOT/files/usr/etc/containers/registries.d/ghcr-io-netf.yaml"
}

test_motd
test_containers_policy
test_registries_config

echo "PASS: static-image-files"
