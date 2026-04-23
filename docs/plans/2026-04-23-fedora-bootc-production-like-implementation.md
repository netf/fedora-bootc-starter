# Fedora Bootc Production-Like Install Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rework this repo so the shipped installer and CI validate a production-like Fedora Kinoite deployment with install-time `LUKS2` root, first-boot TPM2 enrollment, recovery-key setup, installer-key removal, and second-boot unattended TPM2 auto-unlock.

**Architecture:** Replace the current split between a real encrypted installer config and a weaker CI config with a single rendered installer template. Split bootstrap into automatic `core` and explicit `hardware` profiles, then update CI to boot the encrypted VM twice: first with a one-time serial-console unlock, then a second time with no unlock injection to prove TPM2-backed auto-unlock.

**Tech Stack:** bootc, bootc-image-builder, Fedora Kinoite, systemd, dracut, LUKS2, TPM2, QEMU, swtpm, GitHub Actions, shell tests, hadolint, shellcheck, yamllint

---

### Task 1: Introduce A Rendered Installer Template

**Files:**
- Create: `config.toml.in`
- Create: `scripts/render-installer-config.sh`
- Modify: `config.toml`
- Modify: `tests/test-installer-configs.sh`
- Test: `tests/test-installer-configs.sh`

**Step 1: Write the failing test**

Add assertions in `tests/test-installer-configs.sh` that:

- `config.toml.in` exists and parses after placeholder substitution
- the repo no longer requires a tracked literal `--passphrase=installer-temp-change-me`
- `scripts/render-installer-config.sh` exists
- the rendered output contains encrypted-root kickstart content

Example assertions:

```bash
assert_file_contains "$REPO_ROOT/config.toml.in" "{{INSTALL_LUKS_PASSPHRASE}}"
assert_file_not_contains "$REPO_ROOT/config.toml.in" "installer-temp-change-me"
assert_file_contains "$REPO_ROOT/scripts/render-installer-config.sh" "INSTALL_LUKS_PASSPHRASE"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-installer-configs.sh`
Expected: FAIL because `config.toml.in` and `scripts/render-installer-config.sh` do not exist yet.

**Step 3: Write minimal implementation**

Create `config.toml.in` as the authoritative template with placeholders:

```toml
[customizations.installer.kickstart]
contents = """
...
part / --grow --fstype=btrfs --encrypted --luks-version=luks2 --pbkdf=argon2id --passphrase={{INSTALL_LUKS_PASSPHRASE}}
...
{{EXTRA_USER_BLOCKS}}
"""

[customizations.kernel]
append = "{{EXTRA_KERNEL_APPEND}}"
```

Create `scripts/render-installer-config.sh` to require env vars and render the template:

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${INSTALL_LUKS_PASSPHRASE:?}"
: "${ADMIN_PASSWORD_HASH:?}"
```

Keep `config.toml` only as a local/generated artifact or remove it from the authoritative role.

**Step 4: Run test to verify it passes**

Run: `bash tests/test-installer-configs.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add config.toml.in scripts/render-installer-config.sh tests/test-installer-configs.sh
git commit -m "feat: add rendered installer config template"
```

### Task 2: Split Bootstrap Into Core And Hardware Profiles

**Files:**
- Create: `bootstrap/core/`
- Create: `bootstrap/hardware/`
- Create: `bootstrap/run-profile.sh`
- Modify: `bootstrap/run-all.sh`
- Modify: `files/usr/lib/systemd/system/netf-bootstrap.service`
- Modify: `tests/test-bootstrap-scaffold.sh`
- Test: `tests/test-bootstrap-scaffold.sh`

**Step 1: Write the failing test**

Add assertions that:

- the first-boot service runs `run-profile.sh core`
- `run-all.sh` is no longer the first-boot entrypoint
- core scripts and hardware scripts live in separate profile directories or are selected by profile-aware logic

Example assertions:

```bash
assert_file_contains "$service" "ExecStart=/usr/share/bootstrap/run-profile.sh core"
assert_file_contains "$runner" "case \"$PROFILE\" in"
assert_file_contains "$runner" "core)"
assert_file_contains "$runner" "hardware)"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-bootstrap-scaffold.sh`
Expected: FAIL because the current service still runs `run-all.sh --interactive`.

**Step 3: Write minimal implementation**

Create `bootstrap/run-profile.sh`:

```bash
PROFILE="${1:?profile required}"
case "$PROFILE" in
  core) mapfile -t STEPS < <(find /usr/share/bootstrap/core -name '[0-9]*.sh' | sort) ;;
  hardware) mapfile -t STEPS < <(find /usr/share/bootstrap/hardware -name '[0-9]*.sh' | sort) ;;
  *) err "unknown profile: $PROFILE" ;;
