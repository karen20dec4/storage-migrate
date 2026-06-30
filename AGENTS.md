# Repository Guidelines

## Project Structure & Module Organization

This repository contains two top-level Bash scripts for Debian storage migration:

- `storage-migrate.sh`: primary migration workflow for root disk and/or LVM PV migration, including check, resume, dry-run-style validation, metadata capture, and fstab handling.
- `storage-post-migration.sh`: post-migration repair and audit helper for preboot or postboot checks, swap/fstab sync, boot settings, and optional LVM extension.

There is no separate `src/`, `tests/`, or assets directory. Keep new helper scripts at the repository root unless the project grows enough to justify a dedicated directory.

## Build, Test, and Development Commands

- `bash -n storage-migrate.sh storage-post-migration.sh`: syntax-check both scripts without executing them.
- `sudo ./storage-migrate.sh --check`: run the migration pre-validation path before attempting destructive actions.
- `sudo ./storage-migrate.sh --resume`: resume a failed LVM `pvmove` workflow when metadata exists.
- `sudo ./storage-post-migration.sh --summary`: run the post-migration helper with concise progress output.
- `sudo ./storage-post-migration.sh --postboot --verbose`: perform a postboot audit with detailed command output.

Run operational commands only on disposable test systems, VMs, or known-good backups. These scripts can repartition disks and modify boot-critical files.

## Coding Style & Naming Conventions

Use Bash with `#!/usr/bin/env bash`, `set -euo pipefail`, and `IFS=$'\n\t'` for new scripts. Prefer uppercase names for global configuration variables, lowercase names for functions, and local variables inside functions. Follow the existing style: two-space indentation, explicit argument parsing with `case`, short helper functions, and quoted variable expansions.

Keep user-facing messages concise. Existing comments include Romanian context; preserve nearby language style when editing related blocks.

## Testing Guidelines

At minimum, run `bash -n` before submitting changes. For behavioral changes, test the safest available path first: `--help`, `--check`, `--summary`, and `--no-color` modes. Validate destructive flows in a VM with virtual disks, not on a workstation. Capture logs from `/var/log/storage-migrate.log` and `/root/storage-migrate-backups/` when diagnosing failures.

## Commit & Pull Request Guidelines

Git history is not available in this working directory, so no existing commit convention can be inferred. Use clear imperative commits such as `Fix fstab validation for UUID swaps` or `Add postboot LVM audit option`.

Pull requests should describe the storage scenario tested, list commands run, mention VM or hardware details, and include relevant log excerpts for migration behavior changes.

## Security & Configuration Tips

Do not hard-code real device names, UUIDs, hostnames, or private paths in examples. Treat `--yes` as hazardous: document why it is needed and pair it with explicit `--source` and `--target` arguments.
