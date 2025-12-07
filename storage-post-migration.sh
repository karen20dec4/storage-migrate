#!/usr/bin/env bash
# post-migration.sh v2.4 - Final LVM detection fix + syntax cleanup
# - Summary-mode by default (concise console output)
# - Verbose mode streams command output (useful for debugging)
# - All detailed output is logged to LOG (default /root/storage-migrate-backups/post-migration.log)
#
# Usage:
#   ./post-migration.sh                 # summary (concise, incremental step rows)
#   ./post-migration.sh --verbose       # verbose (stream command output)
#   ./post-migration.sh --quiet         # very quiet (only fatal errors)
#   ./post-migration.sh --extend-lvm auto # auto-extend LVM
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.4"
ROOT="/"
MODE="preboot"
FIX_RESUME="auto"
FIX_CDROM="nofail"
BLACKLIST_FLOPPY="yes"
QUIET_BOOT="keep"
SYNC_FSTAB_SWAP="yes"
EXTEND_LVM="ask" # auto | ask | no
LOG_REL="/root/storage-migrate-backups/post-migration.log"
VERBOSITY="summary"   # quiet | summary | verbose
COLOR=true

# Helpers
ce() { echo "$@" >&2; }
require_root() { [ "$(id -u)" -eq 0 ] || { ce "This script must run as root."; exit 1; } }
path_in_root() { echo "${ROOT%/}$1"; }
read_arg() { local key="$1"; shift || true; if [ $# -gt 0 ]; then printf "%s" "$1"; else ce "Missing value for ${key}"; exit 1; fi }

# Color setup
_red() { [ "$COLOR" = true ] && printf '\033[0;31m%s\033[0m' "$1" || printf '%s' "$1"; }
_green() { [ "$COLOR" = true ] && printf '\033[0;32m%s\033[0m' "$1" || printf '%s' "$1"; }
_yellow() { [ "$COLOR" = true ] && printf '\033[1;33m%s\033[0m' "$1" || printf '%s' "$1"; }
_blue() { [ "$COLOR" = true ] && printf '\033[0;34m%s\033[0m' "$1" || printf '%s' "$1"; }

# Helper for interactive ask
_ask() {
  [ "${VERBOSITY}" = "quiet" ] && return 1 # if quiet, default to no
  local prompt="$1" default="${2:-yes}" response
  if [ "$default" = "yes" ]; then
    read -rp "$(_yellow "$prompt") [Y/n]: " response
    response=${response:-y}
  else
    read -rp "$(_yellow "$prompt") [y/N]: " response
    response=${response:-n}
  fi
  [[ "$response" =~ ^[Yy] ]]
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(read_arg "$1" ${2-})"; shift ;;
    --preboot) MODE="preboot" ;;
    --postboot) MODE="postboot" ;;
    --fix-resume) FIX_RESUME="$(read_arg "$1" ${2-})"; shift ;;
    --fix-cdrom) FIX_CDROM="$(read_arg "$1" ${2-})"; shift ;;
    --blacklist-floppy) BLACKLIST_FLOPPY="$(read_arg "$1" ${2-})"; shift ;;
    --quiet-boot) QUIET_BOOT="$(read_arg "$1" ${2-})"; shift ;;
    --sync-fstab-swap) SYNC_FSTAB_SWAP="$(read_arg "$1" ${2-})"; shift ;;
    --extend-lvm) EXTEND_LVM="$(read_arg "$1" ${2-})"; shift ;;
    --log) LOG_REL="$(read_arg "$1" ${2-})"; shift ;;
    --verbose) VERBOSITY="verbose" ;;
    --summary) VERBOSITY="summary" ;;
    --quiet) VERBOSITY="quiet" ;;
    --no-color) COLOR=false ;;
    -h|--help)
      cat <<'USAGE'
post-migration.sh v2.4
Usage:
  ./post-migration.sh [--postboot] [--verbose|--summary|--quiet] [--no-color] [--log <file>]
Options:
  --postboot            run additional checks for a live system (post-boot audit)
  --verbose             stream detailed output to console + log
  --summary             concise console output (default)
  --quiet               only log to file; show errors on console
  --no-color            disable color in console output
  --log <file>          set log file path inside target root
  --extend-lvm <auto|ask|no>
                        (Default: ask) Check and extend LVM volumes that have free space in their VG.
  --help                show this help
