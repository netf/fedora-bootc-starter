# fedora-bootc-starter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a signed, CI-tested Fedora Kinoite bootc image for Framework Laptop 13 Pro, with unattended installer ISO and idempotent first-boot bootstrap.

**Architecture:** Single bootc image built FROM `quay.io/fedora-ostree-desktops/kinoite:${FEDORA_VERSION}` (default 44). Build-time: package layering, `framework_tool` built from source, initramfs regenerated with TPM2/FIDO2 modules, bootstrap scripts embedded at `/usr/share/bootstrap/`. Install-time: kickstart via bootc-image-builder → LUKS2/argon2id on btrfs. First-boot: systemd oneshot runs numbered bootstrap scripts (firmware → TPM2 → FIDO2 → recovery → wipe installer pw → fingerprint → EC). CI gates: lint → build+smoke → e2e-vm (qcow2 + swtpm + QEMU).

**Tech Stack:** Fedora 44 bootc, podman, bootc-image-builder, QEMU/KVM, swtpm, cosign (local keypair), GitHub Actions, shellcheck/hadolint/yamllint for local validation.

**Reference:** `docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md` is the authoritative spec. `guide.md` at repo root is original design reference.

**Environment note:** Authoring happens on macOS — `podman build` and `bootc-image-builder` cannot run locally. The CI workflow is the canonical build path; local validation = static checks only (`shellcheck`, `bash -n`, `yamllint`, `hadolint` if available).

---

## Phase 1 — Prerequisites (repo scaffolding + cosign bootstrap)

### Task 1: Create `.gitignore`

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write the file**

```
# cosign private material — NEVER commit
cosign.key
cosign.password

# CI keypair (regenerated per run)
ci-key
ci-key.pub

# bootc-image-builder output
output/
*.qcow2
*.iso

# local build artefacts
*.tar
*.tar.zst

# editor
.DS_Store
.idea/
.vscode/
*.swp

# python cache that tooling may produce
__pycache__/
*.pyc
```

- [ ] **Step 2: Verify no accidentally-committed secrets**

```bash
git ls-files | grep -E '^(cosign\.key|ci-key)$' || echo "✓ no secret files tracked"
```

Expected: `✓ no secret files tracked`

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore for secrets, build artefacts, editor noise"
```

---

### Task 2: Create `.shellcheckrc`

**Files:**
- Create: `.shellcheckrc`

- [ ] **Step 1: Write the file**

```
# Follow source= directives (for `source /usr/share/bootstrap/lib/common.sh`)
external-sources=true

# Allow SCRIPTDIR/SCRIPT_DIR style patterns
disable=SC1091
```

- [ ] **Step 2: Commit**

```bash
git add .shellcheckrc
git commit -m "chore: add shellcheck config (external sources, SC1091 allow)"
```

---

### Task 3: Create `.yamllint`

**Files:**
- Create: `.yamllint`

- [ ] **Step 1: Write the file**

```yaml
extends: default

rules:
  line-length:
    max: 160
    level: warning
  truthy:
    # GitHub Actions 'on:' keyword trips default truthy rule
    allowed-values: ['true', 'false', 'on', 'off']
  document-start: disable
  comments:
    min-spaces-from-content: 1
```

- [ ] **Step 2: Commit**

```bash
git add .yamllint
git commit -m "chore: add yamllint config (relaxed line length, allow GHA on:)"
```

---

### Task 4: Write `scripts/bootstrap-cosign.sh`

**Files:**
- Create: `scripts/bootstrap-cosign.sh`

- [ ] **Step 1: Write the file**

```bash
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
```

- [ ] **Step 2: Make executable and lint**

```bash
chmod +x scripts/bootstrap-cosign.sh
shellcheck scripts/bootstrap-cosign.sh
bash -n scripts/bootstrap-cosign.sh
```

Expected: shellcheck silent (no findings), bash -n silent (parse clean).

- [ ] **Step 3: Commit**

```bash
git add scripts/bootstrap-cosign.sh
git commit -m "feat: add cosign keypair bootstrap script"
```

---

### Task 5: **USER ACTION** — Run cosign bootstrap

- [ ] **Step 1: User runs the bootstrap**

```bash
./scripts/bootstrap-cosign.sh
```

- [ ] **Step 2: User commits `cosign.pub`**

```bash
git add cosign.pub
git commit -m "chore: add cosign public key for image signing"
```

- [ ] **Step 3: User adds GitHub Secrets**

At `https://github.com/netf/fedora-bootc-starter/settings/secrets/actions`:
- `COSIGN_PRIVATE_KEY` = contents of `cosign.key`
- `COSIGN_PASSWORD` = password chosen during generation

- [ ] **Step 4: User deletes local `cosign.key`**

```bash
rm -P cosign.key   # macOS
# or
shred -u cosign.key  # Linux
```

- [ ] **Step 5: Verify `cosign.pub` is tracked and `cosign.key` is not**

```bash
git ls-files | grep cosign
```

Expected: only `cosign.pub` appears.

---

## Phase 2 — Static image-side files

### Task 6: Create `files/usr/etc/motd`

**Files:**
- Create: `files/usr/etc/motd`

- [ ] **Step 1: Write the file** (plain multi-line, no backslash continuations)

```
┌─────────────────────────────────────────────────────────────┐
│  System bootstrap complete. To apply dotfiles:              │
│                                                             │
│    curl -fsLS https://raw.githubusercontent.com/netf/dotfiles/main/install.sh | bash
│                                                             │
│  Or: chezmoi init --apply netf                              │
└─────────────────────────────────────────────────────────────┘
```

- [ ] **Step 2: Commit**

```bash
git add files/usr/etc/motd
git commit -m "feat: add motd with dotfiles handoff instructions"
```

---

### Task 7: Create `files/usr/etc/containers/policy.json`

**Files:**
- Create: `files/usr/etc/containers/policy.json`

- [ ] **Step 1: Write the file**

```json
{
  "default": [{"type": "insecureAcceptAnything"}],
  "transports": {
    "docker": {
      "ghcr.io/netf": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/usr/etc/containers/pubkey.pem",
          "signedIdentity": {"type": "matchRepository"}
        }
      ],
      "quay.io/fedora-ostree-desktops": [{"type": "insecureAcceptAnything"}],
      "quay.io/centos-bootc": [{"type": "insecureAcceptAnything"}]
    }
  }
}
```

- [ ] **Step 2: Validate JSON**

```bash
python3 -m json.tool files/usr/etc/containers/policy.json > /dev/null && echo "✓ valid JSON"
```

Expected: `✓ valid JSON`.

- [ ] **Step 3: Commit**

```bash
git add files/usr/etc/containers/policy.json
git commit -m "feat: add containers policy.json enforcing cosign for ghcr.io/netf"
```

---

### Task 8: Create `files/usr/etc/containers/registries.d/ghcr-io-netf.yaml`

**Files:**
- Create: `files/usr/etc/containers/registries.d/ghcr-io-netf.yaml`

- [ ] **Step 1: Write the file**

```yaml
docker:
  ghcr.io/netf:
    use-sigstore-attachments: true
```

- [ ] **Step 2: Validate YAML**

```bash
yamllint files/usr/etc/containers/registries.d/ghcr-io-netf.yaml
```

Expected: no output (clean).

- [ ] **Step 3: Commit**

```bash
git add files/usr/etc/containers/registries.d/ghcr-io-netf.yaml
git commit -m "feat: configure sigstore attachments for ghcr.io/netf"
```

---

### Task 9: Create `files/usr/lib/systemd/system/netf-bootstrap.service`

**Files:**
- Create: `files/usr/lib/systemd/system/netf-bootstrap.service`

- [ ] **Step 1: Write the file**

```ini
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
```

- [ ] **Step 2: Commit**

```bash
git add files/usr/lib/systemd/system/netf-bootstrap.service
git commit -m "feat: add netf-bootstrap.service (first-boot oneshot)"
```

---

## Phase 3 — Bootstrap library & scripts

### Task 10: Create `bootstrap/lib/common.sh`

