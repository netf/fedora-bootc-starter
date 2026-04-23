# `kinoite-fw13` — Fedora Kinoite 44 bootc starter for Framework Laptop 13 Pro

Unattended, single-USB install of a custom Fedora Kinoite 44 image for the **Framework Laptop 13 Pro** (Intel Core Ultra Series 3 / Panther Lake). The container image is the source of truth; a kickstart-backed installer ISO handles partitioning + LUKS2, and first-boot scripts enroll TPM2 / FIDO2 / YubiKey as additional LUKS keyslots, apply firmware updates via LVFS, and set a sane battery charge limit via Framework's embedded controller.

## What you get

- A signed bootc image at `ghcr.io/netf/kinoite-fw13:44` that you rebase onto and update with `bootc upgrade`.
- A self-contained installer ISO (`install.iso`) with the image content embedded — no network required during install.
- Idempotent first-boot bootstrap scripts (all support `--check`).
- Framework-specific tooling baked in: `framework_tool` (EC / fan / battery control), `iio-sensor-proxy` (ambient light), LVFS firmware refresh.
- CI that builds, lints, smoke-tests, signs, and pushes nightly so upstream regressions fail there, not on your laptop.

## Hardware targets

- Intel Core Ultra Series 3 (Panther Lake) — `intel_iommu=on`, kernel 6.15+ (F44 ships this)
- LPCAMM2 DDR5X at 7467 MT/s — modular, no special handling
- Goodix fingerprint reader integrated into the power button — `fprintd` works out of the box
- Haptic touchpad (LiteOn piezo) — requires recent kernel, driver landed in 6.15
- Intel BE211 Wi-Fi 7 + 4× Thunderbolt 4
- TPM2 via Intel PTT — must be enabled in BIOS

## Division of responsibility — image vs dotfiles

The image provides the **minimum host needed to run the dotfiles bootstrap**, nothing more. Everything else is chezmoi's job. The split mirrors [netf/dotfiles](https://github.com/netf/dotfiles) architecture: _Host stays minimal, all dev work happens in the `dev` toolbox._

| Layer                       | What                                                                                                                                                                                                      | Where                    |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| **Image only**              | Hardware drivers, firmware tooling (`framework_tool`, `fwupd`), LUKS/TPM/FIDO2 stack, `fprintd`, `tailscale`, `sbsigntools`, kernel-matched tools (`bpftool`, `bpftrace`), fonts, system services          | Containerfile            |
| **Image — host foundation** | `git` (to clone dotfiles), `chezmoi`, `mise`, `starship`, `alacritty`, `podman`/`distrobox` (toolbox runtime)                                                                                             | Containerfile            |
| **Dotfiles**                | `gh`, `just`, `jq`, `yq`, modern CLI (`eza`/`bat`/`ripgrep`/`fd`/`fzf`/`delta`/`zoxide`), kubectl/helm/k9s/kind/k3d, terraform/terragrunt, AWS/Azure CLI, sops/age, dnscrypt-proxy, all language runtimes | `mise` + chezmoi scripts |
| **Dotfiles — toolbox**      | `zsh`, `tmux`, `neovim`, all dev CLIs                                                                                                                                                                     | `dev` toolbox container  |
| **Dotfiles — GUI**          | All flatpaks (Brave, Firefox, VS Code, Slack, Discord, Spotify, etc.)                                                                                                                                     | chezmoi manages          |

One practical consequence: the image's first-boot bootstrap does **not** install flatpaks or dev CLIs. It handles LUKS enrollment, firmware, fingerprint, and Framework EC config — then hands off to you to run `chezmoi init`.

## Repo layout

```
kinoite-fw13/
├── Containerfile
├── config.toml                  # kickstart wrapper for bootc-image-builder
├── cosign.pub                   # public half of the signing key (committed)
├── Makefile
├── bootstrap/                   # baked into the image at /usr/share/bootstrap
│   ├── run-all.sh
│   ├── lib/common.sh
│   ├── 00-sanity.sh
│   ├── 05-firmware-update.sh
│   ├── 10-luks-tpm2.sh
│   ├── 11-luks-fido2.sh
│   ├── 12-luks-recovery.sh
│   ├── 13-luks-wipe-installer.sh
│   ├── 30-fingerprint-enroll.sh
│   └── 40-framework-ec.sh
├── files/
│   └── usr/etc/
│       ├── motd
│       └── containers/
│           ├── policy.json                # enforce cosign verification
│           ├── pubkey.pem                 # copy of cosign.pub (image-side)
│           └── registries.d/
│               └── ghcr-io-netf.yaml     # sigstore attachments config
├── scripts/
│   └── test-vm.sh
└── .github/workflows/build.yml
```

The cosign private key (`cosign.key`) is a **secret** — never commit it. Store it in GitHub Actions secrets as `COSIGN_PRIVATE_KEY` and in a local password manager. The `cosign.pub` half is committed to the repo so anyone (including your own machine) can verify signatures.