USAGE
      exit 0
      ;;
    *)
      ce "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

require_root

LOG="$(path_in_root "${LOG_REL}")"
mkdir -p "$(dirname "${LOG}")"
touch "${LOG}" || { ce "Cannot write log: ${LOG}"; exit 1; }

_now() { date '+%Y-%m-%d %H:%M:%S'; }
_ts() { date '+%s'; }

# Logging primitives
_log_write() { local ts; ts=$(_now); echo "[$ts] $*" >> "${LOG}"; }
log_summary() { _log_write "$@"; if [ "${VERBOSITY}" = "summary" ] || [ "${VERBOSITY}" = "verbose" ]; then echo "[$(_now)] $*"; fi; }
log_info() { _log_write "$@"; if [ "${VERBOSITY}" = "verbose" ]; then echo "[$(_now)] $*" ; fi; }
log_error() { _log_write "ERROR: $*"; echo "[$(_now)] ${_red "ERROR:"} $*" >&2; }

# run_cmd: behavior depends on VERBOSITY
run_cmd() {
  if [ "${VERBOSITY}" = "verbose" ]; then
    echo "+ $*"
    ( set -o pipefail; "$@" 2>&1 | tee -a "${LOG}" )
    local rc=${PIPESTATUS[0]:-$?}
    if [ "${rc}" -ne 0 ]; then
      log_error "Command failed (rc=${rc}): $*"
      return "${rc}"
    fi 
  else
    _log_write "+ $*"
    if "$@" >> "${LOG}" 2>&1; then
      log_info "Command succeeded: $*"
    else
      local rc=$?
      log_error "Command failed (rc=${rc}): $*"
      return "${rc}"
    fi
  fi
  return 0
}

# Step tracking arrays
declare -a STEPS_NAME=()
declare -a STEPS_STATUS=()
declare -a STEPS_TIME=()

step_start() {
  STEPS_NAME+=("$1")
  STEPS_TIME+=("$(_ts)") # store start epoch; will be replaced with duration on ok/fail
  STEPS_STATUS+=("running")
  # On start, print header once if first step
  if [ "${#STEPS_NAME[@]}" -eq 1 ]; then
    # print header for incremental table
    if [ "${VERBOSITY}" != "quiet" ]; then
      echo ""
      echo "$(_blue '--- post-migration progress ---')"
      printf "%-3s  %-40s  %-8s   %6s\n" "#" "STEP" "STATUS" "DUR(s)"
      echo "---------------------------------------------------------------------"
    fi
  fi
}

# Print a single step row immediately when completed
step_print_row() {
  local idx="$1"
  local num=$((idx+1))
  local name="${STEPS_NAME[$idx]}"
  local status="${STEPS_STATUS[$idx]}"
  local dur="${STEPS_TIME[$idx]}"
  local status_str
  if [ "${status}" = "ok" ]; then
    status_str="$(_green "✓ OK")"
  elif [ "${status}" = "failed" ]; then
    status_str="$(_red "✖ FAIL")"
  else
    status_str="$(_yellow "${status}")"
  fi
  if [ "${VERBOSITY}" != "quiet" ]; then
    printf "%-3s  %-40s  %-8s   %6s\n" "${num}" "${name:0:40}" "${status_str}" "${dur}"
  fi
}