**Files:**
- Create: `bootstrap/lib/common.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Shared helpers for first-boot bootstrap scripts.
# Sourced by every bootstrap/NN-*.sh — do not `exec` or exit on source.
set -euo pipefail

log()  { printf '\e[1;34m[bootstrap]\e[0m %s\n' "$*" >&2; }
ok()   { printf '\e[1;32m[   ok   ]\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33m[  warn  ]\e[0m %s\n' "$*" >&2; }
skip() { printf '\e[1;36m[  skip  ]\e[0m %s\n' "$*" >&2; }
err()  { printf '\e[1;31m[  fail  ]\e[0m %s\n' "$*" >&2; exit 2; }

require_root() {
    [[ $EUID -eq 0 ]] || err "must run as root"
}

# ─── Hardware detection ────────────────────────────────────────────────
# Return 0 if applicable, 1 if not. Scripts use these to skip gracefully.

is_framework_laptop() {
    [[ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" == "Framework" ]]
}

is_vm() {
    local vendor
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
    [[ "$vendor" =~ (QEMU|KVM|innotek|VMware|Xen|Microsoft\ Corporation) ]]
}

has_tpm2() {
    [[ -e /dev/tpm0 || -e /dev/tpmrm0 ]] \
        && command -v tpm2_pcrread >/dev/null 2>&1 \
        && tpm2_pcrread sha256:7 >/dev/null 2>&1
}

has_yubikey() {
    command -v ykman >/dev/null 2>&1 && [[ -n "$(ykman list 2>/dev/null)" ]]
}

has_fingerprint_reader() {
    lsusb 2>/dev/null | grep -iqE "goodix|synaptics.*fingerprint|validity"
}

has_encrypted_root() {
    findmnt -no SOURCE / 2>/dev/null | grep -q "^/dev/mapper/luks-"
}

# ─── LUKS helpers ──────────────────────────────────────────────────────

luks_device() {
    local mapper
    mapper=$(findmnt -no SOURCE / | sed 's,.*/,,')
    cryptsetup status "$mapper" | awk '/device:/ {print $2}'
}

crypt_mapper_name() {
    findmnt -no SOURCE / | sed 's,.*/,,'
}

has_token() {
    local dev="$1" token="$2"
    cryptsetup luksDump "$dev" | grep -q "$token"
}

# ─── Marker files ──────────────────────────────────────────────────────
# Per-step idempotency markers under /var/lib/bootstrap/.

marker_done()  { [[ -f "/var/lib/bootstrap/.${1}.done" ]]; }
marker_write() { mkdir -p /var/lib/bootstrap && touch "/var/lib/bootstrap/.${1}.done"; }
```

- [ ] **Step 2: Lint**

```bash
shellcheck bootstrap/lib/common.sh
bash -n bootstrap/lib/common.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/lib/common.sh
git commit -m "feat(bootstrap): add lib/common.sh (logging, hardware detection, LUKS helpers)"
```

---

### Task 11: Create `bootstrap/00-sanity.sh`

**Files:**
- Create: `bootstrap/00-sanity.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Prereq sanity check — always runs. Logs kernel/bootc/hardware, verifies
# critical tooling is present. Hardware-dependent tooling may be missing
# in a VM; that's fine and we'll say so.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

[[ "${1:-}" == "--check" ]] && exit 0   # sanity always passes --check

log "hostname: $(hostname)"
log "kernel:   $(uname -r)"

# bootc status parsing — avoid fragile jq paths; use plain output.
if bootc_line=$(bootc status 2>/dev/null | awk '/Booted image:/ {print; exit}'); then
    log "bootc:    ${bootc_line:-unknown}"
else
    warn "bootc status unavailable (may be non-bootc system)"
fi

# Critical tools — must be present on every run
for tool in systemd-cryptenroll cryptsetup fwupdmgr; do
    command -v "$tool" >/dev/null || warn "missing: $tool"
done

# Hardware-dependent tools — OK to miss on non-Framework / non-YubiKey hosts
for tool in tpm2_pcrread ykman fprintd-enroll framework_tool; do
    command -v "$tool" >/dev/null || skip "tool not present (OK outside Framework): $tool"
done

if is_framework_laptop; then
    ok "Framework Laptop detected"
    if ! has_tpm2; then
        err "TPM2 not functional — enable Intel PTT in BIOS"
    fi
    if framework_tool --versions >/dev/null 2>&1; then
        ok "framework_tool can talk to EC"
    else
        warn "framework_tool can't reach EC — check cros_ec kernel module"
    fi
elif is_vm; then
    skip "running in a VM — hardware checks deferred"
    if has_tpm2; then
        ok "TPM2 present (swtpm or passthrough)"
    fi
else
    warn "unknown hardware — proceeding with best-effort detection"
fi

marker_write "00-sanity"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/00-sanity.sh
bash -n bootstrap/00-sanity.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/00-sanity.sh
git commit -m "feat(bootstrap): add 00-sanity.sh (tooling + hardware checks)"
```

---

### Task 12: Create `bootstrap/05-firmware-update.sh`

**Files:**
- Create: `bootstrap/05-firmware-update.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Pull latest firmware from LVFS and apply. Framework supports EC/BIOS/retimer/PD
# and expansion cards via fwupd. In VMs this is a no-op (nothing to update).
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if is_vm; then
    skip "running in a VM — no real firmware to update"
    marker_write "05-firmware"
    exit 0
fi

fwupdmgr refresh --force >/dev/null 2>&1 || warn "fwupd refresh failed (no network?)"

PENDING=$(fwupdmgr get-updates 2>/dev/null | grep -c '^ •' || true)

if [[ $PENDING -eq 0 ]]; then
    ok "Firmware up to date"
    marker_write "05-firmware"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "$PENDING firmware update(s) pending"
    exit 1
fi

log "Applying $PENDING firmware update(s). System may reboot."
fwupdmgr update -y --no-reboot-check || warn "some updates deferred to next boot"

marker_write "05-firmware"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/05-firmware-update.sh
bash -n bootstrap/05-firmware-update.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/05-firmware-update.sh
git commit -m "feat(bootstrap): add 05-firmware-update.sh (LVFS refresh + apply)"
```

---

### Task 13: Create `bootstrap/10-luks-tpm2.sh`

**Files:**
- Create: `bootstrap/10-luks-tpm2.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Enroll TPM2 as a LUKS keyslot bound to PCR 7 (secure boot) + 11 (kernel/initrd).
# Rebinding needed after kernel updates — see day-2 command in README.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted — TPM2 enrollment N/A"
    marker_write "10-tpm2"
    exit 0
fi
if ! has_tpm2; then
    skip "no functional TPM2 on this machine — skipping enrollment"
    marker_write "10-tpm2"
    exit 0
fi

DEV=$(luks_device)
MAPPER=$(crypt_mapper_name)

if has_token "$DEV" "systemd-tpm2"; then
    ok "TPM2 already enrolled on $DEV"
    marker_write "10-tpm2"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "TPM2 NOT enrolled on $DEV"
    exit 1
fi

log "Enrolling TPM2 on $DEV (PCRs 7+11). Prompts for current LUKS passphrase."
systemd-cryptenroll "$DEV" --tpm2-device=auto --tpm2-pcrs=7+11

if ! grep -qE "^${MAPPER}.*tpm2-device=auto" /etc/crypttab; then
    log "Patching /etc/crypttab for TPM2 auto-unlock"
    sed -ri "s|^(${MAPPER}\s+\S+\s+\S+)(\s+.*)?$|\1 tpm2-device=auto|" /etc/crypttab
fi

ok "TPM2 enrolled"
marker_write "10-tpm2"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/10-luks-tpm2.sh
bash -n bootstrap/10-luks-tpm2.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/10-luks-tpm2.sh
git commit -m "feat(bootstrap): add 10-luks-tpm2.sh (TPM2 keyslot, PCRs 7+11)"
```

---

### Task 14: Create `bootstrap/11-luks-fido2.sh`

