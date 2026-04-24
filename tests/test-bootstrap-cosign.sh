#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/scripts/bootstrap-cosign.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

assert_contains() {
    local haystack="$1"
    local needle="$2"

    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

run_script() {
    local workdir="$1"
    shift

    set +e
    RUN_OUTPUT="$(
        cd "$workdir" &&
        "$@" 2>&1
    )"
    RUN_STATUS=$?
    set -e
}

make_stub_cosign() {
    local bindir="$1"

    mkdir -p "$bindir"
    cat >"$bindir/cosign"
    chmod +x "$bindir/cosign"
}

test_fails_when_cosign_is_missing() {
    local workdir="$TMP_ROOT/missing-cosign"
    mkdir -p "$workdir"

    run_script "$workdir" env PATH="/usr/bin:/bin" "$SCRIPT"

    [[ $RUN_STATUS -ne 0 ]] || fail "expected missing cosign check to fail"
    assert_contains "$RUN_OUTPUT" "cosign not installed"
}

test_refuses_to_overwrite_existing_key() {
    local workdir="$TMP_ROOT/existing-key"
    local bindir="$workdir/bin"
    mkdir -p "$workdir"
    touch "$workdir/cosign.key"
    make_stub_cosign "$bindir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

    run_script "$workdir" env PATH="$bindir:/usr/bin:/bin" "$SCRIPT"

    [[ $RUN_STATUS -ne 0 ]] || fail "expected existing key check to fail"
    assert_contains "$RUN_OUTPUT" "cosign.key already exists"
}

test_generates_keypair_and_prints_next_steps() {
    local workdir="$TMP_ROOT/generate"
    local bindir="$workdir/bin"
    mkdir -p "$workdir"
    make_stub_cosign "$bindir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "generate-key-pair" ]]; then
    echo "unexpected args: $*" >&2
    exit 1
fi
printf "%s\n" "PUBLIC KEY DATA" > cosign.pub
printf "%s\n" "PRIVATE KEY DATA" > cosign.key
EOF

    run_script "$workdir" env PATH="$bindir:/usr/bin:/bin" "$SCRIPT"

    [[ $RUN_STATUS -eq 0 ]] || fail "expected key generation flow to succeed"
    [[ -f "$workdir/cosign.pub" ]] || fail "expected cosign.pub to be created"
    [[ -f "$workdir/cosign.key" ]] || fail "expected cosign.key to be created"
    assert_contains "$RUN_OUTPUT" "Keypair generated."
    assert_contains "$RUN_OUTPUT" "COSIGN_PRIVATE_KEY"
    assert_contains "$RUN_OUTPUT" "PRIVATE KEY DATA"
    assert_contains "$RUN_OUTPUT" "COSIGN_PASSWORD"
}

test_allows_cosign_to_prompt_for_password() {
    local workdir="$TMP_ROOT/prompt-password"
    local bindir="$workdir/bin"
    mkdir -p "$workdir"
    make_stub_cosign "$bindir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${COSIGN_PASSWORD+x}" ]]; then
    echo "COSIGN_PASSWORD should not be preset" >&2
    exit 1
fi
printf "%s\n" "PUBLIC KEY DATA" > cosign.pub
printf "%s\n" "PRIVATE KEY DATA" > cosign.key
EOF

    run_script "$workdir" env PATH="$bindir:/usr/bin:/bin" "$SCRIPT"

    [[ $RUN_STATUS -eq 0 ]] || fail "expected cosign to manage password prompting itself"
}

test_fails_when_cosign_is_missing
test_refuses_to_overwrite_existing_key
test_generates_keypair_and_prints_next_steps
test_allows_cosign_to_prompt_for_password

echo "PASS: bootstrap-cosign"