step_ok() {
  local idx=$(( ${#STEPS_NAME[@]} - 1 ))
  STEPS_STATUS[$idx]="ok"
  local start=${STEPS_TIME[$idx]}
  local dur=$(( $(_ts) - start ))
  STEPS_TIME[$idx]="${dur}"
  log_info "STEP OK: ${STEPS_NAME[$idx]} (${dur}s)"
  step_print_row "${idx}"
}

step_fail() {
  local idx=$(( ${#STEPS_NAME[@]} - 1 ))
  STEPS_STATUS[$idx]="failed"
  local start=${STEPS_TIME[$idx]}
  local dur=$(( $(_ts) - start ))
  STEPS_TIME[$idx]="${dur}"
  log_error "STEP FAILED: ${STEPS_NAME[$idx]} (${dur}s)"
  step_print_row "${idx}"
}

# target-root helpers (prefers chroot when root != /)
_chroot() { chroot "${ROOT%/}" "$@" || "$@"; }
blkid_in_root() { _chroot blkid "$@" 2>/dev/null || true; }
swapon_show_in_root() { _chroot swapon --show 2>/dev/null || true; }
# Corectam helper-ele LVM sa nu foloseasca chroot daca ROOT=/
vgs_in_root() {
  if [ "${ROOT}" = "/" ]; then vgs "$@" 2>/dev/null || true; else _chroot vgs "$@" 2>/dev/null || true; fi
}
lvs_in_root() {
  if [ "${ROOT}" = "/" ]; then lvs "$@" 2>/dev/null || true; else _chroot lvs "$@" 2>/dev/null || true; fi
}
findmnt_in_root() {
  if [ "${ROOT}" = "/" ]; then findmnt "$@" 2>/dev/null || true; else _chroot findmnt "$@" 2>/dev/null || true; fi
}

get_swap_uuid_candidates() {
  local fstab; fstab="$(path_in_root /etc/fstab)"
  if [ -f "${fstab}" ]; then
    awk 'NF && $1 !~ /^#/ && $3=="swap" {print $1}' "${fstab}" | sed -n 's/^UUID=//p' || true
  fi
  blkid_in_root -t TYPE=swap -o value -s UUID | head -n 20 || true
}

get_current_swap_uuid() {
  local active
  active=$(swapon_show_in_root | awk 'NR>1{print $1; exit}')
  if [ -n "${active:-}" ]; then
    blkid_in_root -s UUID -o value "${active}" | head -n1 || true
    return
  fi
  blkid_in_root -t TYPE=swap -o value -s UUID | head -n1 || true
}

# Steps implementations
fix_cdrom_fstab() {
  step_start "CD-ROM fstab tune"
  local fstab; fstab="$(path_in_root /etc/fstab)"
  if [ ! -f "${fstab}" ]; then
    _log_write "No /etc/fstab found; skipping CD-ROM tune"
    step_ok; return 0
  fi
  case "${FIX_CDROM}" in
    keep) _log_write "Keep CD-ROM as-is"; step_ok; return 0 ;;
    comment)
      if grep -qE '^[^#].*\s+/media/cdrom0\s+.*(iso9660|udf)' "${fstab}"; then
        sed -i 's#^\([^#].*\s\+/media/cdrom0\s\+.*\)#\1  # commented by post-migration.sh#' "${fstab}" || true
        _log_write "CD-ROM entry commented in fstab"
      fi
      step_ok; return 0 ;;
    nofail)
      if grep -qE '^\s*/dev/sr0\s+/media/cdrom0\s+udf,iso9660\s+' "${fstab}"; then
        awk '{
          if ($1=="/dev/sr0" && $2=="/media/cdrom0") {
            if ($4 ~ /nofail/) { sub(/nofail/,"nofail,x-systemd.device-timeout=1s",$4) }
            else { $4=$4",nofail,x-systemd.device-timeout=1s" }
          }
          print
        }' "${fstab}" > "${fstab}.tmp" && mv "${fstab}.tmp" "${fstab}"
        _log_write "CD-ROM options updated: nofail + 1s device timeout."
      fi
      step_ok; return 0 ;;
    *)
      _log_write "Unknown --fix-cdrom option: ${FIX_CDROM}"
      step_fail; return 1 ;;
  esac
}

blacklist_floppy() {
  step_start "Blacklist floppy"
  [ "${BLACKLIST_FLOPPY}" = "yes" ] || { _log_write "Floppy blacklist disabled"; step_ok; return 0; }
  local conf; conf="$(path_in_root /etc/modprobe.d/blacklist-floppy.conf)"
  echo "blacklist floppy" > "${conf}"
  _log_write "Floppy module blacklisted"
  step_ok
}

sync_fstab_swap_uuid() {
  step_start "Sync fstab swap UUID"
  [ "${SYNC_FSTAB_SWAP}" = "yes" ] || { _log_write "Sync fstab swap disabled by option"; step_ok; return 0; }
  local fstab; fstab="$(path_in_root /etc/fstab)"
  if [ ! -f "${fstab}" ]; then _log_write "No fstab; skipping swap sync"; step_ok; return 0; fi
  local new_uuid old_uuid
  new_uuid="$(get_current_swap_uuid)"
  [ -n "${new_uuid}" ] || { _log_write "No swap UUID detected; skip fstab update"; step_ok; return 0; }
  old_uuid="$(awk 'NF && $1 !~ /^#/ && $3=="swap" {print $1}' "${fstab}" | sed -n 's/^UUID=//p' | head -n1 || true)"
  if [ -n "${old_uuid}" ] && [ "${old_uuid}" = "${new_uuid}" ]; then
    _log_write "fstab swap UUID already matches (${new_uuid})."
    step_ok; return 0
  fi
  awk -v uuid="${new_uuid}" '
    /^[[:space:]]*#/ { print; next }
    NF==0 { print; next }
    $3=="swap" { $1="UUID=" uuid; print; next }
    { print }
  ' "${fstab}" > "${fstab}.tmp" && mv "${fstab}.tmp" "${fstab}"
  _log_write "fstab swap UUID updated to ${new_uuid}"
  step_ok
}

fix_resume_conf() {
  step_start "Fix resume config"
  local resume_conf; resume_conf="$(path_in_root /etc/initramfs-tools/conf.d/resume)"
  local swap_uuid=""
  case "${FIX_RESUME}" in
    disable)
      if [ -f "${resume_conf}" ]; then sed -i 's/^/## disabled by post-migration.sh: /' "${resume_conf}" || true; fi
      _log_write "Resume disabled (commented)"
      step_ok; return 0 ;;
    auto)
      swap_uuid="$(get_current_swap_uuid)"
      if [ -z "${swap_uuid}" ]; then swap_uuid="$(get_swap_uuid_candidates | head -n1 || true)"; fi
      if [ -n "${swap_uuid}" ]; then
        mkdir -p "$(dirname "${resume_conf}")"
        if [ -f "${resume_conf}" ] && grep -q '^RESUME=' "${resume_conf}"; then
          sed -i "s|^RESUME=.*|RESUME=UUID=${swap_uuid}|" "${resume_conf}"
        else
          echo "RESUME=UUID=${swap_uuid}" > "${resume_conf}"
        fi
        _log_write "Resume updated to swap UUID=${swap_uuid}"
        step_ok; return 0
      else
        if [ -f "${resume_conf}" ]; then sed -i 's/^/## disabled by post-migration.sh (no swap found): /' "${resume_conf}" || true; fi
        _log_write "No swap found; resume disabled."
        step_ok; return 0
      fi ;;
    uuid=*)
      swap_uuid="${FIX_RESUME#uuid=}"
      mkdir -p "$(dirname "${resume_conf}")"
      echo "RESUME=UUID=${swap_uuid}" > "${resume_conf}"
      _log_write "Resume set to explicit UUID=${swap_uuid}"
      step_ok; return 0 ;;
    *)
      _log_write "Unknown --fix-resume option: ${FIX_RESUME}"
      step_fail; return 1 ;;
  esac
}