esac
```

Update the systemd unit:

```ini
[Service]
Type=oneshot
ExecStart=/usr/share/bootstrap/run-profile.sh core
```

Keep `run-all.sh` as an explicit convenience wrapper that runs `core` then `hardware`, but not as the automatic boot path.

**Step 4: Run test to verify it passes**

Run: `bash tests/test-bootstrap-scaffold.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add bootstrap/run-profile.sh bootstrap/run-all.sh files/usr/lib/systemd/system/netf-bootstrap.service tests/test-bootstrap-scaffold.sh
git commit -m "refactor: split bootstrap into core and hardware profiles"
```

### Task 3: Make Installer-Key Removal Depend On TPM2 And Recovery Only

**Files:**
- Modify: `bootstrap/13-luks-wipe-installer.sh`
- Modify: `bootstrap/10-luks-tpm2.sh`
- Modify: `tests/test-bootstrap-scaffold.sh`
- Test: `tests/test-bootstrap-scaffold.sh`

**Step 1: Write the failing test**

Change the scaffold test so `13-luks-wipe-installer.sh` must:

- require `systemd-tpm2`
- require `systemd-recovery`
- not require `systemd-fido2`

Example assertion:

```bash
assert_file_not_contains "$path" 'grep -q "systemd-fido2"'
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-bootstrap-scaffold.sh`
Expected: FAIL because the current script still refuses to proceed without FIDO2.

**Step 3: Write minimal implementation**

Adjust the gate:

```bash
grep -q "systemd-tpm2" <<<"$DUMP" || err "Refusing: TPM2 not enrolled"
grep -q "systemd-recovery" <<<"$DUMP" || err "Refusing: recovery key not enrolled"
```

If needed, update `10-luks-tpm2.sh` to mark when initramfs/crypttab changed so later tasks can rebuild boot artifacts deterministically.

**Step 4: Run test to verify it passes**

Run: `bash tests/test-bootstrap-scaffold.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add bootstrap/10-luks-tpm2.sh bootstrap/13-luks-wipe-installer.sh tests/test-bootstrap-scaffold.sh
git commit -m "fix: require only tpm2 and recovery before wiping installer key"
```

### Task 4: Make Core Bootstrap Regenerate Boot Artifacts And Signal Reboot

**Files:**
- Modify: `bootstrap/lib/common.sh`
- Modify: `bootstrap/run-profile.sh`
- Modify: `bootstrap/core/10-luks-tpm2.sh`
- Modify: `bootstrap/core/13-luks-wipe-installer.sh`
- Modify: `tests/test-bootstrap-scaffold.sh`
- Test: `tests/test-bootstrap-scaffold.sh`

**Step 1: Write the failing test**

Add assertions that the core runner:

- tracks whether boot-critical state changed
- regenerates initramfs when needed
- leaves a reboot marker or explicit reboot-required signal

Example assertions:

```bash
assert_file_contains "$runner" "BOOT_ARTIFACTS_DIRTY=0"
assert_file_contains "$runner" "dracut"
assert_file_contains "$runner" "reboot required"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-bootstrap-scaffold.sh`
Expected: FAIL because the current runner does not rebuild initramfs or signal reboot as part of the profile flow.

**Step 3: Write minimal implementation**

Add helper functions:

```bash
boot_artifacts_dirty() { [[ -f /var/lib/bootstrap/.boot-artifacts-dirty ]]; }
mark_boot_artifacts_dirty() { touch /var/lib/bootstrap/.boot-artifacts-dirty; }
```

In the runner:

```bash
if boot_artifacts_dirty; then
  kver=$(ls /usr/lib/modules | sort -V | tail -1)
  env DRACUT_NO_XATTR=1 dracut -vf "/usr/lib/modules/$kver/initramfs.img" "$kver"
  touch /var/lib/bootstrap/.reboot-required
