#!/usr/bin/env bash
# One-shot helper to generate a cosign keypair and print the values you need
# to add to GitHub Actions secrets. Run from the repo root.
#
# Outputs:
#   cosign.pub  — commit this to the repo
#   cosign.key  — KEEP SECRET. Paste contents as COSIGN_PRIVATE_KEY in GHA.
#   password    — paste as COSIGN_PASSWORD in GHA.
set -euo pipefail

if ! command -v cosign >/dev/null 2>&1; then
    echo "ERROR: cosign not installed. brew install cosign (macOS) or" \
         "see https://docs.sigstore.dev/cosign/installation/" >&2
    exit 1
fi

if [[ -f cosign.key ]]; then
    echo "ERROR: cosign.key already exists. Refusing to overwrite." >&2
    echo "If you want to rotate, move the old one aside first." >&2
    exit 1
fi

echo "→ Generating cosign keypair. You will be prompted for a password."
echo "  Choose a strong password; store it in your password manager."
echo ""

COSIGN_PASSWORD="" cosign generate-key-pair

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Keypair generated."
echo ""
echo " 1. The public key cosign.pub should be committed:"
echo ""
echo "      git add cosign.pub"
echo "      git commit -m 'chore: add cosign public key for image signing'"
echo ""
echo " 2. Add these to GitHub Secrets at:"
echo "      https://github.com/netf/fedora-bootc-starter/settings/secrets/actions"
echo ""
echo "    COSIGN_PRIVATE_KEY — paste contents of cosign.key:"
echo "    ─────────── begin cosign.key ───────────"
cat cosign.key
echo "    ──────────── end cosign.key ────────────"
echo ""
echo "    COSIGN_PASSWORD — the password you entered above."
echo ""
echo " 3. After adding both secrets, store cosign.key offline"
echo "    (password manager) and DELETE the local file:"
echo ""
echo "      shred -u cosign.key     # Linux"
echo "      rm -P cosign.key        # macOS"
echo ""
echo "════════════════════════════════════════════════════════════════"
