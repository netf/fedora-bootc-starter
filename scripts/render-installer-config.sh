#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$REPO_ROOT/config.toml.in"

: "${INSTALL_LUKS_PASSPHRASE:?INSTALL_LUKS_PASSPHRASE is required}"
: "${ADMIN_PASSWORD_HASH:?ADMIN_PASSWORD_HASH is required}"
: "${EXTRA_USER_BLOCKS?EXTRA_USER_BLOCKS must be set}"
: "${EXTRA_KERNEL_APPEND?EXTRA_KERNEL_APPEND must be set}"

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

def default_user_block(password_hash: str) -> str:
    if not password_hash:
        fail("ADMIN_PASSWORD_HASH must be set when EXTRA_USER_BLOCKS is empty")
    escaped_hash = escape_toml_basic_string(password_hash)
    return (
        "[[customizations.user]]\n"
        'name = "netf"\n'
        'groups = ["wheel"]\n'
        f'password = "{escaped_hash}"\n'
    )


user_blocks = os.environ["EXTRA_USER_BLOCKS"]
if not user_blocks.strip():
    user_blocks = default_user_block(os.environ["ADMIN_PASSWORD_HASH"])

replacements = {
    "{{INSTALL_LUKS_PASSPHRASE}}": validate_passphrase(os.environ["INSTALL_LUKS_PASSPHRASE"]),
    "{{EXTRA_USER_BLOCKS}}": user_blocks,
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
