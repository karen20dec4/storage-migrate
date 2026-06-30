# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A storage-migration toolkit split into **two independent toolchains that share no code**:

- **Linux/Debian (Bash)** — `storage-migrate.sh` + `storage-post-migration.sh`. Moves a system to a new disk via root-filesystem copy + GRUB install, LVM `pvmove`, or both.
- **Windows (PowerShell)** — `storage-migrate.ps1`. A standalone Windows Forms GUI tool (separate project, repo `karen20ced4/NVME-Migrate`) that migrates Windows with `robocopy`/`bcdboot` or does a raw disk clone. Editing it does not affect the Bash scripts and vice versa.

All three perform **destructive disk operations** (wipe signatures, write partition tables, format, modify boot config). Test in a VM / disposable environment, never on a workstation.

Two existing docs are authoritative and worth reading before non-trivial work:
- `AGENTS.md` — contributor guide (style, commands, PR expectations).
- `comprehensive-documentation.md` — deep technical walkthrough, workflow steps, audit history, and the recommended VM test matrix.

## Commands

```bash
# Syntax-check before any change (the minimum bar before submitting)
bash -n storage-migrate.sh storage-post-migration.sh

# Safe paths to exercise (no destructive writes)
bash storage-migrate.sh --help
bash storage-post-migration.sh --help
sudo ./storage-migrate.sh --check          # pre-validation / dry-run plan
sudo ./storage-migrate.sh --resume         # resume an interrupted LVM pvmove
sudo ./storage-post-migration.sh --summary

# Non-interactive migration (--yes is intentionally separate from --source/--target
# because the target disk is fully erased)
sudo ./storage-migrate.sh --source /dev/sda --target /dev/nvme0n1 --root-size 40 --yes

# Windows tool: run the .ps1 (GUI, auto-elevates to Administrator)
powershell -ExecutionPolicy Bypass -File storage-migrate.ps1
```

There is no build step, package manager, or automated test suite. Behavioral validation is manual, in a VM — see the test matrix in `comprehensive-documentation.md` §8.

## Architecture (Bash scripts)

`storage-migrate.sh` (~1660 lines) is the primary workflow. Flow:

1. `main()` parses CLI args (supporting both `--flag value` and `--flag=value` via `read_cli_value`), then orchestrates everything.
2. Disk/boot detection: `detect_current_root_disks` + `is_current_root_disk` prevent selecting a live root disk as the target; `get_parent_disk` resolves partitions/LVM to their backing disk.
3. **`detect_source_type`** classifies the source as `root-only`, `lvm-only`, `full-disk`, or `empty`. This classification drives which workflow runs.
4. `generate_migration_plan` / `show_dry_run*` print the planned commands.
5. Dispatch: **`migrate_lvm_pv`** (pvcreate → vgextend → `pvmove` with a resumable command saved to `RESUME_FILE`) or **`migrate_root_disk`** (the large core routine: partition sizing/validation *before* destructive writes, GPT layout for UEFI vs BIOS, `rsync -aAXH` that excludes pseudo-fs **and every separately-mounted block-device filesystem** so other disks like `/data` aren't copied into the new root, chroot bind-mounts, GRUB + initramfs, UUID-based fstab rewrite validated in chroot before replacing the real file). `full-disk` runs the root copy then the LVM move.

`storage-post-migration.sh` (~580 lines) repairs/audits after a migration: fstab CD-ROM & swap-UUID sync, initramfs resume config, GRUB `resume=` cleanup, optional LVM extension, rebuild boot artifacts, and a `--postboot` live audit. Use `--root <path>` to operate on a mounted target (e.g. `/mnt/newroot`) instead of `/`; log paths and chroot helpers resolve inside that root.

### Runtime safety model
- Both scripts use `set -euo pipefail` and `IFS=$'\n\t'`.
- Risky commands run through `log_command` (records command + exit code; supports dry-run) or `log_interactive_command` (streams via `tee` for long ops like `rsync`/`pvmove`).
- Key paths: `LOG_FILE=/var/log/storage-migrate.log` (falls back to `/tmp` if unwritable), `BACKUP_DIR=/root/storage-migrate-backups`, plus `RESUME_FILE`, `METADATA_FILE`, `FSTAB_VALIDATE_LOG` under the backup dir. Post-migration logs to `<root>/root/storage-migrate-backups/post-migration.log`.
- `get_part_name` handles device-naming differences (`sda1` vs `nvme0n1p1` vs `mmcblk0p1`); `wait_for_dev` waits for nodes after `partprobe`.

## Conventions

- **User-facing strings and many comments are in Romanian.** Preserve the surrounding language when editing a block.
- Bash: `#!/usr/bin/env bash`, `set -euo pipefail`, two-space indent, `case`-based arg parsing, short lowercase functions, `local` vars, quoted expansions, UPPERCASE globals.
- Don't hard-code real device names, UUIDs, or hostnames in examples. Treat `--yes` as hazardous and always document why when used.