clean_grub_resume() {
  step_start "Clean GRUB resume"
  local grub_def; grub_def="$(path_in_root /etc/default/grub)"
  # CORECTIE V7: Adaugat 'fi' lipsa
  if [ ! -f "${grub_def}" ]; then _log_write "No /etc/default/grub (skipping)"; step_ok; return 0; fi 
  sed -i 's/\(GRUB_CMDLINE_LINUX[^=]*="\)[^"]*\bresume=[^" ]* *\([^"]*"\)/\1\2/g' "${grub_def}" || true
  case "${QUIET_BOOT}" in
    yes)
      if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "${grub_def}"; then
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 \1"/' "${grub_def}"
      else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"' >> "${grub_def}"
      fi
      ;;
    no)
      sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)\bquiet\b *//; s/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)\bloglevel=[0-9]\b *//;' "${grub_def}" || true
      ;;
    *) : ;;
  esac
  _log_write "GRUB resume cleaned; quiet-boot=${QUIET_BOOT}"
  step_ok
}

extend_lvm_volumes() {
  step_start "Check/Extend LVM volumes"
  [ "${EXTEND_LVM}" = "no" ] && { _log_write "LVM extend disabled by option"; step_ok; return 0; }
  
  if ! command -v vgs >/dev/null 2>&1 || ! command -v lvextend >/dev/null 2>&1; then
    _log_write "LVM tools (vgs, lvextend) not found. Skipping resize."
    step_ok; return 0 # Not a failure, just a skip
  fi

  local vgs_with_free
  # Folosim vg_free > 1024m pentru a include VGs cu cel putin 1G liber
  vgs_with_free=$(vgs_in_root --noheadings --units m -o vg_name,vg_free --separator=',' --select 'vg_free > 1024' 2>/dev/null || true)
  
  if [ -z "${vgs_with_free}" ]; then
    _log_write "No VGs found with >1G free space."
    step_ok; return 0
  fi
  
  _log_write "VGs with free space found: ${vgs_with_free}"
  
  local vg_name vfree all_lv_paths mounted_lvs lv_path mountpoint fs_type extend_count=0 overall_ok=true
  
  while IFS=',' read -r vg_name vfree; do
    [ -z "${vg_name}" ] && continue
    # vfree vine acum in Megabytes (m), pentru prompt il convertim in G
    local vfree_mb
    vfree_mb=$(LC_ALL=C printf "%.0f" "${vfree}" 2>/dev/null || echo "0")
    local vfree_gb=$((vfree_mb / 1024))
    
    # **LOGICA V6/V7: Nu folosim mountpoint din lvs, folosim findmnt pentru fiabilitate.**

    # 1. Obtinem toate LV path-urile din acest VG
    # Folosim tr pentru a transforma output-ul intr-o lista de linii
    all_lv_paths=$(lvs_in_root --noheadings -o lv_path --separator=',' --select "vg_name=${vg_name}" 2>/dev/null | tr ',' '\n' | grep -v '^\s*$' || true)
    
    # 2. Verificam care LV-uri sunt montate
    mounted_lvs=""
    for lv_path in ${all_lv_paths}; do
      # Curatam spatiile albe (care apar in output-ul lvs)
      lv_path=$(echo "${lv_path}" | tr -d '[:space:]')
      [ -z "${lv_path}" ] && continue
      
      # Folosim findmnt pentru a verifica daca e montat si unde
      mountpoint=$(findmnt_in_root -no TARGET "${lv_path}" 2>/dev/null || true)
      
      if [ -n "${mountpoint}" ]; then
        # Am gasit un LV montat: adaugam in lista (path;mountpoint) - folosim ';' ca separator sigur
        mounted_lvs+="${lv_path};${mountpoint}\n"
      fi
    done
    
    # Curatam spatiile goale si liniile noi
    mounted_lvs=$(echo -e "${mounted_lvs}" | grep -v '^\s*$' || true)
    
    if [ -z "${mounted_lvs}" ]; then
      _log_write "VG '${vg_name}' has free space, but no mounted LVs were found. Skipping automatic resize."
      continue
    fi
    
    # 3. Verificare de siguranta: trebuie sa fie un singur LV montat
    if [ "$(echo -e "${mounted_lvs}" | wc -l)" -ne 1 ]; then
      _log_write "VG '${vg_name}' has free space, but has multiple mounted LVs or the output is malformed. Skipping automatic resize for safety."
      _log_write "Detected mounted LVs count: $(echo -e "${mounted_lvs}" | wc -l)"
      continue
    fi
    
    # 4. Procesam singurul LV montat gasit. Separatorul este ';'
    IFS=';' read -r lv_path mountpoint <<< "${mounted_lvs}"
    # Curatam spatiile albe
    lv_path=$(echo "${lv_path}" | xargs)
    mountpoint=$(echo "${mountpoint}" | xargs)

    local proceed=false
    if [ "${EXTEND_LVM}" = "auto" ]; then
      proceed=true
    elif [ "${EXTEND_LVM}" = "ask" ]; then
      if _ask "Found ${vfree_gb}G (${vfree_mb}M) free in VG '${vg_name}'. Extend '${mountpoint}' (${lv_path}) to use it?"; then
        proceed=true
      else
        _log_write "User skipped resize for '${mountpoint}'."
      fi
    fi
    
    if [ "${proceed}" = true ]; then
      _log_write "Extending LV: ${lv_path} (${mountpoint})"
      if ! run_cmd lvextend -l +100%FREE "${lv_path}"; then
        _log_write "ERROR: lvextend failed for ${lv_path}"
        overall_ok=false; continue
      fi
      
      fs_type=$(findmnt_in_root -no FSTYPE "${mountpoint}" 2>/dev/null || echo "ext4")
      _log_write "Filesystem type for '${mountpoint}' is '${fs_type}'."
      
      case "${fs_type}" in
        ext2|ext3|ext4)
          if ! run_cmd resize2fs "${lv_path}"; then
            _log_write "ERROR: resize2fs failed for ${lv_path}"
            overall_ok=false
          else
            extend_count=$((extend_count + 1))
          fi
          ;;
        xfs)
          if ! run_cmd xfs_growfs "${mountpoint}"; then # Note: xfs_growfs takes mountpoint
            _log_write "ERROR: xfs_growfs failed for ${mountpoint}"
            overall_ok=false
          else
            extend_count=$((extend_count + 1))
          fi
          ;;
        *)
          _log_write "WARN: Filesystem '${fs_type}' needs manual resize: ${lv_path}"
          ;;
      esac
    fi
  done <<< "${vgs_with_free}"

  _log_write "LVM check complete. Extended ${extend_count} volume(s)."
  if [ "${overall_ok}" = true ]; then
    step_ok
  else
    step_fail
  fi
}


