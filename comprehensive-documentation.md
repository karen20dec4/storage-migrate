# Comprehensive Documentation

**Current versions:** `storage-migrate.sh` v2.11, `storage-post-migration.sh` v2.4 (2026-07-04).

## 1. Project Purpose

This repository contains a Debian-focused storage migration toolkit implemented as Bash scripts. It is designed to help move a system from one disk to another, either by copying a root filesystem and installing GRUB on a new disk, by moving LVM Physical Volume data with `pvmove`, or by combining both operations for a full-disk migration.

The project is intentionally small:

- `storage-migrate.sh`: the main migration script.
- `storage-post-migration.sh`: a post-migration repair, cleanup, and audit helper.
- `AGENTS.md`: contributor guidance.
- `comprehensive-documentation.md`: this technical explanation and audit summary.

These scripts perform destructive operations such as wiping signatures, writing partition tables, formatting filesystems, and modifying boot configuration. They should be tested in a VM or disposable environment before being used on real hardware.

## 2. High-Level Architecture

The application is not a long-running service. It is a command-line automation workflow made of Bash functions, global state variables, and imperative execution steps.

`storage-migrate.sh` owns the primary workflow:

1. Parse CLI arguments.
2. Detect boot mode, root device, source disk, and target disk.
3. Detect migration type from source disk contents.
4. Generate and optionally display a dry-run command plan.
5. Confirm destructive actions.
6. Execute one of the migration workflows.
7. Save metadata, logs, backups, and recovery commands.

`storage-post-migration.sh` owns repair and validation after a migration:

1. Normalize `/etc/fstab` CD-ROM and swap entries.
2. Update initramfs resume configuration.
3. Remove stale `resume=` kernel parameters from GRUB defaults.
4. Optionally extend mounted LVM volumes that have free space.
5. Rebuild initramfs and GRUB.
6. Optionally run a postboot audit.

## 3. Main Script: `storage-migrate.sh`

### Runtime Safety Model

The script uses:

```bash
set -euo pipefail
IFS=$'\n\t'
```

This catches unset variables, failed commands, and pipeline errors. Most risky commands are routed through `log_command` or `log_interactive_command`, which record the command and exit code in `/var/log/storage-migrate.log`.

Important global paths:

- `LOG_FILE=/var/log/storage-migrate.log`
- `BACKUP_DIR=/root/storage-migrate-backups`
- `RESUME_FILE=/root/storage-migrate-backups/lvm-resume.sh`
- `METADATA_FILE=/root/storage-migrate-backups/migration-metadata.json`
- `FSTAB_VALIDATE_LOG=/root/storage-migrate-backups/fstab-validate.log`

If `/var/log` is not writable, logging falls back to `/tmp/storage-migrate.log`.

### Supported Modes

Interactive mode:

```bash
sudo ./storage-migrate.sh
```

Pre-validation mode:

```bash
sudo ./storage-migrate.sh --check
```

Resume a failed LVM move:

```bash
sudo ./storage-migrate.sh --resume
```

Non-interactive mode:

```bash
sudo ./storage-migrate.sh \
  --source /dev/sda \
  --target /dev/nvme0n1 \
  --root-size 40 \
  --boot-mode UEFI \
  --yes
```

`--yes` is deliberately separate from `--source` and `--target` because the target disk is erased.

### Migration Type Detection

The script scans partitions on the selected source disk with `lsblk`, `findmnt`, `swapon`, and LVM commands. It classifies the operation as:

- `root-only`: source disk contains a mounted root filesystem but no LVM PV.
- `lvm-only`: source disk contains LVM PVs but no directly mounted root filesystem.
- `full-disk`: source disk contains both a directly mounted root filesystem and LVM PVs.
- `empty`: no usable root or LVM content detected.

The detection result controls the execution path.

### LVM-Only Workflow

For `lvm-only`, the script:

1. Wipes old signatures on the target disk.
2. Creates a GPT partition table.
3. Creates one full-disk LVM partition.
4. Runs `pvcreate`.
5. Runs `vgextend` for each detected source PV.
6. Saves a resumable `pvmove` command to `lvm-resume.sh`.
7. Runs `pvmove -i 5 <source_pv> <target_pv>`.
8. Removes the old PV from the VG with `vgreduce`.

If `pvmove` fails, the resume file remains available.

### Root / Full-Disk Workflow

For `root-only` and `full-disk`, the script:

1. Computes partition sizes in MiB.
2. Validates that boot, root, and swap partitions fit before destructive writes.
3. Wipes target signatures and creates a GPT table.
4. Creates either:
   - UEFI layout: ESP, root, swap, optional LVM partition.
   - BIOS layout: BIOS boot partition, root, swap, optional LVM partition.