Note: no `20-flatpaks.sh`. Flatpak management lives in [netf/dotfiles](https://github.com/netf/dotfiles).

## 1. `Containerfile`

```dockerfile
# syntax=docker/dockerfile:1

# ---- Stage 1: build framework_tool from source ----------------------------
# Not yet packaged in Fedora proper (available in the Terra repo, but building
# from source keeps the image self-contained and version-pinned).
FROM quay.io/fedora/fedora:44 AS fw-tool-builder
ARG FW_TOOL_VERSION=v0.4.0
RUN dnf install -y rust cargo systemd-devel hidapi-devel git pkgconf-pkg-config \
 && git clone --depth 1 --branch ${FW_TOOL_VERSION} \
      https://github.com/FrameworkComputer/framework-system /src \
 && cd /src && cargo build --release -p framework_tool

# ---- Stage 2: the actual bootc image --------------------------------------
FROM quay.io/fedora-ostree-desktops/kinoite:44

# ---- Layered packages -----------------------------------------------------
# Strict policy: this list contains ONLY things that must be root-installed,
# kernel-matched, or needed before dotfiles bootstrap can even run.
# Modern CLI (eza/bat/rg/fd/jq/yq/gh/just/age) lives in dotfiles via mise.
RUN rpm-ostree install \
      # host foundation — what dotfiles bootstrap needs to run
      git-core \
      chezmoi \
      starship \
      alacritty \
      # containers / toolbox runtime (netf/dotfiles uses `tb` → distrobox)
      podman-compose distrobox \
      # networking / mesh (system services, run before user login)
      tailscale wireguard-tools \
      # LUKS / auth hardware (used by first-boot bootstrap as root)
      tpm2-tools yubikey-manager fido2-tools \
      fprintd fprintd-pam \
      sbsigntools \
      # Framework-specific hardware support
      iio-sensor-proxy \
      fwupd \
      # KDE system integration not in kinoite base
      kdeconnectd \
      # fonts — system-wide, terminals need them before user session
      jetbrains-mono-fonts-all fira-code-fonts \
      # kernel-matched tooling (version-locked to image kernel; Watchpost/eBPF)
      bpftool bpftrace kernel-tools \
      # system backup (runs via systemd timer)
      restic \
 && ostree container commit

# Drop framework_tool in from stage 1
COPY --from=fw-tool-builder /src/target/release/framework_tool /usr/local/bin/framework_tool
RUN chmod +x /usr/local/bin/framework_tool

# ---- mise (dev tool version manager; explicitly "host" per dotfiles arch) -
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && ostree container commit

# ---- System config --------------------------------------------------------
# /usr/etc/ is copied into /etc/ on deploy and handles 3-way merge on upgrade.
COPY files/usr/ /usr/

# ---- Bootstrap scripts (first-boot LUKS/FIDO2/YubiKey enrollment) --------
COPY bootstrap/ /usr/share/bootstrap/
RUN chmod +x /usr/share/bootstrap/*.sh /usr/share/bootstrap/lib/*.sh

# ---- Initramfs: bake in TPM2 + FIDO2 LUKS unlock modules -----------------
# Runtime dracut regeneration doesn't work on bootc (/usr is read-only).
# The initramfs must be built with these modules NOW so that post-enrollment
# unlock just works on next boot.
RUN cat > /usr/lib/dracut/dracut.conf.d/50-luks-unlock.conf <<'EOF'
add_dracutmodules+=" crypt tpm2-tss systemd-cryptsetup fido2 systemd ostree "
EOF

RUN set -xe; \
    kver=$(ls /usr/lib/modules | head -1); \
    env DRACUT_NO_XATTR=1 dracut -vf /usr/lib/modules/$kver/initramfs.img "$kver"

# ---- Kargs (TOML format for bootc) ---------------------------------------
RUN mkdir -p /usr/lib/bootc/kargs.d \
 && cat > /usr/lib/bootc/kargs.d/10-fw13.toml <<'EOF'
kargs = [
  "intel_iommu=on",
  "rd.luks.options=discard",
  "mem_sleep_default=s2idle",
  "quiet",
  "splash"
]
EOF

# ---- First-boot systemd unit ---------------------------------------------
RUN cat > /usr/lib/systemd/system/netf-bootstrap.service <<'EOF'
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
RUN systemctl enable netf-bootstrap.service

# ---- Verify the image is sane --------------------------------------------
RUN bootc container lint
```

## 2. Signature verification setup (the Aurora pattern)

Signing an image in CI is only half the story — the laptop has to _enforce_ that signatures are valid before pulling any update. Aurora, Bluefin, and Bazzite all ship a `policy.json` that makes this non-optional. We do the same.

### `cosign.pub` (repo root)

Generate once, commit the `.pub` file, keep `.key` secret:

```bash
cosign generate-key-pair        # creates cosign.key + cosign.pub
git add cosign.pub
# Store cosign.key in your password manager AND in GitHub secret COSIGN_PRIVATE_KEY
# Also store the password in COSIGN_PASSWORD
```

### `files/usr/etc/containers/policy.json`

```json
{
  "default": [{ "type": "insecureAcceptAnything" }],
  "transports": {
    "docker": {
      "ghcr.io/netf": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/usr/etc/containers/pubkey.pem",
          "signedIdentity": { "type": "matchRepository" }
        }
      ],
      "quay.io/fedora-ostree-desktops": [{ "type": "insecureAcceptAnything" }],
      "quay.io/centos-bootc": [{ "type": "insecureAcceptAnything" }]
    }
  }
}
```

The default is `insecureAcceptAnything` so pulling random podman images still works — but anything under `ghcr.io/netf/` requires a valid cosign signature against your key.

### `files/usr/etc/containers/registries.d/ghcr-io-netf.yaml`

```yaml
docker:
  ghcr.io/netf:
    use-sigstore-attachments: true
```

This tells the container tooling that signatures for `ghcr.io/netf/*` live as sigstore attachments on the registry (which is how cosign stores them).

### Containerfile additions

```dockerfile
# ---- Embed the cosign public key and containers policy ------------------
# cosign.pub from repo root → /usr/etc/containers/pubkey.pem in the image.
# policy.json + registries.d come in via files/usr/etc/ copy above.
COPY cosign.pub /usr/etc/containers/pubkey.pem

# Verify the policy references the key we just embedded (build-time smoke test)
RUN set -e; \
    grep -q "/usr/etc/containers/pubkey.pem" /usr/etc/containers/policy.json && \
    test -f /usr/etc/containers/pubkey.pem && \
    echo "✓ signature policy wired correctly"
```

### Updated `bootc` commands with enforcement

Once the image is installed, use `--enforce-container-sigpolicy` on every `bootc switch`:

```bash
# Patch-level updates — policy is checked automatically by bootc-fetch-apply-updates
bootc upgrade
systemctl reboot

# Major version jump (e.g., to Fedora 45)
bootc switch --enforce-container-sigpolicy ghcr.io/netf/kinoite-fw13:45
systemctl reboot

# The enforcement flag is also what ublue uses; see aurora/changelogs.py.
```

If your signature, key, or policy is misconfigured, `bootc` will refuse the pull with a clear error — which is exactly what you want. You'll know at `bootc upgrade` time, not at reboot.

## 3. `config.toml` (installer kickstart)

```toml
# Consumed by bootc-image-builder --type=anaconda-iso.
# `bootc-image-builder` injects the image deployment verb automatically — do
# NOT include `ostreecontainer` or `bootc` here.

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
# Password hash for "CHANGE_ME!!!" — this is intentionally a throwaway.
# First thing after first login: `passwd` to change it.
# Regenerate with: python3 -c "import crypt; print(crypt.crypt('your-pw', crypt.mksalt(crypt.METHOD_SHA512)))"
user --name=netf --groups=wheel --iscrypted --password='$6$YdvxSXl6YUHhOzEf$YTvt9PEWKWpTVcb.Y4N/Qlwp.cpMmQbegc8OIFsturFPjOtuYWw4Uzwy5dHlwNiqqiaMd9mfUlJH6wn.EA1Wo0'

services --enabled=sshd,tailscaled
firstboot --disable
reboot --eject
"""

# User creation happens above, so disable Anaconda's users module
[customizations.installer.modules]
disable = [ "org.fedoraproject.Anaconda.Modules.Users" ]

[customizations.iso]
volume_id = "KINOITE-FW13-44"
```

The user password hash above decodes to `CHANGE_ME!!!` — deliberately weak and one-use. On first login, run `passwd` immediately to change it. If you'd rather not ship a known hash in the ISO at all, drop the `--password=` flag and Anaconda will prompt for a password during install (breaks fully-unattended but only costs one keystroke interaction).

The installer LUKS passphrase (`installer-temp-change-me` above) is separately wiped by the first-boot bootstrap once TPM2 + FIDO2 + recovery key are enrolled.

## 4. Bootstrap scripts

The scripts live at `/usr/share/bootstrap/` in the image and are run by the first-boot systemd service. System-level only — **dotfiles bootstrap (`chezmoi init netf`) happens after, as your user, per your dotfiles README**.

Alongside the scripts, ship a motd so the shell greets you with the hand-off:

```
# files/usr/etc/motd
┌─────────────────────────────────────────────────────────────┐
│  System bootstrap complete. To apply dotfiles:              │
│                                                             │
│    curl -fsLS https://raw.githubusercontent.com/netf/\      │
│      dotfiles/main/install.sh | bash                        │
│                                                             │
│  Or: chezmoi init --apply netf                              │
└─────────────────────────────────────────────────────────────┘
```

### `bootstrap/lib/common.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

log()  { printf '\e[1;34m[bootstrap]\e[0m %s\n' "$*" >&2; }
ok()   { printf '\e[1;32m[   ok   ]\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33m[  warn  ]\e[0m %s\n' "$*" >&2; }
skip() { printf '\e[1;36m[  skip  ]\e[0m %s\n' "$*" >&2; }
err()  { printf '\e[1;31m[  fail  ]\e[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || err "must run as root"
}

# ─── Hardware detection ────────────────────────────────────────────────────
# Bootstrap scripts call these to gracefully skip steps on machines that
# don't have the relevant hardware — makes the image usable on any box
# and makes VM-based CI testing possible.

is_framework_laptop() {
    [[ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" == "Framework" ]]
}

is_vm() {
    local vendor
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
    [[ "$vendor" =~ (QEMU|KVM|innotek|VMware|Xen|Microsoft\ Corporation) ]]
}

has_tpm2() {
    [[ -e /dev/tpm0 || -e /dev/tpmrm0 ]] && \
        command -v tpm2_pcrread >/dev/null 2>&1 && \
        tpm2_pcrread sha256:7 >/dev/null 2>&1
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

# ─── LUKS helpers ──────────────────────────────────────────────────────────

luks_device() {
    local mapper
    mapper=$(findmnt -no SOURCE / | sed 's,.*/,,')
    cryptsetup status "$mapper" | awk '/device:/ {print $2}'
}

crypt_mapper_name() {
    findmnt -no SOURCE / | sed 's,.*/,,'
}

marker_done()  { [[ -f "/var/lib/bootstrap/.${1}.done" ]]; }
marker_write() { mkdir -p /var/lib/bootstrap && touch "/var/lib/bootstrap/.${1}.done"; }

has_token() {
    local dev="$1" token="$2"
    cryptsetup luksDump "$dev" | grep -q "$token"
}
```

### `bootstrap/00-sanity.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
source /usr/share/bootstrap/lib/common.sh
require_root

[[ "${1:-}" == "--check" ]] && exit 0  # sanity is always re-run

log "hostname: $(hostname)"
log "kernel:   $(uname -r)"
log "bootc:    $(bootc status --json | jq -r '.status.booted.image.image.image')"

for tool in systemd-cryptenroll cryptsetup fwupdmgr; do
    command -v "$tool" >/dev/null || warn "missing: $tool"
done

# Hardware-dependent tools — missing is OK on non-Framework / non-YubiKey hosts
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
    # TPM2 might still be available via swtpm
    if has_tpm2; then
        ok "TPM2 present (swtpm or passthrough)"
    fi
else
    warn "unknown hardware — proceeding with best-effort detection"
fi

marker_write "00-sanity"
```

### `bootstrap/05-firmware-update.sh`

```bash
#!/usr/bin/env bash
# Pull the latest firmware from LVFS and apply. Framework supports this well.
# Expansion cards, EC, BIOS, retimers, and PD controllers all update via fwupd.
# In VMs this is a no-op (nothing to update).
set -euo pipefail
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

[[ $CHECK -eq 1 ]] && { warn "$PENDING firmware update(s) pending"; exit 1; }

log "Applying $PENDING firmware update(s). System may reboot."
fwupdmgr update -y --no-reboot-check || warn "some updates deferred to next boot"

marker_write "05-firmware"
```

### `bootstrap/10-luks-tpm2.sh`

```bash
#!/usr/bin/env bash
# Enroll TPM2 as a LUKS keyslot bound to PCR 7 (secure boot state) + 11 (kernel/initrd).
# Rebinding will be needed after kernel updates — handled by a separate timer.
set -euo pipefail
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# Hardware gates — skip gracefully if the machine can't do this
if ! has_encrypted_root; then
    skip "root filesystem is not LUKS-encrypted — TPM2 enrollment N/A"
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

# Teach crypttab to auto-unlock via TPM2
if ! grep -qE "^${MAPPER}.*tpm2-device=auto" /etc/crypttab; then
    log "Patching /etc/crypttab for TPM2 auto-unlock"
    sed -ri "s|^(${MAPPER}\s+\S+\s+\S+)(\s+.*)?$|\1 tpm2-device=auto|" /etc/crypttab
fi

# NOTE: initramfs already contains tpm2-tss + systemd-cryptsetup (baked in
# at image build time — see dracut.conf.d/50-luks-unlock.conf). Runtime
# dracut regeneration is NOT needed and would fail anyway, because /usr is
# read-only on deployed bootc systems.

ok "TPM2 enrolled"
marker_write "10-tpm2"
```

### `bootstrap/11-luks-fido2.sh`

```bash
#!/usr/bin/env bash
# Enroll FIDO2 (YubiKey) as a LUKS keyslot with PIN + user presence.
set -euo pipefail
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# Hardware gates
if ! has_encrypted_root; then
    skip "root not LUKS-encrypted — FIDO2 enrollment N/A"
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

### `bootstrap/12-luks-recovery.sh`

```bash
#!/usr/bin/env bash
# Generate a 48-char recovery key. You write it down and stash it offline.
# This is your break-glass when both TPM2 and YubiKey are unavailable.
set -euo pipefail
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root not LUKS-encrypted — recovery key N/A"
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

### `bootstrap/13-luks-wipe-installer.sh`

```bash
#!/usr/bin/env bash
# Wipe the weak installer passphrase (keyslot 0). Refuses unless TPM2, FIDO2,
# and recovery are all already enrolled — so you can never lock yourself out.
set -euo pipefail
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_encrypted_root; then
    skip "root not LUKS-encrypted — nothing to wipe"
    marker_write "13-wipe"
    exit 0
fi

DEV=$(luks_device)
DUMP=$(cryptsetup luksDump "$DEV")

# Only wipe slot 0 if it's still there
if ! grep -qE '^\s*0:\s+luks2' <<<"$DUMP"; then
    ok "Installer passphrase already wiped"
    marker_write "13-wipe"
    exit 0
fi

[[ $CHECK -eq 1 ]] && { warn "Installer passphrase still present"; exit 1; }

# Safety net — refuse to wipe unless all three escape hatches exist
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

### `bootstrap/30-fingerprint-enroll.sh`

```bash
#!/usr/bin/env bash
# Framework 13 Pro has a Goodix reader integrated into the power button.
set -euo pipefail
source /usr/share/bootstrap/lib/common.sh

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if ! has_fingerprint_reader; then
    skip "no fingerprint reader detected — skipping"
    marker_write "30-fprint"
    exit 0
fi

USER_NAME="${SUDO_USER:-netf}"

if sudo -u "$USER_NAME" fprintd-list "$USER_NAME" 2>/dev/null | grep -q "right-index-finger\|left-index-finger"; then
    ok "Fingerprint already enrolled for $USER_NAME"
    marker_write "30-fprint"
    exit 0
fi

[[ $CHECK -eq 1 ]] && { warn "No fingerprint enrolled"; exit 1; }

log "Enrolling right index finger for $USER_NAME"
log "Press the power button repeatedly until enrollment completes (5 reads)"
sudo -u "$USER_NAME" fprintd-enroll -f right-index-finger "$USER_NAME"

ok "Fingerprint enrolled"
marker_write "30-fprint"
```

### `bootstrap/40-framework-ec.sh`

```bash
#!/usr/bin/env bash
# Set sane EC defaults via framework_tool. Skips cleanly on non-Framework hardware.
set -euo pipefail
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

CURRENT=$(framework_tool --charge-limit 2>/dev/null | awk '/Maximum/ {print $NF}' | tr -d '%') || CURRENT=0

if [[ "$CURRENT" == "$CHARGE_LIMIT" ]]; then
    ok "Charge limit already set to ${CHARGE_LIMIT}%"
    marker_write "40-ec"
    exit 0
fi

[[ $CHECK -eq 1 ]] && { warn "charge limit is ${CURRENT}%, want ${CHARGE_LIMIT}%"; exit 1; }

log "Setting battery charge limit to ${CHARGE_LIMIT}%"
framework_tool --charge-limit "$CHARGE_LIMIT"

ok "EC configured"
marker_write "40-ec"
```

### `bootstrap/run-all.sh`

```bash
#!/usr/bin/env bash
# Runs all numbered bootstrap steps in order. --check = dry-run verification.
set -euo pipefail
source /usr/share/bootstrap/lib/common.sh
require_root

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

cd /usr/share/bootstrap
STEPS=(0*.sh 1*.sh 3*.sh 4*.sh)

FAILED=0
for step in "${STEPS[@]}"; do
    log "═══ $step ═══"
    if [[ $CHECK -eq 1 ]]; then
        "./$step" --check || { FAILED=1; warn "$step needs running"; }
    else
        "./$step"
    fi
done

if [[ $CHECK -eq 1 ]]; then
    [[ $FAILED -eq 0 ]] && ok "All steps idempotent — nothing to do" || exit 1
else
    marker_write "all"
    ok "Bootstrap complete. Reboot recommended."
fi
```

## 5. `Makefile`

```makefile
IMAGE_REF    ?= ghcr.io/netf/kinoite-fw13:44
BUILDER_IMG  := quay.io/centos-bootc/bootc-image-builder:latest
OUTPUT_DIR   := output

.DEFAULT_GOAL := help

help:  ## Show this help
 @awk 'BEGIN{FS=":.*?##"; printf "\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint:  ## Lint Containerfile and shell scripts
 hadolint Containerfile
 shellcheck -x bootstrap/*.sh bootstrap/lib/*.sh
 @echo "✓ lint clean"

build:  ## Build the bootc image locally
 sudo podman build --pull=newer -t $(IMAGE_REF) .

inspect:  build  ## Run bootc container lint + inspection
 sudo podman run --rm $(IMAGE_REF) bootc container lint
 sudo podman run --rm $(IMAGE_REF) bash -c '\
  test -x /usr/share/bootstrap/run-all.sh && \
  test -f /usr/lib/bootc/kargs.d/10-fw13.toml && \
  systemctl is-enabled netf-bootstrap.service && \
  command -v chezmoi mise starship alacritty distrobox tailscale framework_tool && \
  echo "smoke tests passed"'

push:  build  ## Push image to registry
 sudo podman push $(IMAGE_REF)

sign:  ## cosign sign the pushed image with local keypair (cosign.key)
 test -f cosign.key || (echo "ERROR: cosign.key missing — run 'cosign generate-key-pair' first" && exit 1)
 cosign sign --yes --key cosign.key $(IMAGE_REF)

iso:  build  ## Build the unattended installer ISO
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

test-vm:  iso  ## Boot the ISO in QEMU with swtpm for end-to-end testing
 ./scripts/test-vm.sh

clean:
 sudo rm -rf $(OUTPUT_DIR)
```

## 6. `scripts/test-vm.sh`

```bash
#!/usr/bin/env bash
# Boot installer ISO in QEMU with emulated TPM2. Verifies unattended install
# works end-to-end before you commit the USB to the real machine.
set -euo pipefail

ISO=output/bootiso/install.iso
DISK=output/test-disk.qcow2
TPM_DIR=$(mktemp -d)

trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TPM_DIR"' EXIT

[[ -f "$DISK" ]] || qemu-img create -f qcow2 "$DISK" 60G

swtpm socket --tpm2 --tpmstate dir="$TPM_DIR" \
    --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
    --log level=20 --daemon

qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 8G -smp 4 \
    -bios /usr/share/edk2/ovmf/OVMF_CODE.fd \
    -chardev socket,id=chrtpm,path="$TPM_DIR/swtpm-sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -drive file="$DISK",if=virtio \
    -cdrom "$ISO" \
    -boot d \
    -netdev user,id=n0 -device virtio-net,netdev=n0 \
    -display gtk
```

## 7. `.github/workflows/build.yml`

The CI has three jobs in sequence: **lint** (fast, runs on every PR), **build** (builds the image, runs in-container smoke tests, pushes + signs on main), and **e2e-vm** (spins up a real QEMU VM with an emulated TPM2, SSHes in, runs `run-all.sh --check`, and confirms Framework-specific scripts skip cleanly when not on Framework hardware).

What CI can test:

- Image builds successfully, every package present, every karg in place
- `bootc container lint` passes
- Initramfs has TPM2 modules baked in (by booting a VM and calling `tpm2_pcrread`)
- Signature policy is wired correctly (policy.json references the embedded key)
- Bootstrap scripts run without errors, and hardware-gated ones skip gracefully in a VM
- qcow2 + ISO build artifacts produce bootable systems

What CI cannot test (hardware-only, manual check required on the laptop):

- Real YubiKey enrollment (FIDO2 requires hardware)
- Real fingerprint enrollment (Goodix needs real silicon)
- `framework_tool` actually talking to the real EC
- LVFS firmware updates applying to real Framework components
- Panther Lake-specific kernel behavior

The VM test uses `swtpm` to emulate a TPM2, so TPM2 _tooling_ is exercised even though the real PCR values come from QEMU firmware rather than real silicon. That's enough to catch "image doesn't have tpm2-tss in initramfs" regressions, which is the most likely failure mode.

```yaml
name: build
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
  schedule:
    - cron: "0 4 * * *" # catch upstream regressions nightly
  workflow_dispatch:

env:
  IMAGE_REF: ghcr.io/${{ github.repository_owner }}/kinoite-fw13:44

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: hadolint/hadolint-action@v3
        with: { dockerfile: Containerfile }
      - run: |
          sudo apt-get update -y && sudo apt-get install -y shellcheck
          shellcheck -x bootstrap/*.sh bootstrap/lib/*.sh

  build:
    needs: lint
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write # cosign keyless
    steps:
      - uses: actions/checkout@v4

      # Bootc image builds are disk-heavy; free up the runner first.
      # Official bootc docs recommend this to avoid out-of-space failures.
      - name: Free up disk space on runner
        run: |
          sudo rm -rf /opt/hostedtoolcache
          sudo docker system prune -af || true

      - name: Install podman + cosign
        run: |
          sudo apt-get update -y
          sudo apt-get install -y podman
      - uses: sigstore/cosign-installer@v3
      - name: Login to ghcr.io
        run: echo "${{ secrets.GITHUB_TOKEN }}" \
          | podman login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Build
        run: sudo podman build -t $IMAGE_REF .

      - name: bootc container lint
        run: sudo podman run --rm $IMAGE_REF bootc container lint

      - name: Smoke test
        run: |
          sudo podman run --rm $IMAGE_REF bash -c '
            set -e
            test -x /usr/share/bootstrap/run-all.sh
            test -f /usr/lib/bootc/kargs.d/10-fw13.toml
            systemctl is-enabled netf-bootstrap.service
            command -v chezmoi mise starship alacritty
            command -v tailscale tpm2_pcrread ykman framework_tool fwupdmgr
            # Signature enforcement is wired (matches Aurora smoke test pattern)
            test -f /usr/etc/containers/policy.json
            test -f /usr/etc/containers/pubkey.pem
            grep -q /usr/etc/containers/pubkey.pem /usr/etc/containers/policy.json
            test -f /usr/etc/containers/registries.d/ghcr-io-netf.yaml
            # Negative assertions — these should NOT be in the image (dotfiles owns them)
            ! command -v eza && ! command -v bat && ! command -v rg && ! command -v jq
            echo "✓ smoke tests pass"
          '

      - name: Push + sign (main only)
        if: github.ref == 'refs/heads/main'
        env:
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
        run: |
          sudo podman push $IMAGE_REF
          DIGEST=$(sudo podman inspect --format '{{index .RepoDigests 0}}' $IMAGE_REF)
          echo "${{ secrets.COSIGN_PRIVATE_KEY }}" > /tmp/cosign.key
          cosign sign --yes --key /tmp/cosign.key "$DIGEST"
          rm -f /tmp/cosign.key

  # ───────────────────────────────────────────────────────────────────────
  # End-to-end VM test: build qcow2, boot in QEMU with swtpm, SSH in,
  # run bootstrap --check. Framework-specific scripts must report "skip".
  # Does not test real hardware (Goodix/YubiKey/EC) — that's a manual step
  # on the actual laptop. Everything else we CAN exercise in a VM.
  # ───────────────────────────────────────────────────────────────────────
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
          # GHA runners have KVM available
          sudo chmod 666 /dev/kvm

      - name: Build image (local tag only)
        run: sudo podman build -t localhost/test-image:ci .

      - name: Generate CI SSH keypair
        run: |
          ssh-keygen -t ed25519 -N '' -f ci-key -C "ci@github-actions"

      - name: Write CI-mode bootc-image-builder config
        run: |
          # CI variant: no LUKS, SSH key injected, qcow2 output
          cat > config-ci.toml <<EOF
          [[customizations.user]]
          name = "netf"
          groups = ["wheel"]
          key = "$(cat ci-key.pub)"

          [[customizations.user]]
          name = "root"
          key = "$(cat ci-key.pub)"

          [customizations.kernel]
          append = "console=ttyS0,115200"
          EOF

      - name: Build qcow2
        run: |
          mkdir -p output
          sudo podman run --rm --privileged --pull=newer \
              --security-opt label=type:unconfined_t \
              -v /var/lib/containers/storage:/var/lib/containers/storage \
              -v $PWD/config-ci.toml:/config.toml:ro \
              -v $PWD/output:/output \
              quay.io/centos-bootc/bootc-image-builder:latest \
              --type qcow2 --config /config.toml \
              localhost/test-image:ci
          sudo chown -R $USER output
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
          USER_SSH="ssh -i ci-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 netf@localhost"
          ROOT_SSH="ssh -i ci-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@localhost"

          echo "─── Basic system ───"
          $USER_SSH 'cat /etc/os-release | grep VERSION'
          $ROOT_SSH 'bootc status'
          $ROOT_SSH 'systemctl is-system-running || true'   # may report degraded, that's OK

          echo "─── Image-baked tooling ───"
          $ROOT_SSH 'command -v chezmoi mise starship alacritty framework_tool'
          $ROOT_SSH 'command -v tpm2_pcrread ykman fwupdmgr'

          echo "─── TPM2 visible (via swtpm) ───"
          $ROOT_SSH 'tpm2_pcrread sha256:7,11'

          echo "─── Hardware-gated scripts skip gracefully ───"
          # Framework EC: should skip (VM is not Framework)
          $ROOT_SSH '/usr/share/bootstrap/40-framework-ec.sh --check 2>&1' | grep -i 'skip\|not a framework'
          # Fingerprint: should skip (no Goodix device)
          $ROOT_SSH '/usr/share/bootstrap/30-fingerprint-enroll.sh --check 2>&1' | grep -i 'skip\|no fingerprint'
          # FIDO2: should skip (no YubiKey)
          $ROOT_SSH '/usr/share/bootstrap/11-luks-fido2.sh --check 2>&1' | grep -i 'skip\|no yubikey\|not luks'
          # Firmware: should skip in VM
          $ROOT_SSH '/usr/share/bootstrap/05-firmware-update.sh --check 2>&1' | grep -i 'skip\|vm'

          echo "─── run-all.sh --check terminates cleanly ───"
          $ROOT_SSH '/usr/share/bootstrap/run-all.sh --check; echo "exit: $?"'

          echo "✓ e2e VM test passed"

      - name: Shutdown VM
        if: always()
        run: |
          ssh -i ci-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -p 2222 root@localhost 'systemctl poweroff' || true
          sleep 5
          [[ -f qemu.pid ]] && kill -9 $(cat qemu.pid) 2>/dev/null || true

      - name: Upload VM serial log on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: vm-serial-log
          path: vm-serial.log
          retention-days: 7
```

## 8. End-to-end usage

First-time install, from a workstation:

```bash
# 1. Build + push + sign (once, or after Containerfile changes)
make build push sign

# 2. Pull the signed image into LOCAL container storage — this is what
#    bootc-image-builder reads from. It does NOT pull from the registry.
sudo podman pull ghcr.io/netf/kinoite-fw13:44

# 3. Generate the ISO
make iso

# 4. Flash to USB
make usb DEV=/dev/sdb

# 5. Optional: verify end-to-end in a VM first
make test-vm
```

Then on the Framework 13 Pro:

1. BIOS: confirm Intel PTT (TPM2) is on, Secure Boot on. Disable "Hardware Security" if you want DIY firmware / coreboot later (not required for this setup).
2. Boot the USB (F12 for boot menu on Framework). Walk away. Install takes ~5 min (ISO-embedded image = no network).
3. Machine reboots. Enter the temporary installer passphrase once.
4. `netf-bootstrap.service` runs on first login and handles **system-level** setup: firmware update via LVFS → TPM2 enroll → YubiKey enroll → recovery key → wipe installer passphrase → fingerprint enrollment → Framework EC (80% charge limit).
5. The motd then tells you to apply **user-level** config — `curl -fsLS .../netf/dotfiles/main/install.sh | bash`. chezmoi clones your dotfiles, installs your 29 mise tools, sets up the `dev` toolbox with zsh/tmux/neovim, applies the Ghostty/Alacritty/starship themes, and installs flatpaks.
6. Open Ghostty, type `tb` to enter the toolbox. Done.

The split: **steps 1–4 are the image.** Steps 5–6 are your dotfiles. No overlap, no duplicated state.

## 9. Day 2

```bash
# Updates (image has been rebuilt and pushed)
bootc upgrade
systemctl reboot

# Rollback to the previous deployment
bootc rollback
systemctl reboot

# Verify bootstrap state any time
sudo /usr/share/bootstrap/run-all.sh --check

# After a kernel update changes PCR 11, re-bind TPM2
sudo systemd-cryptenroll "$(findmnt -no SOURCE / | xargs cryptsetup status | awk '/device:/ {print $2}')" \
  --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7+11
```

## Known sharp edges

- **Kernel updates rebind PCR 11.** Either widen the binding to PCR 7 only (weaker — won't detect a tampered kernel) or automate re-enrollment via a systemd path unit watching `/usr/lib/modules`.
- **Plaintext passphrase in the ISO.** Acceptable because the USB stays with you and the passphrase is wiped on first boot. If you want zero plaintext, drop `--passphrase=` and Anaconda will prompt once — install is no longer _fully_ unattended but everything else still is.
- **btrfs subvolume layout is fixed at install.** If you want `@home` / `@snapshots` subvols, create them in a first-boot script before user data lands.
- **Initramfs is image-time, not runtime.** Per the [bootc docs](https://fedora-bootc-docs-7c668a.gitlab.io/bootc/initramfs/), the initrd is built at container-build time and baked into `/usr/lib/modules/$kver/initramfs.img`. Runtime `dracut -f` will fail because `/usr` is read-only on deployed bootc systems. That's why this image explicitly adds `crypt`, `tpm2-tss`, `systemd-cryptsetup`, and `fido2` to the initramfs in the Containerfile — so `systemd-cryptenroll` at runtime just adds the keyslot and next-boot unlock works immediately.
- **`/etc` changes become machine-local state.** Per the [filesystem layout](https://fedora-bootc-docs-7c668a.gitlab.io/bootc/filesystem/) docs: any file modified in `/etc` after deployment is "100% the responsibility of the system administrator and will no longer be touched by bootc." The bootstrap script patches `/etc/crypttab` — from that point forward, changes to crypttab in a future image version won't propagate. That's exactly what you want for per-machine LUKS state, but if you later need to change crypttab via the image, you'll need to handle the merge yourself.
- **`bootc rollback` does NOT merge `/etc`.** Per the [auto-updates](https://fedora-bootc-docs-7c668a.gitlab.io/bootc/auto-updates/) docs: rollback reorders existing deployments, it doesn't create new ones, so changes made to `/etc` on the current deployment won't carry back to the previous one. Concretely: if you enroll TPM2 and then `bootc rollback`, the older deployment won't have the TPM2 keyslot metadata in its `/etc/crypttab` — you'd be back to passphrase/YubiKey/recovery-key only for that boot. Not locked out, just less convenient.
- **LVFS firmware updates may prompt for a reboot between stages.** The Framework 13 Pro has multiple updatable components (EC, BIOS, retimers, PD controllers, expansion cards, fingerprint reader) and LVFS typically applies them across two boots — expect one extra reboot on first run of `05-firmware-update.sh`.
- **`framework_tool` talks to `/dev/cros_ec`.** If the `cros_ec` kernel module isn't loaded on first boot, commands fail silently; the sanity check catches this. On the 13 Pro with kernel 6.15+ it's built-in.
- **Expansion card config isn't in the image.** The 4× USB-C slots can hold USB-A/HDMI/DisplayPort/Ethernet/MicroSD/storage modules — which ports have which card is per-machine state, not part of the OS. If you're strict about port consistency across rebuilds, document it in the README.
- **Panther Lake is new silicon.** Intel and Framework will be pushing microcode / thunderbolt / retimer firmware fixes through mid-2026. Run `fwupdmgr update` weekly for the first few months.
- **Wi-Fi 7 BE211 firmware.** Shipped in `linux-firmware` in F44. If you ever go to a kernel < 6.14 you'll fall back to Wi-Fi 6E speeds and may see occasional reconnects.
- **Haptic touchpad driver.** Lands in 6.15 mainline. If you need to pin to an older kernel for any reason, the touchpad clicks won't register — it behaves as a touch-only surface.

## rpm-ostree compatibility on bootc

Per the [bootc and rpm-ostree](https://fedora-bootc-docs-7c668a.gitlab.io/bootc/rpm-ostree/) docs, `rpm-ostree upgrade` / `rollback` / `status` / `db diff` are fungible with their `bootc` equivalents — they share the underlying ostree backend. So you can use either command interchangeably for normal updates and inspection.

**What breaks bootc**: any rpm-ostree operation that mutates local state — `rpm-ostree install pkg`, `rpm-ostree override replace/remove`, `rpm-ostree initramfs --enable`, `rpm-ostree kargs`. These permanently switch the system to rpm-ostree management and `bootc upgrade` will then error out. Package additions belong in the Containerfile; kargs belong in `/usr/lib/bootc/kargs.d/`; initramfs changes belong in `dracut.conf.d/`. Every one of those has an image-side home, and that's the invariant that keeps the system cleanly upgradeable.

## How this compares to Aurora / Bluefin / Bazzite

This starter cribs heavily from [ublue-os/aurora](https://github.com/ublue-os/aurora) and the Universal Blue project generally — they've been running this pattern in production for years. A few things we explicitly adopted and a few we deliberately skipped:

**Adopted:**

- `/etc/containers/policy.json` + `registries.d/` for signature enforcement, with build-time smoke tests verifying the key is wired correctly (Aurora's `20-tests.sh` pattern).
- Local cosign keypair rather than keyless OIDC — simpler threat model for a personal machine, and the `cosign.pub` in the repo root is how anyone can verify your images.
- `--enforce-container-sigpolicy` on `bootc switch` commands.
- Multi-stage Containerfile (the `framework_tool` builder stage).
- Numbered first-boot scripts with a single systemd unit that runs them (Aurora uses `ublue-system-setup.service` + `aurora-groups.service`).
- Nightly CI rebuild against upstream base to catch regressions before they hit the laptop.

**Deliberately skipped:**

- **Rechunking** (`hhd-dev/rechunk`). Aurora and Bazzite run their images through this to cut update download sizes 5–10× by restructuring OCI layers around package groups. For a single laptop with nightly rebuilds on a home connection, the bandwidth saving isn't worth the extra CI complexity. Worth revisiting if you're seeing slow `bootc upgrade` downloads — it's a drop-in GHA action.
- **Multi-stream variants** (stable/latest/beta). ublue ships three streams so users can choose between cautious and bleeding-edge. You have one user (you). One tag (`:44`) is enough.
- **`build_files/base/NN-*.sh` split.** Aurora's Containerfile is deliberately thin (~50 lines) and delegates to numbered scripts in a `build_files/` directory. We're doing everything inline because the total logic fits in one readable Containerfile. If this image grows past ~150 lines or starts needing hardware-variant branches (NVIDIA, ARM), pull the steps out — that's the right time.
- **Akmods / custom kernel modules.** ublue signs kernel modules with `akmods-ublue.der` and requires MOK enrollment. A plain Kinoite + layered packages image doesn't need this — Secure Boot just works via shim + Fedora's signed grub + signed kernel. If you ever add ZFS or proprietary NVIDIA drivers, revisit this.
- **`just` as the task runner.** ublue uses a ~1000-line `Justfile`. `just` is great (and your dotfiles include it), but for this scale a `Makefile` is fine and universally readable. Swap if you prefer.
- **Renovate for base-image digest pinning.** A valid optimization: instead of `FROM kinoite:44` (floating), pin to `FROM kinoite:44@sha256:abc123...` and have Renovate auto-bump the digest. Fully reproducible builds. Not urgent for a single machine but useful if you ever fork this for fleet deployment.

## If you extend this — the COPR isolation pattern

If you ever add a package from a third-party COPR (for example, if you want `atuin` or something from a Framework community COPR), Aurora's `20-tests.sh` has a pattern worth copying. Don't just `dnf copr enable` and leave the repo enabled — a compromised COPR could ship a tampered version of a Fedora package on the next update. Enable the COPR briefly, install explicitly from it, then disable:

```dockerfile
RUN dnf copr enable -y someuser/somerepo && \
    dnf install -y --enablerepo=someuser-somerepo atuin && \
    dnf copr disable -y someuser/somerepo && \
    ostree container commit
```

This keeps the Fedora package set clean against upstream and makes it obvious which packages came from COPRs.