**Files:**
- Create: `bootstrap/11-luks-fido2.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Enroll FIDO2 (YubiKey) as a LUKS keyslot with PIN + user presence (touch).
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted — FIDO2 enrollment N/A"
    marker_write "11-fido2"
    exit 0
fi
if ! has_yubikey; then
    skip "no YubiKey detected — plug one in and re-run if you want FIDO2"
    marker_write "11-fido2"
    exit 0
fi

DEV=$(luks_device)

if has_token "$DEV" "systemd-fido2"; then
    ok "FIDO2 already enrolled on $DEV"
    marker_write "11-fido2"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "FIDO2 NOT enrolled"
    exit 1
fi

log "Enrolling FIDO2 on $DEV with PIN + user presence (touch the YubiKey when it blinks)"
systemd-cryptenroll "$DEV" \
    --fido2-device=auto \
    --fido2-with-client-pin=yes \
    --fido2-with-user-presence=yes

ok "FIDO2 enrolled"
marker_write "11-fido2"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/11-luks-fido2.sh
bash -n bootstrap/11-luks-fido2.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/11-luks-fido2.sh
git commit -m "feat(bootstrap): add 11-luks-fido2.sh (YubiKey FIDO2 keyslot)"
```

---

### Task 15: Create `bootstrap/12-luks-recovery.sh`

**Files:**
- Create: `bootstrap/12-luks-recovery.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Generate a 48-char LUKS recovery key. Break-glass when TPM2 + YubiKey both fail.
# Key is displayed ONCE — user must write it down before continuing.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted — recovery key N/A"
    marker_write "12-recovery"
    exit 0
fi

DEV=$(luks_device)

if has_token "$DEV" "systemd-recovery"; then
    ok "Recovery key already present on $DEV"
    marker_write "12-recovery"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "Recovery key NOT enrolled"
    exit 1
fi

cat >&2 <<'EOF'

============================================================
  A LUKS recovery key will be generated and displayed ONCE.
  Write it on paper. Store it in a safe place OFFLINE.
  This is your only way in if TPM2 and YubiKey both fail.
============================================================

EOF
read -rp "Press enter when ready to see the key..."

systemd-cryptenroll "$DEV" --recovery-key

read -rp "Type 'saved' to confirm you wrote it down: " ans
[[ "$ans" == "saved" ]] || err "not confirmed — re-run to re-display"

clear
ok "Recovery key enrolled"
marker_write "12-recovery"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/12-luks-recovery.sh
bash -n bootstrap/12-luks-recovery.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/12-luks-recovery.sh
git commit -m "feat(bootstrap): add 12-luks-recovery.sh (48-char recovery key)"
```

---

### Task 16: Create `bootstrap/13-luks-wipe-installer.sh`

**Files:**
- Create: `bootstrap/13-luks-wipe-installer.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Wipe the weak installer passphrase (keyslot 0). Refuses unless TPM2, FIDO2,
# and recovery are all already enrolled — three-lock safety gate.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root is not LUKS-encrypted — nothing to wipe"
    marker_write "13-wipe"
    exit 0
fi

DEV=$(luks_device)
DUMP=$(cryptsetup luksDump "$DEV")

if ! grep -qE '^\s*0:\s+luks2' <<<"$DUMP"; then
    ok "Installer passphrase already wiped"
    marker_write "13-wipe"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "Installer passphrase still present"
    exit 1
fi

# Safety net — refuse to wipe unless all three escape hatches exist.
grep -q "systemd-tpm2"     <<<"$DUMP" || err "Refusing: TPM2 not enrolled"
grep -q "systemd-fido2"    <<<"$DUMP" || err "Refusing: FIDO2 not enrolled"
grep -q "systemd-recovery" <<<"$DUMP" || err "Refusing: recovery key not enrolled"

warn "Wiping keyslot 0 (installer passphrase) on $DEV"
read -rp "Type YES to proceed: " ans
[[ "$ans" == "YES" ]] || err "aborted"

cryptsetup luksKillSlot "$DEV" 0
ok "Installer passphrase wiped. Unlock is now TPM2 (auto) / YubiKey / recovery key only."
marker_write "13-wipe"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/13-luks-wipe-installer.sh
bash -n bootstrap/13-luks-wipe-installer.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/13-luks-wipe-installer.sh
git commit -m "feat(bootstrap): add 13-luks-wipe-installer.sh (kill slot 0 after 3-way enroll)"
```

---

### Task 17: Create `bootstrap/30-fingerprint-enroll.sh`

**Files:**
- Create: `bootstrap/30-fingerprint-enroll.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Framework 13 Pro: Goodix fingerprint reader integrated into the power button.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_fingerprint_reader; then
    skip "no fingerprint reader detected — skipping"
    marker_write "30-fprint"
    exit 0
fi

USER_NAME="${SUDO_USER:-netf}"

if sudo -u "$USER_NAME" fprintd-list "$USER_NAME" 2>/dev/null \
    | grep -q "right-index-finger\|left-index-finger"; then
    ok "Fingerprint already enrolled for $USER_NAME"
    marker_write "30-fprint"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "No fingerprint enrolled"
    exit 1
fi

log "Enrolling right index finger for $USER_NAME"
log "Press the power button repeatedly until enrollment completes (5 reads)"
sudo -u "$USER_NAME" fprintd-enroll -f right-index-finger "$USER_NAME"

ok "Fingerprint enrolled"
marker_write "30-fprint"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/30-fingerprint-enroll.sh
bash -n bootstrap/30-fingerprint-enroll.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/30-fingerprint-enroll.sh
git commit -m "feat(bootstrap): add 30-fingerprint-enroll.sh (Goodix right-index)"
```

---

### Task 18: Create `bootstrap/40-framework-ec.sh`

**Files:**
- Create: `bootstrap/40-framework-ec.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Set Framework EC defaults via framework_tool. Charge limit 80% for battery
# longevity. Skips cleanly on non-Framework hardware.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! is_framework_laptop; then
    skip "not a Framework laptop — skipping EC config"
    marker_write "40-ec"
    exit 0
fi

if ! command -v framework_tool >/dev/null 2>&1; then
    err "is Framework laptop but framework_tool missing — image bug"
fi

CHARGE_LIMIT=80

CURRENT=$(framework_tool --charge-limit 2>/dev/null \
    | awk '/Maximum/ {print $NF}' | tr -d '%') || CURRENT=0

if [[ "$CURRENT" == "$CHARGE_LIMIT" ]]; then
    ok "Charge limit already set to ${CHARGE_LIMIT}%"
    marker_write "40-ec"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    warn "charge limit is ${CURRENT}%, want ${CHARGE_LIMIT}%"
    exit 1
fi

log "Setting battery charge limit to ${CHARGE_LIMIT}%"
framework_tool --charge-limit "$CHARGE_LIMIT"

ok "EC configured"
marker_write "40-ec"
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/40-framework-ec.sh
bash -n bootstrap/40-framework-ec.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/40-framework-ec.sh
git commit -m "feat(bootstrap): add 40-framework-ec.sh (charge limit 80%)"
```

---

### Task 19: Create `bootstrap/run-all.sh`

**Files:**
- Create: `bootstrap/run-all.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Orchestrate every numbered bootstrap step in order. --check = dry-run.
# Glob is [0-9]*.sh so adding a new numbered step (e.g., 20-*) is drop-in.
set -euo pipefail

# shellcheck source=/usr/share/bootstrap/lib/common.sh
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

cd /usr/share/bootstrap
# Expand glob via find + sort so order is deterministic and failure-tolerant.
mapfile -t STEPS < <(find . -maxdepth 1 -name '[0-9]*.sh' -type f | sort)

if [[ ${#STEPS[@]} -eq 0 ]]; then
    err "no bootstrap steps found in $PWD"
fi

FAILED=0
for step in "${STEPS[@]}"; do
    name=${step#./}
    log "═══ $name ═══"
    if [[ $CHECK -eq 1 ]]; then
        if ! "$step" --check; then
            FAILED=1
            warn "$name needs running"
        fi
    else
        "$step"
    fi
done

if [[ $CHECK -eq 1 ]]; then
    if [[ $FAILED -eq 0 ]]; then
        ok "All steps idempotent — nothing to do"
    else
        exit 1
    fi
else
    marker_write "all"
    ok "Bootstrap complete. Reboot recommended."
fi
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x bootstrap/run-all.sh
bash -n bootstrap/run-all.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add bootstrap/run-all.sh
git commit -m "feat(bootstrap): add run-all.sh orchestrator with --check mode"
```