rebuild_boot_artifacts() {
  step_start "Rebuild initramfs & grub"
  local realroot; realroot="$(readlink -f "${ROOT}")"
  if [ "${realroot}" = "/" ]; then
    local kcur; kcur="$(uname -r)"
    if ! run_cmd /usr/sbin/update-initramfs -u -k "${kcur}" -v; then
      step_fail; return 1
    fi
    if ! run_cmd /usr/sbin/update-grub; then
      step_fail; return 1
    fi
  else
    if ! run_cmd chroot "${realroot}" update-initramfs -u -k all; then step_fail; return 1; fi
    if ! run_cmd chroot "${realroot}" update-grub; then step_fail; return 1; fi
  fi
  _log_write "Boot artifacts updated"
  step_ok
  return 0
}

postboot_audit() {
  step_start "Post-boot audit"
  [ -r /proc/cmdline ] && _log_write "cmdline: $(cat /proc/cmdline)"
  if command -v systemd-analyze >/dev/null 2>&1; then
    _log_write "Boot time: $(systemd-analyze 2>/dev/null || true)"
    if [ "${VERBOSITY}" = "verbose" ]; then
      systemd-analyze blame 2>/dev/null | head -n 20 | tee -a "${LOG}"
    fi
  fi
  _log_write "Swap active:"
  swapon --show 2>&1 | tee -a "${LOG}" >/dev/null || true
  _log_write "Resume in cmdline? $(cat /proc/cmdline | tr " " "\n" | grep -i '^resume=' || true)"
  step_ok
}