5. Runs `partprobe` and waits for device nodes.
6. Formats root, swap, and ESP where applicable.
7. Mounts the new root at `/mnt/newroot`.
8. Runs `rsync -aAXH --delete` from `/` to the new root **in two passes** — a long bulk pass, then a fast delta pass that captures files changed on the live system during the first pass (shrinks the inconsistency window from hours to seconds). Both passes exclude pseudo-filesystems and **every separately-mounted block-device filesystem** (e.g. `/home`, `/data`, `/boot/efi`). Their data stays on its own partition/disk; only the empty mountpoint directory is recreated and `fstab` remounts it after boot.
9. Bind-mounts `/dev`, `/proc`, `/sys`, `/run`, and optionally `/dev/pts`.
10. Copies and sanitizes `/etc/default/grub`.
11. Installs GRUB in UEFI or BIOS mode.
12. Writes target swap resume configuration.
13. Runs `update-grub` and `update-initramfs`.
14. Rewrites target `/etc/fstab` using UUIDs.
15. Validates the generated fstab in a chroot with `mount -fav -T`.
16. Runs a **boot sanity check** while the target is still mounted: kernel (`vmlinuz-*`) and initrd present in the target `/boot`, `grub.cfg` references the new root UUID, and the bootloader is really installed (EFI binary on the ESP for UEFI, GRUB signature in the MBR for BIOS). A failure aborts the migration with an explicit "do not swap the disk yet" message.
17. Optionally runs `e2fsck`.
18. Cleans temporary mounts.

For `full-disk`, it also creates a target LVM PV and moves data from source PVs after the root copy.

## 4. Post-Migration Script: `storage-post-migration.sh`

Typical run:

```bash
sudo ./storage-post-migration.sh --summary
```

Verbose run:

```bash
sudo ./storage-post-migration.sh --postboot --verbose
```

Useful options:

- `--root <path>`: operate on a mounted target root instead of `/`.
- `--preboot`: default mode, suitable before first boot.
- `--postboot`: adds live-system audit checks.
- `--fix-resume auto|disable|uuid=<uuid>`: control initramfs resume behavior.
- `--fix-cdrom keep|comment|nofail`: control stale CD-ROM fstab entries.
- `--quiet-boot yes|no|keep`: manage quiet boot settings.
- `--extend-lvm auto|ask|no`: optionally extend LVM volumes.
- `--verbose|--summary|--quiet`: control console output.

The script logs to:

```text
/root/storage-migrate-backups/post-migration.log
```

When `--root` is used, the log path is resolved inside that root.

Option values are validated immediately after parsing, interactive prompts read from
`/dev/tty` (defaulting to "no" when no terminal is available), and the final summary
table is emitted through an `EXIT` trap, so it also appears when the script dies
mid-run.

## 5. Audit Findings and Repairs Applied

The audit identified and repaired the following concrete issues:

1. Missing CLI values could be misread as the next option.
   - Fixed in both scripts by validating required argument values.

2. Current root disk detection was too narrow.
   - Added `CURRENT_ROOT_DISKS`, parent-disk resolution, and LVM-backed root detection so the target disk cannot be a current root disk.

3. Root partition capacity validation happened after destructive disk operations.
   - Moved boot/root/swap size validation before `wipefs` and `parted`.

4. Several `parted` operations were not checked.
   - Added explicit failure handling to partition creation and critical flag-setting commands.

5. `partprobe` failures were not fatal.
   - Made `partprobe` failure stop both LVM-only and root/full-disk flows.

6. `rsync` exit-code handling was wrong because `if ! command; then rc=$?` captures the inverted status.
   - Rewrote the block so exit code `24` remains specially tolerated and other failures stop the migration.

7. `/dev/pts` bind mount passed `2>/dev/null` as a literal command argument.
   - Removed the accidental argument and kept the mount optional.

8. CD-ROM comment mode in post-migration did not reliably comment the fstab line.
   - Replaced the fragile `sed` expression with an `awk` rewrite that prefixes the line.

9. LVM free-space display could parse values like `10.00g` as `0`.
   - Stripped the unit suffix before numeric formatting.

10. Tab indentation was removed from scripts after patching.
    - This improves readability and keeps style closer to the contributor guide.

### Second audit (2026-06-30)

A follow-up review (validated with `bash -n` and ShellCheck 0.10) found and fixed:

1. **`log_error` was fatally broken (`storage-post-migration.sh`).** It used
   `${_red "ERROR:"}` (parameter-expansion braces) instead of `$(_red "ERROR:")`
   (command substitution). Under `set -euo pipefail` this raises a *bad substitution*
   error, so the error-reporting function itself aborted the script and the real
   message was lost — exactly when something had already gone wrong. Now uses `$(...)`.