---

## Phase 4 — Installer configs

### Task 20: Create `config.toml` (user installer kickstart)

**Files:**
- Create: `config.toml`

- [ ] **Step 1: Write the file**

```toml
# Consumed by bootc-image-builder --type=anaconda-iso.
# bootc-image-builder injects the image deployment verb automatically — do
# NOT include `ostreecontainer` or `bootc` in the kickstart below.

[customizations.installer.kickstart]
contents = """
text
keyboard --xlayouts='pl'
lang en_GB.UTF-8
timezone Europe/Warsaw --utc

network --bootproto=dhcp --device=link --activate --hostname=fw13

zerombr
clearpart --all --initlabel --disklabel=gpt
reqpart --add-boot
part / --grow --fstype=btrfs --encrypted --luks-version=luks2 --pbkdf=argon2id --passphrase=installer-temp-change-me

rootpw --lock
# Password hash for 'CHANGE_ME!!!' — intentionally throwaway.
# First thing after first login: `passwd` to change it.
# Regenerate with: openssl passwd -6 'your-pw'
user --name=netf --groups=wheel --iscrypted --password='$6$YdvxSXl6YUHhOzEf$YTvt9PEWKWpTVcb.Y4N/Qlwp.cpMmQbegc8OIFsturFPjOtuYWw4Uzwy5dHlwNiqqiaMd9mfUlJH6wn.EA1Wo0'

services --enabled=sshd,tailscaled
firstboot --disable
reboot --eject
"""

# User creation happens in the kickstart, so disable Anaconda's users module.
[customizations.installer.modules]
disable = ["org.fedoraproject.Anaconda.Modules.Users"]

[customizations.iso]
volume_id = "FEDORA-BOOTC-STARTER"
```

- [ ] **Step 2: Validate TOML parses (requires taplo or python3)**

```bash
python3 -c "import tomllib; tomllib.load(open('config.toml','rb'))" && echo "✓ valid TOML"
```

Expected: `✓ valid TOML`.

- [ ] **Step 3: Commit**

```bash
git add config.toml
git commit -m "feat: add installer kickstart config (LUKS2/argon2id, unattended)"
```

---

### Task 21: Create `config-ci.toml` (CI qcow2 variant)

**Files:**
- Create: `config-ci.toml`

- [ ] **Step 1: Write the file**

```toml
# CI-mode bootc-image-builder config: qcow2 output with SSH key injection,
# no LUKS (keeps e2e-vm boot simple + fast). The workflow substitutes the
# real CI pubkey into {{CI_PUBKEY}} before invocation.

[[customizations.user]]
name = "netf"
groups = ["wheel"]
key = "{{CI_PUBKEY}}"

[[customizations.user]]
name = "root"
key = "{{CI_PUBKEY}}"

[customizations.kernel]
append = "console=ttyS0,115200"
```

- [ ] **Step 2: Commit**

```bash
git add config-ci.toml
git commit -m "feat: add CI qcow2 config (SSH key injected via template)"
```

---

## Phase 5 — Containerfile

### Task 22: Create `Containerfile`

**Files:**
- Create: `Containerfile`

- [ ] **Step 1: Write the file**

```dockerfile
# syntax=docker/dockerfile:1

ARG FEDORA_VERSION=44

# ---- Stage 1: build framework_tool from source ---------------------------
# Not in Fedora proper yet; building from source keeps the image self-contained
# and version-pinned.
FROM quay.io/fedora/fedora:${FEDORA_VERSION} AS fw-tool-builder
ARG FW_TOOL_VERSION=v0.4.0
RUN dnf install -y rust cargo systemd-devel hidapi-devel git pkgconf-pkg-config \
 && git clone --depth 1 --branch ${FW_TOOL_VERSION} \
      https://github.com/FrameworkComputer/framework-system /src \
 && cd /src && cargo build --release -p framework_tool

# ---- Stage 2: the actual bootc image -------------------------------------
FROM quay.io/fedora-ostree-desktops/kinoite:${FEDORA_VERSION}

# ---- Layered packages ----------------------------------------------------
# Strict policy: only things that MUST be root-installed, kernel-matched, or
# needed before dotfiles bootstrap can even run. Modern CLI lives in dotfiles.
RUN rpm-ostree install \
      git-core \
      chezmoi \
      alacritty \
      podman-compose distrobox \
      tailscale wireguard-tools \
      tpm2-tools yubikey-manager fido2-tools \
      fprintd fprintd-pam \
      sbctl \
      iio-sensor-proxy \
      fwupd \
      kdeconnectd \
      jetbrains-mono-fonts-all fira-code-fonts \
      bpftool bpftrace kernel-tools \
      restic \
 && ostree container commit

# framework_tool from stage 1
COPY --from=fw-tool-builder /src/target/release/framework_tool /usr/local/bin/framework_tool
RUN chmod +x /usr/local/bin/framework_tool

# mise (dev tool version manager; host-level per dotfiles architecture)
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && ostree container commit

# System config: /usr/etc/* is copied to /etc/ on deploy with 3-way merge.
# systemd unit: /usr/lib/systemd/system/* is package-owned (correct location).
COPY files/usr/ /usr/

# Bootstrap scripts
COPY bootstrap/ /usr/share/bootstrap/
RUN chmod +x /usr/share/bootstrap/*.sh /usr/share/bootstrap/lib/*.sh

# Embed cosign public key for signature enforcement
COPY cosign.pub /usr/etc/containers/pubkey.pem

# Build-time smoke test — fail the build if policy is misconfigured
RUN set -e; \
    grep -q "/usr/etc/containers/pubkey.pem" /usr/etc/containers/policy.json; \
    test -f /usr/etc/containers/pubkey.pem; \
    echo "✓ signature policy wired correctly"

# Initramfs: bake in TPM2 + FIDO2 LUKS unlock modules.
# Runtime dracut regeneration fails on bootc (/usr is read-only), so we MUST
# regenerate at build time.
RUN printf 'add_dracutmodules+=" crypt tpm2-tss systemd-cryptsetup fido2 systemd "\n' \
      > /usr/lib/dracut/dracut.conf.d/50-luks-unlock.conf

RUN set -xe; \
    kver=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1); \
    test -n "$kver"; \
    env DRACUT_NO_XATTR=1 dracut -vf "/usr/lib/modules/$kver/initramfs.img" "$kver"

# Kernel args (bootc TOML format)
RUN mkdir -p /usr/lib/bootc/kargs.d \
 && printf 'kargs = [\n  "intel_iommu=on",\n  "rd.luks.options=discard",\n  "mem_sleep_default=s2idle",\n  "quiet",\n  "splash",\n]\n' \
      > /usr/lib/bootc/kargs.d/10-fw13.toml

# Enable first-boot bootstrap oneshot
RUN systemctl enable netf-bootstrap.service

# Final validation (in-image): bootc considers the image well-formed.
RUN bootc container lint
```

- [ ] **Step 2: Lint with hadolint (if available)**

```bash
if command -v hadolint >/dev/null; then
    hadolint Containerfile
else
    echo "hadolint not installed; skipping (CI will run it)"
fi
```

Expected: clean, or hadolint-not-installed message.

- [ ] **Step 3: Commit**

```bash
git add Containerfile
git commit -m "feat: add Containerfile (parameterized FEDORA_VERSION, all layers)"
```

---

## Phase 6 — Makefile & local scripts

### Task 23: Create `Makefile`

**Files:**
- Create: `Makefile`

- [ ] **Step 1: Write the file**