fi
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test-bootstrap-scaffold.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add bootstrap/lib/common.sh bootstrap/run-profile.sh bootstrap/core/10-luks-tpm2.sh bootstrap/core/13-luks-wipe-installer.sh tests/test-bootstrap-scaffold.sh
git commit -m "feat: rebuild initramfs after core luks changes"
```

### Task 5: Update The Image Layout For Profile-Aware Bootstrap

**Files:**
- Modify: `Containerfile`
- Modify: `Makefile`
- Modify: `tests/test-build-files.sh`
- Modify: `tests/test-runtime-scripts.sh`
- Test: `tests/test-build-files.sh`
- Test: `tests/test-runtime-scripts.sh`

**Step 1: Write the failing test**

Update build/runtime tests to assert:

- `Containerfile` copies the new profile-aware bootstrap layout
- the image still ships both core and hardware scripts
- the first-boot unit is enabled, but now runs the core profile

Example assertions:

```bash
assert_file_contains "$path" "COPY bootstrap/ /usr/share/bootstrap/"
assert_file_contains "$path" "run-profile.sh"
assert_file_contains "$path" "systemctl enable netf-bootstrap.service"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-build-files.sh`
Run: `bash tests/test-runtime-scripts.sh`
Expected: FAIL because the tests still expect the old flat bootstrap contract.

**Step 3: Write minimal implementation**

Adjust the `Containerfile` smoke-test block and `Makefile inspect` block so they assert the new profile-aware paths instead of the old automatic-all-scripts behavior.

**Step 4: Run test to verify it passes**

Run: `bash tests/test-build-files.sh`
Run: `bash tests/test-runtime-scripts.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Containerfile Makefile tests/test-build-files.sh tests/test-runtime-scripts.sh
git commit -m "refactor: align image smoke tests with bootstrap profiles"
```

### Task 6: Replace The Weak CI Config With A Rendered Encrypted Install Path

**Files:**
- Modify: `.github/workflows/build.yml`
- Modify: `tests/test-ci-files.sh`
- Modify: `tests/test-installer-configs.sh`
- Test: `tests/test-ci-files.sh`
- Test: `tests/test-installer-configs.sh`

**Step 1: Write the failing test**

Add assertions that CI:

- renders the installer template instead of using a static `config-ci.toml`
- supplies `INSTALL_LUKS_PASSPHRASE`
- keeps `--type qcow2 --rootfs btrfs`
- no longer relies on a `no LUKS` config file

Example assertions:

```bash
assert_file_contains "$workflow" "scripts/render-installer-config.sh"
assert_file_contains "$workflow" "INSTALL_LUKS_PASSPHRASE"
assert_file_not_contains "$workflow" "config-ci.toml"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-ci-files.sh`
Run: `bash tests/test-installer-configs.sh`
Expected: FAIL because the current workflow still renders `config-ci.toml`.

**Step 3: Write minimal implementation**

Update the workflow to render the authoritative template:

```yaml
- name: Render installer config
  env:
    INSTALL_LUKS_PASSPHRASE: ${{ secrets.CI_INSTALL_LUKS_PASSPHRASE }}
    ADMIN_PASSWORD_HASH: ${{ secrets.CI_ADMIN_PASSWORD_HASH }}
    EXTRA_USER_BLOCKS: |
      [[customizations.user]]
      name = "netf"
      ...
    EXTRA_KERNEL_APPEND: "console=ttyS0,115200 rd.debug ..."
  run: ./scripts/render-installer-config.sh > config-ci-rendered.toml
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test-ci-files.sh`
Run: `bash tests/test-installer-configs.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add .github/workflows/build.yml tests/test-ci-files.sh tests/test-installer-configs.sh
git commit -m "ci: render encrypted installer config from template"
```

### Task 7: Teach E2E VM To Unlock The First Boot Over Serial

**Files:**
- Modify: `.github/workflows/build.yml`
- Modify: `tests/test-ci-files.sh`
- Test: `tests/test-ci-files.sh`

**Step 1: Write the failing test**

Add assertions that the workflow:

- uses a console channel that can be written to, not just tailed
- detects the LUKS prompt
- injects the temporary installer passphrase once

Example assertions:

```bash
assert_file_contains "$workflow" "mkfifo vm-serial.in"
assert_file_contains "$workflow" "grep -i 'Passphrase'"
assert_file_contains "$workflow" "printf '%s\\n' \"$INSTALL_LUKS_PASSPHRASE\""
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-ci-files.sh`
Expected: FAIL because the current workflow only logs serial output to a file and never injects input.

**Step 3: Write minimal implementation**

Switch the QEMU serial plumbing to something CI can both read and write, for example a named pipe or socket-backed serial device. Add a step that watches for the first LUKS prompt and sends the passphrase once.

**Step 4: Run test to verify it passes**

Run: `bash tests/test-ci-files.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add .github/workflows/build.yml tests/test-ci-files.sh
git commit -m "ci: unlock first encrypted boot over serial console"
```

### Task 8: Prove Second-Boot TPM2 Auto-Unlock

**Files:**
- Modify: `.github/workflows/build.yml`
- Modify: `tests/test-ci-files.sh`
- Test: `tests/test-ci-files.sh`

**Step 1: Write the failing test**

Add assertions that the workflow:

- verifies TPM2 and recovery enrollment after first boot
- verifies the installer slot is gone
- reboots the VM
- does not inject a passphrase on the second boot
- waits for SSH on the second boot

Example assertions:

```bash
assert_file_contains "$workflow" "cryptsetup luksDump"
assert_file_contains "$workflow" "systemd-tpm2"
assert_file_contains "$workflow" "systemd-recovery"
assert_file_contains "$workflow" "second boot"
assert_file_contains "$workflow" "no passphrase injection"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-ci-files.sh`
Expected: FAIL because the current VM job only performs one boot and never proves unattended second boot.

**Step 3: Write minimal implementation**

In `e2e-vm`, add:

- first-boot post-SSH validation:

```bash
$ROOT_SSH 'cryptsetup luksDump $(findmnt -no SOURCE / | xargs cryptsetup status | awk "/device:/ {print \$2}")'
```

- reboot:

```bash
$ROOT_SSH 'systemctl reboot'
```

- second-boot wait logic with no unlock injection

Pass only when SSH returns on the second boot with the same `swtpm` state and no manual LUKS entry.

**Step 4: Run test to verify it passes**

Run: `bash tests/test-ci-files.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add .github/workflows/build.yml tests/test-ci-files.sh
git commit -m "ci: prove second-boot tpm2 auto-unlock"
```

### Task 9: Update Container Smoke Tests For The New Contract

**Files:**
- Modify: `.github/workflows/build.yml`
- Modify: `tests/test-build-files.sh`
- Modify: `tests/test-runtime-scripts.sh`
- Test: `bash tests/test-build-files.sh`
- Test: `bash tests/test-runtime-scripts.sh`

**Step 1: Write the failing test**

Update static tests so they expect:

- no mandatory automatic FIDO2/fingerprint/Framework enrollment in the core boot path
- presence of both core and hardware scripts in the image
- initramfs includes `ostree`, `cryptsetup`, and `tpm2`

**Step 2: Run test to verify it fails**

Run: `bash tests/test-build-files.sh`
Run: `bash tests/test-runtime-scripts.sh`
Expected: FAIL because the tests still reflect the old "run everything" contract.

**Step 3: Write minimal implementation**

Update the build smoke test block in `.github/workflows/build.yml` and the local static tests to reflect the new profile-aware contract.

**Step 4: Run test to verify it passes**

Run: `bash tests/test-build-files.sh`
Run: `bash tests/test-runtime-scripts.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add .github/workflows/build.yml tests/test-build-files.sh tests/test-runtime-scripts.sh
git commit -m "test: update smoke assertions for production-like install contract"
```

### Task 10: Rewrite README And Supporting Docs To Match The New Contract

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md`
- Modify: `docs/superpowers/plans/2026-04-23-fedora-bootc-starter-implementation.md`
- Create: `docs/plans/2026-04-23-fedora-bootc-production-like-design.md` (already present)
- Test: `tests/test-docs.sh`

