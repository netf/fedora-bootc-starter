# Fedora Bootc Production-Like Install Design

## Goal

Redesign this repo so the shipped image and CI validate a production-like Fedora Kinoite deployment: encrypted `LUKS2` root on `btrfs`, first-boot TPM2 enrollment, recovery-key setup, installer-key removal, and a second unattended boot proving TPM2-backed auto-unlock works.

## Core Decisions

- Keep `LUKS2` root creation in the installer, not in the container build and not in a post-install migration flow.
- Move `TPM2` enrollment and recovery-key setup into the automatic first-boot core bootstrap path.
- Move `YubiKey/FIDO2`, fingerprint, and Framework-specific EC tuning into explicit post-install hardware profiles.
- Replace the current CI-only non-LUKS install path with the same encrypted-root semantics used for real installs.
- Use the best artifact-discipline patterns from Aurora, but not Aurora's validation boundary. This repo must validate an installed encrypted system, not just a signed container artifact.

## Why Not "Encrypt Later"

Root-disk encryption is part of the install shape. If encryption is deferred to post-install, the system either boots once unencrypted or requires an in-place conversion/migration path that is harder to reason about, harder to test, and less representative of the final deployment. The installer should create the encrypted root. Post-install should only add unlock methods and remove the temporary installer secret after success criteria are met.

## Build Model

The image build remains container-native.

- Keep a single authoritative `Containerfile`.
- Keep an online build phase for package installs, downloads, and upstream key material.
- Keep an offline finalization phase for image-owned config, initramfs regeneration, bootc metadata, smoke tests, and `bootc container lint`.
- Add Aurora-style discipline where it is useful:
  - pin upstream image digests in a lock file
  - verify upstream signed images before composing
  - sign the pushed image digest
  - attach and sign an SBOM
  - emit CI attestation/provenance

Do not copy Aurora's flavor matrix or rechunk complexity unless this repo actually needs multiple shipped variants or ostree-OCI post-processing beyond plain bootc images.

## Installer Model

The installer config becomes a rendered template instead of a tracked file with a literal throwaway secret.

### Authoritative Template

Create a single authoritative installer template, recommended as `config.toml.in`, with placeholders for:

- `{{INSTALL_LUKS_PASSPHRASE}}`
- `{{ADMIN_PASSWORD_HASH}}`
- `{{EXTRA_USER_BLOCKS}}`
- `{{EXTRA_KERNEL_APPEND}}`

The rendered output is what `bootc-image-builder` consumes.

### Real Install Semantics

The real install path must keep:

- unattended bootc install
- `LUKS2`
- `btrfs`
- locked root account unless explicitly overridden
- no CI-only weakening of storage/security semantics

### Allowed CI-Only Deltas

CI may add:

- injected SSH keys for `netf` and `root`
- serial/debug kernel arguments
- VM-only host identity values

CI may not remove root encryption just to make the VM easier to boot.

## Bootstrap Model

Split bootstrap into profiles.

### Core Profile

Runs automatically on first boot and is part of the reproducible contract:

- `00-sanity.sh`
- `05-firmware-update.sh`
- `10-luks-tpm2.sh`
- `12-luks-recovery.sh`
- `13-luks-wipe-installer.sh`

Core responsibilities:

- generic sanity checks
- generic firmware refresh logic that safely skips in VM
- TPM2 enrollment
- recovery-key enrollment
- installer passphrase removal
- any generic kargs/sysctl/zram/service enablement that is safe and non-interactive

### Hardware Profile

Installed in the image but only run explicitly:

- `11-luks-fido2.sh`
- `30-fingerprint-enroll.sh`
- `40-framework-ec.sh`

Hardware responsibilities:

- YubiKey/FIDO2 enrollment
- fingerprint enrollment
- Framework battery/EC tuning
- any user-presence or secret-bearing flow tied to actual hardware

## First-Boot Contract

The systemd first-boot unit should stop being "run everything interactively". It should become an automatic core convergence service.

The service contract:

- runs once on first boot
- executes the core profile only
- remains idempotent via per-step markers
- updates initramfs and `crypttab` when TPM2 enrollment changes boot-time unlock behavior
- ends in a state that requires or strongly requests reboot