```makefile
FEDORA_VERSION ?= 44
FW_TOOL_VERSION ?= v0.4.0
IMAGE_REF      ?= ghcr.io/netf/fedora-bootc-starter:$(FEDORA_VERSION)
BUILDER_IMG    := quay.io/centos-bootc/bootc-image-builder:latest
OUTPUT_DIR     := output

.DEFAULT_GOAL := help
.PHONY: help lint build inspect push sign iso usb test-vm clean

help:  ## Show this help
	@awk 'BEGIN{FS=":.*?##"; printf "\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint:  ## Lint Containerfile, shell scripts, and YAML
	hadolint Containerfile
	shellcheck -x bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh
	yamllint .github/workflows/ files/usr/etc/containers/registries.d/
	@echo "✓ lint clean"

build:  ## Build the bootc image locally (requires Linux host)
	sudo podman build \
	  --pull=newer \
	  --build-arg FEDORA_VERSION=$(FEDORA_VERSION) \
	  --build-arg FW_TOOL_VERSION=$(FW_TOOL_VERSION) \
	  -t $(IMAGE_REF) .

inspect: build  ## Smoke test the built image
	sudo podman run --rm $(IMAGE_REF) bootc container lint
	sudo podman run --rm $(IMAGE_REF) bash -c '\
	  set -e; \
	  test -x /usr/share/bootstrap/run-all.sh; \
	  test -f /usr/lib/bootc/kargs.d/10-fw13.toml; \
	  systemctl is-enabled netf-bootstrap.service; \
	  command -v chezmoi mise alacritty distrobox tailscale framework_tool fwupdmgr tpm2_pcrread ykman; \
	  echo "✓ smoke tests passed"'

push: build  ## Push image to GHCR
	sudo podman push $(IMAGE_REF)

sign:  ## cosign sign the pushed image DIGEST (not tag)
	@test -f cosign.key || (echo "ERROR: cosign.key missing — run scripts/bootstrap-cosign.sh" && exit 1)
	DIGEST=$$(sudo podman inspect --format '{{index .RepoDigests 0}}' $(IMAGE_REF)); \
	  test -n "$$DIGEST"; \
	  echo "Signing $$DIGEST"; \
	  cosign sign --yes --key cosign.key "$$DIGEST"

iso: build  ## Build the unattended installer ISO
	mkdir -p $(OUTPUT_DIR)
	sudo podman run --rm -it --privileged --pull=newer \
	  --security-opt label=type:unconfined_t \
	  -v /var/lib/containers/storage:/var/lib/containers/storage \
	  -v $(PWD)/config.toml:/config.toml:ro \
	  -v $(PWD)/$(OUTPUT_DIR):/output \
	  $(BUILDER_IMG) \
	  --type anaconda-iso \
	  --config /config.toml \
	  $(IMAGE_REF)
	@echo ""
	@echo "✓ ISO ready: $(OUTPUT_DIR)/bootiso/install.iso"
	@du -h $(OUTPUT_DIR)/bootiso/install.iso

usb:  ## Flash ISO to USB (DEV=/dev/sdX required)
	@test -n "$(DEV)" || { echo "ERROR: DEV=/dev/sdX required"; exit 1; }
	@test -b "$(DEV)" || { echo "ERROR: $(DEV) not a block device"; exit 1; }
	@echo "═══ WILL WIPE $(DEV) ═══"
	@lsblk -o NAME,SIZE,MODEL,MOUNTPOINT $(DEV)
	@read -p "Type YES to flash: " a && [ "$$a" = "YES" ]
	sudo dd if=$(OUTPUT_DIR)/bootiso/install.iso of=$(DEV) bs=4M status=progress oflag=direct conv=fsync
	sync
	@echo "✓ USB ready"

test-vm: iso  ## Boot the ISO in QEMU with swtpm for end-to-end testing
	./scripts/test-vm.sh

clean:
	sudo rm -rf $(OUTPUT_DIR)
```

- [ ] **Step 2: Sanity check syntax**

```bash
make -n help >/dev/null && echo "✓ makefile parses"
```

Expected: `✓ makefile parses`.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "feat: add Makefile (build/iso/usb/test-vm targets, digest-only signing)"
```

---

### Task 24: Create `scripts/test-vm.sh`

**Files:**
- Create: `scripts/test-vm.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Boot installer ISO in QEMU with emulated TPM2. Verifies unattended install
# works end-to-end before committing the USB to real hardware.
set -euo pipefail

ISO=${ISO:-output/bootiso/install.iso}
DISK=${DISK:-output/test-disk.qcow2}
MEM=${MEM:-8G}
CPUS=${CPUS:-4}

if [[ ! -f $ISO ]]; then
    echo "ERROR: $ISO not found. Run 'make iso' first." >&2
    exit 1
fi

TPM_DIR=$(mktemp -d)
trap 'pkill -P $$ 2>/dev/null || true; rm -rf "$TPM_DIR"' EXIT

if [[ ! -f $DISK ]]; then
    qemu-img create -f qcow2 "$DISK" 60G
fi

swtpm socket --tpm2 --tpmstate dir="$TPM_DIR" \
    --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
    --log level=20 --daemon

OVMF=/usr/share/edk2/ovmf/OVMF_CODE.fd
[[ -f $OVMF ]] || OVMF=/usr/share/OVMF/OVMF_CODE.fd
[[ -f $OVMF ]] || { echo "ERROR: cannot find OVMF firmware"; exit 1; }

qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m "$MEM" -smp "$CPUS" \
    -bios "$OVMF" \
    -chardev socket,id=chrtpm,path="$TPM_DIR/swtpm-sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -drive file="$DISK",if=virtio \
    -cdrom "$ISO" \
    -boot d \
    -netdev user,id=n0 -device virtio-net,netdev=n0 \
    -display gtk
```

- [ ] **Step 2: Make executable and lint**

```bash
chmod +x scripts/test-vm.sh
shellcheck scripts/test-vm.sh
bash -n scripts/test-vm.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/test-vm.sh
git commit -m "feat: add scripts/test-vm.sh (local QEMU boot with swtpm)"
```

---

### Task 25: Create `scripts/verify-image.sh`

**Files:**
- Create: `scripts/verify-image.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Verify a pushed bootc image: cosign signature, expected layers, expected
# binaries. Run from any machine with podman + cosign. Uses repo's cosign.pub.
set -euo pipefail

IMAGE_REF=${IMAGE_REF:-ghcr.io/netf/fedora-bootc-starter:44}
PUBKEY=${PUBKEY:-cosign.pub}

if [[ ! -f $PUBKEY ]]; then
    echo "ERROR: $PUBKEY not found. Run from repo root." >&2
    exit 1
fi

echo "→ Verifying cosign signature for $IMAGE_REF"
cosign verify --key "$PUBKEY" "$IMAGE_REF" > /dev/null
echo "  ✓ signature verified"

echo "→ Pulling image"
podman pull --quiet "$IMAGE_REF" > /dev/null

echo "→ Running smoke test inside image"
podman run --rm "$IMAGE_REF" bash -c '
    set -e
    test -x /usr/share/bootstrap/run-all.sh
    test -f /usr/lib/bootc/kargs.d/10-fw13.toml
    test -f /usr/etc/containers/policy.json
    test -f /usr/etc/containers/pubkey.pem
    command -v chezmoi mise alacritty distrobox tailscale framework_tool >/dev/null
    echo "  ✓ image content OK"
'
echo "✓ $IMAGE_REF verified"
```

- [ ] **Step 2: Make executable and lint**

```bash
chmod +x scripts/verify-image.sh
shellcheck scripts/verify-image.sh
bash -n scripts/verify-image.sh
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-image.sh
git commit -m "feat: add scripts/verify-image.sh (cosign + content verification)"
```

---

## Phase 7 — CI workflow

### Task 26: Create `.github/workflows/build.yml`

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Write the file**

```yaml
name: build
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 4 * * *"  # nightly — catches upstream regressions
  workflow_dispatch:
    inputs:
      fedora_version:
        description: "Fedora version (default 44)"
        default: "44"
        required: false

env:
  FEDORA_VERSION: ${{ inputs.fedora_version || '44' }}
  IMAGE_NAME: fedora-bootc-starter