**Step 1: Write the failing test**

Update `tests/test-docs.sh` so the docs must describe:

- install-time encrypted root
- one-time first-boot passphrase entry
- automatic core bootstrap only
- explicit hardware post-install profile
- second-boot TPM2 auto-unlock proof in CI

**Step 2: Run test to verify it fails**

Run: `bash tests/test-docs.sh`
Expected: FAIL because the README still says first boot runs firmware, TPM2, FIDO2, fingerprint, and EC tuning as one automatic path.

**Step 3: Write minimal implementation**

Rewrite the user-facing docs to match the approved design. Remove statements that imply:

- a tracked literal installer passphrase is normal
- FIDO2/fingerprint/Framework EC are part of the automatic reproducible core
- CI only proves a non-LUKS smoke path

**Step 4: Run test to verify it passes**

Run: `bash tests/test-docs.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add README.md docs/superpowers/specs/2026-04-23-fedora-bootc-starter-design.md docs/superpowers/plans/2026-04-23-fedora-bootc-starter-implementation.md tests/test-docs.sh
git commit -m "docs: align repository docs with production-like install design"
```

### Task 11: Run The Full Static Validation Sweep

**Files:**
- Modify: none unless fixes are needed
- Test: `tests/test-bootstrap-scaffold.sh`
- Test: `tests/test-installer-configs.sh`
- Test: `tests/test-build-files.sh`
- Test: `tests/test-runtime-scripts.sh`
- Test: `tests/test-ci-files.sh`
- Test: `tests/test-docs.sh`

**Step 1: Run the static test suite**

Run:

```bash
bash tests/test-bootstrap-scaffold.sh
bash tests/test-installer-configs.sh
bash tests/test-build-files.sh
bash tests/test-runtime-scripts.sh
bash tests/test-ci-files.sh
bash tests/test-docs.sh
```

Expected: all PASS

**Step 2: Run linting**

Run:

```bash
shellcheck -x bootstrap/**/*.sh bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh tests/*.sh
yamllint .github/workflows/
bash -n bootstrap/**/*.sh bootstrap/*.sh bootstrap/lib/*.sh scripts/*.sh tests/*.sh
```

Expected: clean output

**Step 3: Commit any final fixups**

```bash
git add .
git commit -m "chore: finalize production-like install refactor"
```

