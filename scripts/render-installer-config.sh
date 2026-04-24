#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/config.toml.in"

: "${INSTALL_LUKS_PASSPHRASE:?INSTALL_LUKS_PASSPHRASE is required}"
: "${ADMIN_PASSWORD_HASH:?ADMIN_PASSWORD_HASH is required}"
: "${EXTRA_SSHKEY_LINES=}"
: "${EXTRA_KERNEL_APPEND?EXTRA_KERNEL_APPEND must be set}"
export EXTRA_SSHKEY_LINES

[[ -f "$TEMPLATE_PATH" ]] || {
    echo "ERROR: missing template: $TEMPLATE_PATH" >&2
    exit 1
}

TEMPLATE_PATH="$TEMPLATE_PATH" python3 - <<'PY'
import json
import os
import pathlib
import re
import sys
import tomllib

template_path = pathlib.Path(os.environ["TEMPLATE_PATH"])
rendered = template_path.read_text()


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_passphrase(value: str) -> str:
    if not value:
        fail("INSTALL_LUKS_PASSPHRASE must not be empty")
    if not re.fullmatch(r"[A-Za-z0-9._%+=,:@/-]+", value):
        fail(
            "unsafe INSTALL_LUKS_PASSPHRASE: only [A-Za-z0-9._%+=,:@/-] are allowed"
        )
    return value


def escape_toml_basic_string(value: str) -> str:
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        fail("EXTRA_KERNEL_APPEND must not contain control characters")
    return json.dumps(value)[1:-1]

def validate_sshkey_lines(value: str) -> str:
    # Each non-empty line must start with `sshkey --username=` so we can't
    # accidentally inject unrelated kickstart directives (reboot, clearpart, ...).
    for line in value.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("sshkey --username="):
            fail(
                'EXTRA_SSHKEY_LINES entries must start with `sshkey --username=`; '
                f"got: {stripped!r}"
            )
    return value


replacements = {
    "{{INSTALL_LUKS_PASSPHRASE}}": validate_passphrase(os.environ["INSTALL_LUKS_PASSPHRASE"]),
    "{{ADMIN_PASSWORD_HASH}}": os.environ["ADMIN_PASSWORD_HASH"],
    "{{EXTRA_SSHKEY_LINES}}": validate_sshkey_lines(os.environ.get("EXTRA_SSHKEY_LINES", "")),
    "{{EXTRA_KERNEL_APPEND}}": escape_toml_basic_string(os.environ["EXTRA_KERNEL_APPEND"]),
}

for needle, replacement in replacements.items():
    rendered = rendered.replace(needle, replacement)

leftover_placeholder = re.search(r"{{[^{}]+}}", rendered)
if leftover_placeholder:
    fail(
        "unresolved template placeholders remain: "
        f"{leftover_placeholder.group(0)}"
    )

try:
    tomllib.loads(rendered)
except tomllib.TOMLDecodeError as exc:
    fail(f"rendered TOML is invalid: {exc}")

sys.stdout.write(rendered)
PY