2. **rsync copied every separately-mounted filesystem, not just `/home`
   (`storage-migrate.sh`).** Because `rsync -aAXH` runs without `-x`, any extra mount
   under `/` (e.g. a separate `/data` disk) was descended into and copied into the new
   root, risking a bloated or overflowing target. Replaced the `/home`-only special case
   with a loop that excludes **all** block-device mountpoints under `/` (detected via
   `findmnt -rno TARGET,SOURCE`). Applied identically to the dry-run preview so the
   plan matches the real run.

3. **VG de-duplication failed with 2+ VGs (`storage-migrate.sh`).** Because the global
   `IFS=$'\n\t'`, `${found_vgs[*]}` joined with a newline, so the space-delimited
   membership test never matched and VG names could be listed more than once. The test
   now joins with `IFS=' '` in a subshell (cosmetic, but correct).

4. **Minor hardening:** quoted `${2-}` in `storage-post-migration.sh` argument parsing
   (consistency with the main script) and quoted two unquoted summary `echo $(…)` lines.

### Third audit (2026-07-04) — v2.10/v2.3, then v2.11/v2.4

A full re-audit (validated with `bash -n`, ShellCheck, and safe smoke tests) fixed the
following, released as `storage-migrate.sh` v2.10 and `storage-post-migration.sh` v2.3:

1. **Target-disk in-use guard (`storage-migrate.sh`, A1).** `wipefs -a` on a whole disk
   can succeed even while its partitions are mounted, destroying the partition table of
   a disk still in use. A new `target_disk_in_use()` check now rejects a target whose
   partitions are mounted, are active LVM PVs, or are active swap — on both the
   interactive and the `--target` paths.

2. **Multi-VG source abort (A2).** A PV can belong to only one VG, so a source disk with
   PVs from two or more VGs would fail mid-migration at the second `vgextend`/`pvmove`
   (after the target was already wiped). The script now aborts explicitly before any
   destructive operation.

3. **Space check includes LVM (A3).** The fits-on-target estimate now sums used root
   space, used PV space, and swap. Previously an `lvm-only` migration to a smaller disk
   only produced a warning and failed hours later during `pvmove`.

4. **Phantom VG from empty array (A4).** `printf '%s\n'` with an empty array emitted one
   blank line, so `readarray` produced `DETECTED_VGS=("")`.

5. **JSON metadata (A5).** Empty arrays serialized as `[""]` instead of `[]`; a
   `json_string_array` helper fixed both `source_pvs` and `detected_vgs`.

6. **Disk selection filters `TYPE=disk` (A6).** CD-ROM/loop devices no longer appear as
   wipe candidates, and manually typed paths must be whole disks (not partitions).

7. **ESP copy uses `rsync -rt` (A7).** FAT32 has no owner/ACL/xattr support, so
   `-aAXH` produced errors that were masked by `|| true`.

8. **Cleanup on INT/TERM (A8).** Ctrl+C during rsync previously left `/mnt/newroot`
   with pseudo-filesystems bind-mounted; the cleanup trap now also covers INT and TERM.

9. **`_ask` reads from `/dev/tty` (`storage-post-migration.sh`, A1).** Inside
   `extend_lvm_volumes` the while-loop's stdin is the herestring with the VG list, so
   the confirmation `read` consumed the next line or got EOF — which defaulted to
   **"yes" and ran `lvextend` without consent**. Prompts now read from the terminal,
   and with no TTY the answer defaults to "no".

10. **CLI values validated upfront (A2).** A bad value (e.g. `--fix-cdrom foo`)
    previously killed the script mid-run via `set -e`, without the summary table.

11. **Locale-safe LVM parsing (A3).** `vgs` under a decimal-comma locale printed
    `5,00g`, breaking both the `--separator=','` split and `printf %.0f`; calls now run
    under `LC_ALL=C` and `vg_name` is trimmed of `--noheadings` indentation before
    being used in `--select`.

12. **dpkg repair in the target root (A4).** The `apt-get -f install` / `dpkg
    --configure -a` fallback now runs through `_chroot` instead of on the host when
    `--root` is used.

13. **`blacklist_floppy` creates `modprobe.d` if missing** (surfaced by the EXIT-trap
    smoke test against a minimal `--root`).

On top of the fixes, three improvements were added as v2.11 / v2.4:

- **Two-pass rsync with delta (I1, `storage-migrate.sh`).** See workflow step 8 above.
  `--delete` was added so the target mirrors the source; excluded paths stay protected.