jobs:
  # ─────────────────────────────────────────────────────────────────────
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: hadolint
        uses: hadolint/hadolint-action@v3
        with:
          dockerfile: Containerfile

      - name: shellcheck + bash -n
        run: |
          sudo apt-get update -y
          sudo apt-get install -y shellcheck
          shellcheck -x bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh
          for f in bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh; do
            bash -n "$f"
          done

      - name: yamllint
        run: |
          sudo apt-get install -y yamllint
          yamllint .github/workflows/ files/usr/etc/containers/registries.d/

      - name: TOML parse
        run: |
          python3 -c "import tomllib; tomllib.load(open('config.toml','rb'))"
          python3 -c "import tomllib; tomllib.load(open('config-ci.toml','rb'))"

  # ─────────────────────────────────────────────────────────────────────
  build:
    needs: lint
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write  # cosign keyless (not used, but harmless)
    env:
      IMAGE_REF: ghcr.io/${{ github.repository_owner }}/fedora-bootc-starter:${{ inputs.fedora_version || '44' }}
    steps:
      - uses: actions/checkout@v4

      - name: Free runner disk space
        run: |
          sudo rm -rf /opt/hostedtoolcache /usr/share/dotnet /usr/local/lib/android
          sudo docker system prune -af || true
          df -h /

      - name: Install podman + cosign
        run: |
          sudo apt-get update -y
          sudo apt-get install -y podman
      - uses: sigstore/cosign-installer@v3

      - name: Login to ghcr.io
        run: echo "${{ secrets.GITHUB_TOKEN }}" \
          | podman login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Verify cosign.pub is committed
        run: test -f cosign.pub || (echo "cosign.pub missing — run scripts/bootstrap-cosign.sh" && exit 1)

      - name: Build
        run: sudo podman build --build-arg FEDORA_VERSION=$FEDORA_VERSION -t $IMAGE_REF .

      - name: bootc container lint
        run: sudo podman run --rm $IMAGE_REF bootc container lint

      - name: Smoke test (positive + negative assertions, initramfs)
        run: |
          sudo podman run --rm $IMAGE_REF bash -c '
            set -e

            # Bootstrap scripts present, executable
            test -x /usr/share/bootstrap/run-all.sh
            for s in 00-sanity 05-firmware-update 10-luks-tpm2 11-luks-fido2 \
                     12-luks-recovery 13-luks-wipe-installer 30-fingerprint-enroll \
                     40-framework-ec; do
              test -x /usr/share/bootstrap/$s.sh
              bash -n /usr/share/bootstrap/$s.sh
            done
            test -f /usr/share/bootstrap/lib/common.sh

            # Kargs
            test -f /usr/lib/bootc/kargs.d/10-fw13.toml
            grep -q intel_iommu /usr/lib/bootc/kargs.d/10-fw13.toml

            # systemd unit
            systemctl is-enabled netf-bootstrap.service

            # Signature policy wired correctly
            test -f /usr/etc/containers/policy.json
            test -f /usr/etc/containers/pubkey.pem
            grep -q /usr/etc/containers/pubkey.pem /usr/etc/containers/policy.json
            test -f /usr/etc/containers/registries.d/ghcr-io-netf.yaml

            # Expected binaries
            command -v chezmoi mise alacritty distrobox tailscale tpm2_pcrread \
                       ykman fido2-token fwupdmgr framework_tool fprintd-enroll \
                       sbctl restic bpftool bpftrace kdeconnectd iio-sensor-proxy

            # Negative assertions — must NOT be in image (dotfiles boundary)
            ! command -v eza
            ! command -v bat
            ! command -v rg
            ! command -v fd
            ! command -v jq
            ! command -v starship

            # Initramfs contains TPM2/FIDO2/crypt modules (guards "dracut did not run")
            KVER=$(ls /usr/lib/modules | head -1)
            lsinitrd /usr/lib/modules/$KVER/initramfs.img \
              | grep -qE "tpm2|cryptsetup"

            echo "✓ smoke tests pass"
          '

      - name: Push + sign DIGEST (main only)
        if: github.ref == 'refs/heads/main'
        env:
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
        run: |
          sudo podman push $IMAGE_REF
          DIGEST=$(sudo podman inspect --format '{{index .RepoDigests 0}}' $IMAGE_REF)
          test -n "$DIGEST"
          echo "Signing $DIGEST"
          echo "${{ secrets.COSIGN_PRIVATE_KEY }}" > /tmp/cosign.key
          cosign sign --yes --key /tmp/cosign.key "$DIGEST"
          rm -f /tmp/cosign.key

  # ─────────────────────────────────────────────────────────────────────
  # End-to-end VM test: qcow2 + swtpm + QEMU + SSH verification.
  # Does NOT test real hardware (Goodix/YubiKey/EC) — that's manual on the
  # Framework 13 Pro. Everything else we CAN exercise in a VM.
  e2e-vm:
    needs: build
    runs-on: ubuntu-24.04
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: Free runner disk space
        run: |
          sudo rm -rf /opt/hostedtoolcache /usr/share/dotnet /usr/local/lib/android
          sudo docker system prune -af || true
          df -h /

      - name: Install QEMU + swtpm + OVMF
        run: |
          sudo apt-get update -y
          sudo apt-get install -y \
              qemu-system-x86 qemu-utils ovmf \
              swtpm swtpm-tools \
              podman netcat-openbsd openssh-client

      - name: Verify /dev/kvm available
        run: |
          test -c /dev/kvm || { echo "ERROR: /dev/kvm not present on runner"; exit 1; }
          sudo chmod 666 /dev/kvm

      - name: Build image (local tag only)
        run: sudo podman build --build-arg FEDORA_VERSION=$FEDORA_VERSION -t localhost/test-image:ci .

      - name: Generate CI SSH keypair
        run: ssh-keygen -t ed25519 -N '' -f ci-key -C "ci@github-actions"

      - name: Render config-ci.toml with CI pubkey
        run: |
          sed "s|{{CI_PUBKEY}}|$(cat ci-key.pub)|g" config-ci.toml > config-ci-rendered.toml
          cat config-ci-rendered.toml

      - name: Build qcow2
        run: |
          mkdir -p output
          sudo podman run --rm --privileged --pull=newer \
              --security-opt label=type:unconfined_t \
              -v /var/lib/containers/storage:/var/lib/containers/storage \
              -v $PWD/config-ci-rendered.toml:/config.toml:ro \
              -v $PWD/output:/output \
              quay.io/centos-bootc/bootc-image-builder:latest \
              --type qcow2 --config /config.toml \
              localhost/test-image:ci
          sudo chown -R "$USER" output
          ls -lh output/qcow2/

      - name: Start swtpm (emulated TPM2)
        run: |
          mkdir -p /tmp/swtpm
          swtpm socket --tpm2 --tpmstate dir=/tmp/swtpm \
              --ctrl type=unixio,path=/tmp/swtpm/sock \
              --log level=5 --daemon

      - name: Boot VM in background
        run: |
          qemu-system-x86_64 \
            -machine q35,accel=kvm -cpu host -m 4G -smp 2 \
            -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
            -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
            -chardev socket,id=chrtpm,path=/tmp/swtpm/sock \
            -tpmdev emulator,id=tpm0,chardev=chrtpm \
            -device tpm-crb,tpmdev=tpm0 \
            -drive file=output/qcow2/disk.qcow2,if=virtio,format=qcow2 \
            -netdev user,id=n0,hostfwd=tcp::2222-:22 \
            -device virtio-net-pci,netdev=n0 \
            -nographic -serial file:vm-serial.log \
            -display none &
          echo $! > qemu.pid
          sleep 5

      - name: Wait for SSH (up to 5 min)
        run: |
          for i in {1..30}; do
            if ssh -i ci-key -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -o ConnectTimeout=5 \
                   -p 2222 netf@localhost true 2>/dev/null; then
              echo "✓ SSH up after ${i} attempt(s)"
              exit 0
            fi
            sleep 10
          done
          echo "✗ SSH never came up"
          tail -n 200 vm-serial.log
          exit 1

      - name: Verify system state in VM
        run: |
          SSH="ssh -i ci-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 netf@localhost"

          echo "─── Basic system ───"
          $SSH 'cat /etc/os-release | grep VERSION'
          $SSH 'bootc status'
          $SSH 'systemctl is-system-running || true'   # may report degraded, OK

          echo "─── Image-baked tooling ───"
          $SSH 'command -v chezmoi mise alacritty framework_tool'
          $SSH 'command -v tpm2_pcrread ykman fwupdmgr sbctl'

          echo "─── TPM2 visible via swtpm ───"
          $SSH 'sudo tpm2_pcrread sha256:7,11'

          echo "─── sbctl status readable ───"
          $SSH 'sudo sbctl status || true'

          echo "─── Hardware-gated scripts skip gracefully ───"
          $SSH 'sudo /usr/share/bootstrap/40-framework-ec.sh --check' 2>&1 | grep -i 'skip\|not a framework'
          $SSH 'sudo /usr/share/bootstrap/30-fingerprint-enroll.sh --check' 2>&1 | grep -i 'skip\|no fingerprint'
          $SSH 'sudo /usr/share/bootstrap/11-luks-fido2.sh --check' 2>&1 | grep -i 'skip\|no yubikey\|not luks\|n/a'
          $SSH 'sudo /usr/share/bootstrap/05-firmware-update.sh --check' 2>&1 | grep -i 'skip\|vm'

          echo "─── run-all.sh --check terminates 0 ───"
          $SSH 'sudo /usr/share/bootstrap/run-all.sh --check'

          echo "✓ e2e VM test passed"

      - name: Shutdown VM
        if: always()
        run: |
          ssh -i ci-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -p 2222 netf@localhost 'sudo systemctl poweroff' || true
          sleep 5
          [[ -f qemu.pid ]] && kill -9 "$(cat qemu.pid)" 2>/dev/null || true

      - name: Upload VM serial log on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: vm-serial-log
          path: vm-serial.log
          retention-days: 7