# Run main
main_start=$(_ts)
_log_write "=== post-migration.sh v${SCRIPT_VERSION} start ==="
log_summary "post-migration.sh v${SCRIPT_VERSION} - mode=${MODE} root=${ROOT} verbosity=${VERBOSITY} extend_lvm=${EXTEND_LVM}"

fix_cdrom_fstab
blacklist_floppy
sync_fstab_swap_uuid
fix_resume_conf
clean_grub_resume

# Extend LVM *before* rebuilding initramfs, just in case
extend_lvm_volumes

if ! rebuild_boot_artifacts; then
  log_summary "WARN: update-initramfs/update-grub failed; attempting quick dpkg repair..."
  run_cmd apt-get -y -f install || true
  run_cmd dpkg --configure -a || true
  if ! rebuild_boot_artifacts; then
    log_error "Still failed to update boot artifacts. See ${LOG}"
  fi
fi

[ "${MODE}" = "postboot" ] && postboot_audit

# Final summary table (full)
echo ""
echo ""
echo ""
echo ""
echo $(_blue "========== post-migration summary ==========")
printf "%-3s  %-40s  %-8s   %6s\n" "#" "STEP" "STATUS" "DUR(s)"
echo "---------------------------------------------------------------------"
for i in "${!STEPS_NAME[@]}"; do
  num=$((i+1))
  name="${STEPS_NAME[$i]}"
  status="${STEPS_STATUS[$i]}"
  dur="${STEPS_TIME[$i]}"
  if [ "${status}" = "ok" ]; then
    status_str="$(_green "✓ OK")"
  elif [ "${status}" = "failed" ]; then
    status_str="$(_red "✖ FAIL")"
  else
    status_str="$(_yellow "${status}")"
  fi
  printf "%-3s  %-40s  %-8s   %6s\n" "${num}" "${name:0:40}" "${status_str}" "${dur}"
done
total_dur=$(( $(_ts) - main_start ))
echo "---------------------------------------------------------------------"
echo "Total time: ${total_dur}s"
echo ""
echo "Detailed log: ${LOG}"
echo $(_blue "=============================================")

_log_write "=== post-migration.sh done (total ${total_dur}s) ==="

exit 0