- **Boot sanity check (I2, `storage-migrate.sh`).** See workflow step 16 above. Note
  this is a semantic change: a failed `update-grub` now aborts the migration instead of
  only warning.
- **Summary via EXIT trap (I12, `storage-post-migration.sh`).** The summary table now
  prints even when `set -e` or a signal kills the script mid-run — an interrupted step
  is marked `✖ INTRERUPT` and a non-zero exit code is reported.

## 6. Important Implementation Details

### Command Execution

`log_command` logs command strings and exit codes. It also supports a dry-run mode used by the plan display.

`log_interactive_command` streams output through `tee` while logging, useful for long-running commands such as `rsync` and `pvmove`.

### Device Naming

`get_part_name` handles device naming differences:

- `/dev/sda` + partition 1 -> `/dev/sda1`
- `/dev/nvme0n1` + partition 1 -> `/dev/nvme0n1p1`
- `/dev/mmcblk0` + partition 1 -> `/dev/mmcblk0p1`

### fstab Rewrite

The root migration flow writes a temporary target fstab and only replaces the real target fstab after validation succeeds. UUIDs are obtained with `blkid` for root, swap, and ESP.

In BIOS mode, `/boot/efi` entries are dropped from the generated fstab.

### Chroot Behavior

The migration script bind-mounts pseudo-filesystems before running GRUB and initramfs commands inside `/mnt/newroot`.

The post-migration script also bind-mounts `/dev`, `/proc`, `/sys`, and `/run` when rebuilding boot artifacts for a non-root target path.

## 7. Verification Performed

The following non-destructive checks were run:

```bash
bash -n storage-migrate.sh storage-post-migration.sh
shellcheck -x -S warning storage-migrate.sh storage-post-migration.sh
bash storage-migrate.sh --help
bash storage-post-migration.sh --help
bash storage-migrate.sh --source
bash storage-post-migration.sh --root --verbose
bash storage-post-migration.sh --fix-cdrom bogus     # CLI validation, exits 1
bash storage-post-migration.sh --root <empty-dir>    # EXIT-trap summary smoke test
```

Expected outcomes:

- Syntax check exits successfully.
- ShellCheck reports no findings beyond the intentional `TARGET_EXTRA` compatibility variable (SC2034).
- Help commands print usage and exit `0`.
- Missing-value and invalid-value commands exit `1` and print explicit errors.
- The post-migration summary table prints even when a step fails mid-run.

Destructive migration flows were not executed in this environment because they require real or virtual block devices and root-level disk operations.

## 8. Recommended External Verification

A second AI or human reviewer should inspect:

1. Bash syntax and quoting.
2. Behavior under `set -euo pipefail`.
3. Partition size calculations in both BIOS and UEFI modes.
4. Root-on-LVM detection on a real Debian VM.
5. fstab generation for:
   - root-only UEFI,
   - root-only BIOS,
   - full-disk UEFI,
   - full-disk BIOS.
6. `pvmove` resume behavior after an interrupted migration.
7. GRUB installation behavior with and without existing GRUB packages.
8. Post-migration behavior with `--root /mnt/newroot`.

Recommended VM test matrix:

```text
Debian 12 BIOS, ext4 root, no LVM
Debian 12 UEFI, ext4 root, no LVM
Debian 12 BIOS, root + separate LVM PV
Debian 12 UEFI, root + separate LVM PV
Debian 12 root-on-LVM, lvm-only migration path
```

## 9. Known Limitations

- The scripts are Debian-oriented and assume Debian package names and GRUB tooling.
- Root-on-LVM is treated primarily through the LVM migration path; boot partition edge cases still need VM validation.
- `storage-migrate.sh --check` validates planning and prerequisites but does not simulate every runtime chroot or GRUB condition.
- Network-dependent package installation inside chroot may fail if the target system has no network or broken APT configuration.
- Filesystems other than ext-family and xfs have limited automatic resize support in post-migration.

## 10. Operational Safety Checklist

Before a real migration:

1. Confirm complete backups exist.
2. Confirm source and target device names with `lsblk -f`.
3. Run `sudo ./storage-migrate.sh --check`.
4. Read the dry-run command list.
5. Confirm target disk contains no data that must be preserved.
6. Keep console access available for boot recovery.
7. Preserve the old disk until the new disk has booted and passed validation.

After migration:

1. Boot from the migrated disk.
2. Run `lsblk -f`, `df -h`, `findmnt /`, and `swapon --show`.
3. Run `sudo ./storage-post-migration.sh --postboot --summary`.
4. Inspect `/root/storage-migrate-backups/`.
5. Keep migration logs with any incident report or PR.