The automatic service must not attempt:

- YubiKey/FIDO2 enrollment
- fingerprint enrollment
- Framework-only EC customization

## Temporary Installer Passphrase Handling

Use a templated model.

- The initial LUKS passphrase is injected at render/build time.
- It is not committed to git.
- Local production builds must supply it explicitly.
- CI must supply it from workflow secrets/variables for the first encrypted boot.
- The core bootstrap wipes it after `TPM2 + recovery` are in place.

Because `FIDO2` is no longer part of the mandatory core path, installer-key removal should require:

- `systemd-tpm2`
- `systemd-recovery`

and should no longer require:

- `systemd-fido2`

## E2E VM Model

There should be one authoritative `e2e-vm` job instead of a fast non-LUKS smoke VM plus a separate "real" path.

### Flow

1. Render the authoritative installer template with:
   - the temporary LUKS passphrase
   - CI SSH keys
   - serial/debug kernel args
2. Build a qcow2 from the rendered config using `bootc-image-builder`.
3. Boot the VM with QEMU, UEFI, and persistent `swtpm`.
4. Detect the first LUKS prompt on the serial console.
5. Inject the temporary installer passphrase exactly once.
6. Wait for userspace and SSH.
7. Verify the core bootstrap converged:
   - TPM2 token exists
   - recovery token exists
   - installer keyslot is gone
8. Reboot the same VM with the same TPM state.
9. Do not inject a passphrase on the second boot.
10. Pass only if the system reaches SSH unaided.

### Why This Proof Matters

This proves the actual deployment contract:

- encryption is created at install time
- TPM2 enrollment is performed post-install
- the system can reboot and auto-unlock from TPM2 without manual intervention

Anything weaker only proves that scripts can run, not that the installed machine works.

## What To Reuse From Aurora

Aurora is a good reference for artifact discipline, not for production-faithful install validation.

### Valid Patterns To Reuse

- pinned upstream digests
- upstream signature verification before compose
- explicit online vs offline image-finalization stages
- in-image smoke tests
- `bootc container lint`
- initramfs checks
- output signing
- SBOM attach/sign
- CI provenance/attestation

### Patterns Not To Reuse

- no installer/VM validation in CI
- no encrypted-root boot proof in CI
- no "CI-mode no LUKS" config split
- no matrix/flavor complexity unless justified by actual shipped variants

## Mapping The Framework Guide

The long Framework 13 guide should be split into three categories.

### Manual Preflight / Operator Guide

Keep in documentation only:

- firmware updates
- BIOS settings
- Secure Boot and TPM prerequisites
- install-media verification
- expansion-card/wake policies
- suspend diagnostics

### Automatic Core Baseline

Safe, reproducible, and part of CI:

- encrypted-root install
- TPM2 enrollment
- recovery-key setup
- installer-key removal
- generic power/security defaults that are non-interactive and hardware-agnostic

### Explicit Post-Install Personalization

Valid for this project, but not mandatory for the reproducible core:

- YubiKey/FIDO2 enrollment
- fingerprint enrollment
- Framework EC charge-limit tuning
- custom Secure Boot owner-key workflows
- `usbguard` allowlist generation
- `dnscrypt-proxy`
- aggressive Flatpak lockdown

## Repo Shape

Target structure:

- `Containerfile`
- `image-versions.yml` or equivalent upstream digest lock file
- `config.toml.in`
- `bootstrap/core/`
- `bootstrap/hardware/`
- `bootstrap/lib/`
- `bootstrap/run-profile.sh`
- `tests/` split between static image/build tests and VM contract tests

The first-boot unit should execute the core profile. Hardware scripts remain installed and callable manually.

## Success Criteria

This redesign is complete when:

- no literal installer LUKS passphrase is tracked in git
- the rendered installer config is the single source of truth for both local installer builds and CI
- the automatic first-boot service runs only the core profile
- the hardware scripts are explicit opt-in post-install actions
- CI builds an encrypted-root VM image
- CI injects the installer passphrase only for the first boot
- CI proves TPM2-backed unattended second boot
- image build retains signing, linting, and smoke-test discipline inspired by Aurora