```

- [ ] **Step 2: Lint**

```bash
yamllint .github/workflows/build.yml
```

Expected: clean (or only warnings, not errors).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add build workflow (lint → build+smoke → e2e-vm)"
```

---

## Phase 8 — README

### Task 27: Rewrite `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README**

```bash
cat README.md
```

Current content is just `# fedora-bootc-starter` — replace wholesale.

- [ ] **Step 2: Write the new README**

```markdown
# fedora-bootc-starter

Signed Fedora Kinoite bootc image + unattended installer for the Framework Laptop 13 Pro (Panther Lake). Built nightly in CI, smoke-tested and e2e-tested in a QEMU VM with an emulated TPM2 before every push.

Companion to [netf/dotfiles](https://github.com/netf/dotfiles). This image is the **minimum host foundation**; everything user-facing (flatpaks, dev languages, toolbox, modern CLI) lives in dotfiles.

## Image

```
ghcr.io/netf/fedora-bootc-starter:44
```

Signed with cosign; key committed at `cosign.pub`. Verify any pull with:

```bash
cosign verify --key cosign.pub ghcr.io/netf/fedora-bootc-starter:44
```

## Quickstart (day 0, fresh laptop)

On a Linux workstation:

```bash
make iso                   # builds installer ISO embedding the image
make usb DEV=/dev/sdX      # flashes to USB (wipes the device)
```

On the Framework 13 Pro:

1. BIOS: confirm Intel PTT (TPM2) on, Secure Boot on.
2. Boot the USB (F12 boot menu). Unattended install — ~5 min, no network needed.
3. Reboot, enter the throwaway installer passphrase once.
4. `netf-bootstrap.service` runs on first login: LVFS firmware → TPM2 → FIDO2 → recovery key → wipe installer pw → fingerprint → EC charge limit.
5. motd prints the dotfiles handoff; `curl -fsLS …/netf/dotfiles/main/install.sh | bash`.

## Day 2

```bash
bootc upgrade              # pulls signed update, policy-checked automatically
systemctl reboot

bootc rollback             # previous deployment
systemctl reboot

sudo /usr/share/bootstrap/run-all.sh --check   # idempotency dry-run
```

After a kernel update, PCR 11 changes. Re-bind TPM2:

```bash
DEV=$(findmnt -no SOURCE / | xargs cryptsetup status | awk '/device:/ {print $2}')
sudo systemd-cryptenroll "$DEV" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7+11
```

Major Fedora jump (F44 → F45):

```bash
bootc switch --enforce-container-sigpolicy ghcr.io/netf/fedora-bootc-starter:45
systemctl reboot
```

## What's in the image

Minimal host foundation only. Package list authoritative in `Containerfile`; design rationale in `docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md` §6.

**In the image:** `git`, `chezmoi`, `mise`, `alacritty`, `podman-compose`, `distrobox`, `tailscale`, `wireguard-tools`, `tpm2-tools`, `yubikey-manager`, `fido2-tools`, `fprintd`, `sbctl`, `iio-sensor-proxy`, `fwupd`, `framework_tool` (built from source), `kdeconnectd`, `jetbrains-mono-fonts-all`, `fira-code-fonts`, `bpftool`, `bpftrace`, `kernel-tools`, `restic`.

**Deliberately NOT in the image (owned by dotfiles):** `starship`, `eza`, `bat`, `ripgrep`, `fd`, `jq`, `yq`, `gh`, `just`, `fzf`, `delta`, `zoxide`, flatpaks, language runtimes, toolbox contents.

## First-time setup for maintainers

Before CI can succeed:

1. Generate cosign keypair:
   ```bash
   ./scripts/bootstrap-cosign.sh
   git add cosign.pub && git commit -m "chore: add cosign public key"
   ```
2. Add GitHub Actions secrets at `Settings → Secrets and variables → Actions`:
   - `COSIGN_PRIVATE_KEY` — contents of `cosign.key`
   - `COSIGN_PASSWORD` — password from keypair generation
3. Delete the local `cosign.key` (after storing offline in a password manager).

## Development

- Lint locally: `make lint` (hadolint + shellcheck + yamllint). CI mirrors exactly.
- Full build: `make build && make inspect` — Linux host required.
- VM e2e: `make test-vm` — opens a QEMU window with the ISO booting under swtpm.

CI matrix:

| Job | Runs | What it checks |
|---|---|---|
| `lint` | every PR + push | hadolint, shellcheck, bash -n, yamllint, TOML parse |
| `build` | main + nightly + dispatch | `podman build`, `bootc container lint`, ~30-item smoke test (incl. initramfs contents + negative assertions). On main: push + cosign sign the digest. |
| `e2e-vm` | main + nightly | qcow2 via bootc-image-builder, boot in QEMU with swtpm, SSH in, verify TPM2, run bootstrap `--check`, verify hardware gates skip. |

Manual-only (not exercised by CI, requires real Framework 13 Pro):

- Real YubiKey FIDO2 enrollment
- Real Goodix fingerprint enrollment
- `framework_tool` talking to real EC
- LVFS firmware actually applying
- Panther Lake kernel behavior under real Secure Boot

## Known sharp edges

See `docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md` §14 for the full list. Most-commonly-surprising:

- Kernel updates change PCR 11 → TPM2 auto-unlock breaks until re-bind (not a lockout; FIDO2 + recovery still work).
- `bootc rollback` does not merge `/etc` → rolled-back deployment lacks TPM2 crypttab metadata. Falls back to FIDO2/recovery.
- LVFS may need two boots on first firmware run (EC + BIOS + retimers chain).
- Panther Lake is new silicon — weekly `fwupdmgr update` recommended through mid-2026.

## References

- Spec: `docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md`
- Original design notes (kept as reference): `guide.md`
- Upstream bootc docs: https://bootc-dev.github.io/bootc/
- Aurora signature pattern: https://github.com/ublue-os/aurora
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README with install, day-2, dev workflow, CI matrix"
```

---

## Phase 9 — Local static validation (pre-push dress rehearsal)

### Task 28: Run full local lint sweep

- [ ] **Step 1: Shell scripts**

```bash
shellcheck -x bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh
```

