#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

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
    assert_file_contains "$path" "install-time encrypted root"
    assert_file_contains "$path" "one-time first-boot passphrase entry"
    assert_file_contains "$path" "automatic core bootstrap"
    assert_file_contains "$path" "explicit hardware post-install profile"
    assert_file_contains "$path" "second-boot TPM2 auto-unlock proof"
    assert_file_contains "$path" "sbsigntools"
    assert_file_not_contains "$path" "sbctl"
    assert_file_not_contains "$path" "LVFS firmware -> TPM2 -> FIDO2 -> recovery key -> wipe installer password -> fingerprint -> EC charge limit"
}

test_guide() {
    local path="$REPO_ROOT/guide.md"

    [[ -f "$path" ]] || fail "missing file: $path"
    assert_file_contains "$path" "Render encrypted installer config"
    assert_file_contains "$path" "./scripts/render-installer-config.sh > config-ci-rendered.toml"
    assert_file_contains "$path" "--type qcow2 --rootfs btrfs --config /config.toml"
    assert_file_contains "$path" "Current production contract"
    assert_file_contains "$path" "automatic core bootstrap"
    assert_file_contains "$path" "explicit hardware post-install profile"
    assert_file_not_contains "$path" "CI variant: no LUKS"
    assert_file_not_contains "$path" "cat > config-ci.toml"
}

test_historical_docs_are_marked() {
    local spec_path="$REPO_ROOT/docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md"
    local plan_path="$REPO_ROOT/docs/superpowers/plans/2026-04-23-fedora-bootc-starter-implementation.md"

    assert_file_contains "$spec_path" "**Status:** historical design reference"
    assert_file_contains "$spec_path" "docs/plans/2026-04-23-fedora-bootc-production-like-design.md"
    assert_file_contains "$spec_path" "automatic \`core\` bootstrap only"
    assert_file_contains "$spec_path" "second-boot TPM2 auto-unlock proof in CI"

    assert_file_contains "$plan_path" "**Status:** historical implementation plan"
    assert_file_contains "$plan_path" "docs/plans/2026-04-23-fedora-bootc-production-like-implementation.md"
    assert_file_contains "$plan_path" "explicit \`hardware\` post-install profile"
    assert_file_contains "$plan_path" "second-boot TPM2 auto-unlock proof"
}

run_tests() {
    local tests=("$@")
    local test_name

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(test_readme test_guide test_historical_docs_are_marked)
    fi

    for test_name in "${tests[@]}"; do
        declare -F "$test_name" >/dev/null || fail "unknown test: $test_name"
        "$test_name"
    done
}

run_tests "$@"

echo "PASS: docs"