Expected: no output, exit 0.

- [ ] **Step 2: bash -n parse check**

```bash
for f in bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh; do
    bash -n "$f" && echo "✓ $f"
done
```

Expected: `✓ <path>` for every file.

- [ ] **Step 3: YAML**

```bash
yamllint .github/workflows/ files/usr/etc/containers/registries.d/
```

Expected: no errors. Warnings on line length etc. are OK.

- [ ] **Step 4: TOML parse**

```bash
python3 -c "import tomllib; tomllib.load(open('config.toml','rb'))" && echo "✓ config.toml"
python3 -c "import tomllib; tomllib.load(open('config-ci.toml','rb'))" && echo "✓ config-ci.toml"
```

Expected: both `✓` lines.

- [ ] **Step 5: JSON parse**

```bash
python3 -m json.tool files/usr/etc/containers/policy.json > /dev/null && echo "✓ policy.json"
```

Expected: `✓ policy.json`.

- [ ] **Step 6: hadolint (if available)**

```bash
if command -v hadolint >/dev/null; then
    hadolint Containerfile && echo "✓ Containerfile"
else
    echo "hadolint not installed locally — CI will run it"
fi
```

- [ ] **Step 7: Makefile sanity**

```bash
make -n help >/dev/null && echo "✓ Makefile parses"
```

Expected: `✓ Makefile parses`.

- [ ] **Step 8: No untracked secrets**

```bash
git status --porcelain | grep -E '(cosign\.key|ci-key($|\.pub))' \
    && echo "✗ SECRET FILE untracked but present — remove before push" \
    || echo "✓ no secrets in working tree"
```

Expected: `✓ no secrets in working tree`.

- [ ] **Step 9: Summary commit (if any small fixes landed)**

If any of the above turned up issues that needed inline fixes, commit them now:

```bash
git status
git add -p
git commit -m "chore: address local lint findings before CI push"
```

If everything was already clean, skip this step.

---

## Phase 10 — Push, iterate CI, verify acceptance

### Task 29: Configure GitHub remote (if not already done)

- [ ] **Step 1: Check remote**

```bash
git remote -v
```

- [ ] **Step 2: If no remote, add and push**

```bash
git remote add origin git@github.com:netf/fedora-bootc-starter.git
git push -u origin main
```

- [ ] **Step 3: If remote exists, push**

```bash
git push origin main
```

---

### Task 30: Watch the first CI run

- [ ] **Step 1: Open Actions**

```bash
gh run watch --exit-status || true
```

(Or visit `https://github.com/netf/fedora-bootc-starter/actions`.)

- [ ] **Step 2: If `lint` fails**

Read the failure, fix locally, re-run local Task 28, commit, push.

- [ ] **Step 3: If `build` fails (most likely failure modes)**

Common failures and where to look:

| Symptom | Likely cause | Fix |
|---|---|---|
| `dnf install` ENOENT on a package | package renamed/removed in F44 | update Containerfile package list |
| `framework_tool` build fails | Rust edition / hidapi version mismatch | bump `FW_TOOL_VERSION` arg or pin Rust toolchain |
| `dracut` complains about missing module | module name changed in F44 dracut | adjust `/usr/lib/dracut/dracut.conf.d/50-luks-unlock.conf` |
| Smoke test `command -v X` fails | package we think provides X actually provides something else | check `rpm -ql <pkg>`, update binary list in smoke block |
| `lsinitrd | grep tpm2` fails | dracut ran but didn't include modules | check dracut config + rebuild |
| `podman push` 403 | GHCR permission | repo settings → Actions → workflow permissions = read+write |
| Disk space error | intermediate image too big | increase "Free runner disk space" aggressiveness |

Fix, commit, push. Watch next run.

- [ ] **Step 4: If `e2e-vm` fails**

Common failures:

| Symptom | Likely cause | Fix |
|---|---|---|
| SSH never comes up | qcow2 image won't boot, OVMF path wrong, or kernel panic | download `vm-serial.log` artifact; look at boot output |
| `tpm2_pcrread` fails | swtpm not wired correctly OR initramfs missing tpm2-tss | check dracut conf, rebuild, re-run |
| Hardware-gate script greps fail | script wording doesn't match expected regex | adjust either the script's skip message or the grep |
| KVM not available | `/dev/kvm` permissions | the job chmod should fix; if it doesn't, GHA runner class changed |

Fix, commit, push.

- [ ] **Step 5: Verify green**

Once all three jobs green:

```bash
gh run list --limit 1
```

Expected: latest run shows `success` for all three jobs.

---

### Task 31: Verify signed image is pullable

Run on any Linux host with podman + cosign:

- [ ] **Step 1: Pull**

```bash
podman pull ghcr.io/netf/fedora-bootc-starter:44
```

Expected: pull succeeds.

- [ ] **Step 2: Verify signature**

```bash
cosign verify --key cosign.pub ghcr.io/netf/fedora-bootc-starter:44
```

Expected: verification succeeds, prints the signature claim JSON.

- [ ] **Step 3: Run the verify script**

```bash
./scripts/verify-image.sh
```

Expected: `✓ ghcr.io/netf/fedora-bootc-starter:44 verified`.

---

### Task 32: Nightly stability check

- [ ] **Step 1: Wait for 3 consecutive nightly runs to pass**

The nightly `0 4 * * *` schedule runs daily. After 3 consecutive green nightlies, flakiness is low enough to trust.

```bash
gh run list --workflow=build --event=schedule --limit 3
```

Expected: 3 most recent scheduled runs all `success`.

- [ ] **Step 2: If any flake, diagnose**

Download artifacts for the failed run:

```bash
gh run view <run-id> --log-failed
gh run download <run-id>
```

Fix the flake source (usually timing/wait-for-SSH, or a transient network issue with fwupd).

---

## Self-review

Final check against spec `docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md`:

| Spec section | Where in plan |
|---|---|
| §4 Parameterization | Task 22 (Containerfile ARG), Task 23 (Makefile var), Task 26 (workflow input) |
| §5 Architecture phases | Tasks 11–19 (first-boot), Task 20 (install-time), Task 22 (build-time) |
| §6.1 Package list | Task 22 |
| §6.3 Kargs | Task 22 |
| §6.4 Initramfs (rpm-q kernel detection, dracut modules + `systemd`) | Task 22 |
| §6.5 systemd unit at `/usr/lib/systemd/system/` | Task 9 + Task 22 (`systemctl enable`) |
| §7 Bootstrap library + scripts | Tasks 10–19 |
| §7.2 `--check` exit-code convention | Tasks 11–18 (each script follows exit 0 = skip/done, exit 1 = needs running) |
| §7.5 `run-all.sh` glob `[0-9]*.sh` | Task 19 (uses `find -name '[0-9]*.sh'`) |
| §8 Installer configs | Task 20 + Task 21 |
| §9 Signature enforcement | Task 7 (policy.json), Task 8 (registries.d), Task 4 (cosign bootstrap), Task 22 (build-time smoke) |
| §10 CI workflow | Task 26 |
| §10.2 Smoke test incl. initramfs grep + negative assertions | Task 26 `Smoke test` step |
| §10.3 e2e-vm with swtpm, SSH verify, hardware-gate grep | Task 26 `e2e-vm` job |
| §11 File inventory | Tasks 1–27 cover all listed files |
| §12 Acceptance criteria | Tasks 30–32 |
| §15 Corrections from guide.md | Applied throughout (parameterization, rpm-q kernel, openssl passwd comment, motd format, policy.json structure, digest signing, `systemd` dracut module, `[0-9]*.sh` glob, unit file location) |
| §16 Out-of-band prerequisites | Task 5 (user action) |

No placeholders detected. Type/path consistency verified (e.g., `systemd-cryptenroll`, `systemd-tpm2`, `systemd-fido2`, `systemd-recovery` token names used consistently across scripts; `/usr/share/bootstrap/` path used consistently).

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-23-fedora-bootc-starter-implementation.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Good for this plan because each task is well-isolated.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Simpler; keeps everything in one conversation.

**Which approach?**
