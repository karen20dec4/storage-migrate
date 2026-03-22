#!/usr/bin/env bash
#
# Debian Storage Migration Script V3.1 - mode selection menu, hh:mm:ss progress, ETA
# Author: karen20ced4 + Copilot revisions
# Repository: https://github.com/karen20ced4/NVME-Migrate
# Version: 3.1
# Date: 2026-03-21
#
# Scop: migrare disc root si/sau LVM PV intre drive-uri; clonare disc de date (NTFS, exFAT, etc.).
#        Include: dry-run, check, resume, robust fstab update, better device detection,
#        resume for pvmove, metadata save, data-clone (dd) for USB/NTFS/exFAT drives,
#        menu selectare mod, progress bar cu ETA si timp hh:mm:ss.
#
# NOTE FOR AI: Increment version by +0.1 and update the Date comment each time this file is modified.
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="3.1"
SCRIPT_DATE="2026-03-21"
SCRIPT_AUTHOR="karen20ced4"
SCRIPT_REPO="https://github.com/karen20ced4/NVME-Migrate"

LOG_FILE="/var/log/storage-migrate.log"
DRY_RUN_MODE=false
RESUME_MODE=false
CHECK_MODE=false
DEBUG_MODE=false
BACKUP_DIR="/root/storage-migrate-backups"

# User-chosen operation mode: auto | os-migration | data-clone
USER_MODE_CHOICE="auto"
RESUME_FILE="${BACKUP_DIR}/lvm-resume.sh"
METADATA_FILE="${BACKUP_DIR}/migration-metadata.json"
FSTAB_VALIDATE_LOG="${BACKUP_DIR}/fstab-validate.log"

# Migration variables
SOURCE_DISK=""
TARGET_DISK=""
MIGRATION_TYPE=""
SOURCE_HAS_ROOT=false
SOURCE_HAS_LVM=false
SOURCE_HAS_DATA=false
SOURCE_PVS=()
SOURCE_DATA_PARTS=()
SOURCE_DATA_FS_TYPES=()
SOURCE_ROOT_DEV=""
SOURCE_ROOT_SIZE_GB=0
SOURCE_SWAP_SIZE_GB=0

# Target partition variables
TARGET_ROOT=""
TARGET_SWAP=""
TARGET_EXTRA=""
TARGET_ROOT_SIZE_GB=0
TARGET_IS_USB=false

# System detection
BOOT_MODE=""
CURRENT_ROOT_DEV=""
CURRENT_ROOT_DISK=""

# LVM detection
VG_NAME=""
LV_NAME=""
HOME_SOURCE=""
DETECTED_VGS=()

# Cache for PVs to avoid multiple calls
ALL_PVS_CACHE=""
PVS_CACHE_LOADED=false

TOTAL_STEPS=20
CURRENT_STEP=0

# Configurable timeouts
DEVICE_WAIT_TIMEOUT=45
UDEV_SETTLE_TIMEOUT=5

# Colors
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
fi

# ── Time helpers ──────────────────────────────────────────────────────────────
# Convert seconds to hh:mm:ss display string
seconds_to_hms() {
  local s="${1:-0}"
  [[ "${s}" =~ ^[0-9]+$ ]] || s=0
  printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# Draw a one-line animated progress bar:
#   draw_transfer_progress <pct> <speed_mb> <elapsed_hms> <eta_hms>
draw_transfer_progress() {
  local pct="${1:-0}" speed_mb="${2:-0}"
  local elapsed_str="${3:-00:00:00}" eta_str="${4:---:--:--}"
  local w=40 filled empty
  [ "${pct}" -gt 100 ] && pct=100
  [ "${pct}" -lt 0   ] && pct=0
  filled=$(( pct * w / 100 ))
  empty=$(( w - filled ))
  printf "\r  ${CYAN}[${GREEN}"
  [ "${filled}" -gt 0 ] && printf "%${filled}s" | tr ' ' '█'
  printf "${DIM}"
  [ "${empty}"  -gt 0 ] && printf "%${empty}s"  | tr ' ' '░'
  printf "${NC}${CYAN}]${NC} ${BOLD}%3d%%${NC}  ${GREEN}%4d MB/s${NC}  ⏱ ${CYAN}%s${NC}  ⏳ ${YELLOW}%s${NC}  " \
    "${pct}" "${speed_mb}" "${elapsed_str}" "${eta_str}"
}

print_header() {
  echo -e "${CYAN}${BOLD}"
  echo "╔════════════════════════════════════════════════════════════════════════════╗"
  echo "║  Debian Storage Migration Script v${SCRIPT_VERSION}                        ║"
  echo "║  Universal disk migration tool - SATA/NVMe/SSD - LVM/non-LVM               ║"
  echo "╚════════════════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "${DIM}Version: ${SCRIPT_VERSION} | Date: ${SCRIPT_DATE} | Author: ${SCRIPT_AUTHOR}${NC}"
  echo -e "${DIM}Repository: ${SCRIPT_REPO}${NC}\n"
}

print_step() {
  printf "\n${BLUE}${BOLD}[STEP %s/%s]${NC} ${BOLD}%s${NC}\n" "$1" "$2" "$3"
  echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
}

print_success()  { echo -e "${GREEN}${BOLD}✅${NC} $1"; }
print_warning()  { echo -e "${YELLOW}${BOLD}⚠️${NC} $1"; }
print_error()    { echo -e "${RED}${BOLD}❌${NC} $1"; }
print_info()     { echo -e "${CYAN}[i] ${NC} $1"; }

print_dry_run() {
  local cmd_str=""
  for a in "$@"; do
    case "$a" in *[[:space:]]*) cmd_str+=" \"$a\"" ;; *) cmd_str+=" $a" ;; esac
  done
  echo -e "${MAGENTA}${BOLD}[DRY-RUN]${NC}${cmd_str}"
}

confirm_action() {
  local prompt="$1" default="${2:-no}" response
  if [ "$default" = "yes" ]; then
    read -rp "$(echo -e ${YELLOW}${BOLD}${prompt}${NC} [Y/n]: )" response
    response=${response:-y}
  else
    read -rp "$(echo -e ${YELLOW}${BOLD}${prompt}${NC} [y/N]: )" response
    response=${response:-n}
  fi
  [[ "$response" =~ ^[Yy] ]]
}

# prompt_read: prints a prompt and reads input safely; returns default on EOF/empty
prompt_read() {
  local prompt="$1"
  local default="${2:-}"
  local input=""
  printf "%b" "$prompt" >&2
  if ! IFS= read -r input; then
    input="${default}"
  fi
  if [ -z "${input}" ] && [ -n "${default}" ]; then
    input="${default}"
  fi
  printf "%s" "$input"
}

# ── Operation mode selection ──────────────────────────────────────────────────
# Displays a menu and sets USER_MODE_CHOICE to one of:
#   os-migration | data-clone | auto
select_operation_mode() {
  echo -e "\n${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║  Selectare mod operare                                                     ║${NC}"
  echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"
  echo -e "${BOLD}Ce vrei să faci?${NC}\n"

  echo -e "  ${CYAN}${BOLD}[1]${NC} ${BOLD}Migrare sistem (OS)${NC}"
  echo -e "      Migrare disc root Linux pe un disc nou intern (SSD/NVMe/HDD, LVM)"
  echo -e "      Sursa conține sistem de operare → destinație: disc nou intern"
  echo ""
  echo -e "  ${CYAN}${BOLD}[2]${NC} ${BOLD}Clonare disc de date${NC}"
  echo -e "      Clonare sector-by-sector (NTFS, exFAT, USB HDD, orice tip de disc)"
  echo -e "      Exemplu: clonare HDD USB NTFS 4TB pe alt HDD USB NTFS 4TB"
  echo ""
  echo -e "  ${CYAN}${BOLD}[3]${NC} ${BOLD}Auto-detectare${NC} ${DIM}(implicit — scriptul decide singur)${NC}"
  echo ""

  while true; do
    local choice
    choice=$(prompt_read "${CYAN}${BOLD}Alege [1/2/3, implicit 3]: ${NC}" "3")
    choice=$(echo "${choice}" | tr -d '[:space:]')
    case "${choice}" in
      1)
        USER_MODE_CHOICE="os-migration"
        print_success "Mod selectat: ${BOLD}Migrare sistem (OS)${NC}"
        return 0
        ;;
      2)
        USER_MODE_CHOICE="data-clone"
        print_success "Mod selectat: ${BOLD}Clonare disc de date${NC}"
        return 0
        ;;
      3|"")
        USER_MODE_CHOICE="auto"
        print_success "Mod selectat: ${BOLD}Auto-detectare${NC}"
        return 0
        ;;
      *)
        print_warning "Alegere invalidă. Introdu 1, 2 sau 3."
        ;;
    esac
  done
}
select_disk_from_list() {
  local __resultvar="$1"
  local prompt_title="$2"
  local exclude_root="${3:-false}"
  local -a disks=()
  local line disk i=0

  while IFS= read -r line; do
    case "$line" in
      NAME*) continue ;;
    esac
    disk=$(echo "$line" | awk '{print $1}')
    [ -z "$disk" ] && continue
    if [ "${exclude_root}" = "true" ] && [ -n "${CURRENT_ROOT_DISK}" ] && [ "${disk}" = "${CURRENT_ROOT_DISK}" ]; then
      continue
    fi
    disks+=("$disk")
  done < <(lsblk -d -p -o NAME,SIZE,MODEL,TRAN 2>/dev/null)

  if [ "${#disks[@]}" -eq 0 ]; then
    printf -v "$__resultvar" ""
    return 0
  fi

  if [ "${#disks[@]}" -eq 1 ]; then
    local sel="${disks[0]}"
    local ans
    ans=$(prompt_read "${CYAN}${BOLD}${prompt_title}:${NC} Găsit doar ${sel}. Confirmi? [Y/n]: " "y")
    if [[ "${ans}" =~ ^[Yy] ]]; then
      printf -v "$__resultvar" "%s" "${sel}"
      return 0
    fi
  fi

  echo -e "\n${BOLD}${prompt_title}:${NC}"
  for ((i=0;i<${#disks[@]};i++)); do
    printf "  %3d) %s\n" $((i+1)) "${disks[i]}"
  done
  echo ""

  while true; do
    local choice
    choice=$(prompt_read "${CYAN}Alege disk (1-${#disks[@]}) sau introdu calea (/dev/sdX): ${NC}" "")
    choice=$(echo "${choice}" | tr -d '[:space:]')
    if [ -z "${choice}" ]; then
      echo "Introdu o alegere validă."
      continue
    fi
    if [[ "${choice}" =~ ^[0-9]+$ ]]; then
      if [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#disks[@]}" ]; then
        printf -v "$__resultvar" "%s" "${disks[choice-1]}"
        return 0
      else
        echo "Număr în afara intervalului."
        continue
      fi
    fi
    if [ -b "${choice}" ]; then
      printf -v "$__resultvar" "%s" "${choice}"
      return 0
    fi
    echo "Dispozitiv invalid: ${choice}"
  done
}

show_progress() {
  local current=$1 total=$2 width=50 percentage filled empty
  percentage=$((current * 100 / total))
  filled=$((width * current / total))
  empty=$((width - filled))
  printf "\r${CYAN}Progress: [${GREEN}"
  printf "%${filled}s" | tr ' ' '█'
  printf "${DIM}"
  printf "%${empty}s" | tr ' ' '░'
  printf "${CYAN}] ${BOLD}%3d%%%s" "$percentage" "${NC}"
}

get_part_name() {
  local disk="$1" idx="$2"
  if [[ "$disk" =~ nvme ]] || [[ "$disk" =~ mmcblk ]] || [[ "$disk" =~ loop ]]; then
    printf "%sp%s" "$disk" "$idx"
  else
    printf "%s%s" "$disk" "$idx"
  fi
}

wait_for_dev() {
  local dev="$1" timeout="${2:-${DEVICE_WAIT_TIMEOUT}}" elapsed=0
  print_info "Aștept device node '${dev}' (timeout: ${timeout}s)..."
  while [ ! -b "${dev}" ] && [ "${elapsed}" -lt "${timeout}" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
    printf "."
  done
  echo ""
  udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
  sleep 1
  if [ -b "${dev}" ]; then
    print_success "Device '${dev}' este disponibil."
    return 0
  fi
  print_error "Timeout! Device '${dev}' nu a apărut după ${timeout}s."
  return 1
}

# Logging and execution
setup_logging() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}" 2>/dev/null || {
    LOG_FILE="/tmp/storage-migrate.log"
    print_warning "Nu pot scrie în /var/log, folosesc ${LOG_FILE}"
  }
  if [ "${RESUME_MODE}" = false ]; then
    log_message "=========================================="
    log_message "Storage Migration Script v${SCRIPT_VERSION}"
    log_message "Started: $(date '+%Y-%m-%d %H:%M:%S')"
    log_message "User: $(whoami)"
    log_message "Debug mode: ${DEBUG_MODE}"
    log_message "=========================================="
  else
    log_message "=========================================="
    log_message "Script re-started in RESUME mode"
    log_message "Resumed: $(date '+%Y-%m-%d %H:%M:%S')"
    log_message "=========================================="
  fi
}

log_message() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] $1" >>"${LOG_FILE}"
}

log_command() {
  local -a cmd=("$@")
  local cmd_str=""
  for a in "${cmd[@]}"; do
    case "$a" in *[[:space:]]*) cmd_str+=" \"$a\"" ;; *) cmd_str+=" $a" ;; esac
  done
  log_message "EXEC:${cmd_str}"
  if [ "${DRY_RUN_MODE}" = true ]; then
    print_dry_run "${cmd[@]}"
    return 0
  fi
  "${cmd[@]}" >>"${LOG_FILE}" 2>&1
  local exit_code=$?
  log_message "EXIT CODE: ${exit_code}"
  return "${exit_code}"
}

log_interactive_command() {
  local -a cmd=("$@")
  local cmd_str=""
  for a in "${cmd[@]}"; do
    case "$a" in *[[:space:]]*) cmd_str+=" \"$a\"" ;; *) cmd_str+=" $a" ;; esac
  done
  log_message "INTERACTIVE EXEC:${cmd_str}"
  if [ "${DRY_RUN_MODE}" = true ]; then
    print_dry_run "${cmd[@]}"
    return 0
  fi
  ( set -o pipefail; "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}" )
  local exit_code=$?
  log_message "EXIT CODE: ${exit_code}"
  return "${exit_code}"
}

get_disk_info() {
  local disk="$1"
  local size model tran size_gb

  size=$(lsblk -bdno SIZE "${disk}" 2>/dev/null | tr -d '[:space:]' || echo 0)
  if [[ -z "$size" || ! "$size" =~ ^[0-9]+$ ]]; then
    size=0
  fi
  size_gb=$(awk -v s="$size" 'BEGIN{printf "%d", s/1073741824}')

  model=$(lsblk -dno MODEL "${disk}" 2>/dev/null | xargs || echo "Unknown")
  tran=$(lsblk -dno TRAN "${disk}" 2>/dev/null | xargs || echo "unknown")

  echo "${size_gb}|${model}|${tran}"
}

# FIXED: Cache PVs ...
cache_all_pvs() {
  if [ "${PVS_CACHE_LOADED}" = false ]; then
    ALL_PVS_CACHE=$(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' || true)
    PVS_CACHE_LOADED=true
    log_message "Cached all PVs: ${ALL_PVS_CACHE}"
  fi
}

detect_vgs_on_disk() {
  local disk="$1"
  local -a found_vgs=()

  cache_all_pvs
  if [ -n "${ALL_PVS_CACHE}" ]; then
    while read -r pv; do
      [ -z "${pv}" ] && continue
      if [[ "${pv}" =~ ^${disk}(p[0-9]+|[0-9]+)$ ]]; then
        local vg
        vg=$(pvs --noheadings -o vg_name "${pv}" 2>/dev/null | xargs || echo "")
        if [ -n "${vg}" ] && [[ ! " ${found_vgs[*]} " =~ " ${vg} " ]]; then
          found_vgs+=("${vg}")
        fi
      fi
    done <<< "${ALL_PVS_CACHE}"
  fi

  printf '%s\n' "${found_vgs[@]}"
}








scan_disk_usage() {
  local disk="$1"
  local has_root=false has_lvm=false has_swap=false has_data=false
  local -a pvs_found=()
  local -a mountpoints=()
  local -a data_parts=()
  local -a data_fs_types=()
  local root_dev="" root_size_gb=0 swap_size_gb=0

  log_message "Scanning disk usage for: ${disk}"
  udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
  cache_all_pvs

  while read -r part; do
    [ -z "${part}" ] && continue
    [ ! -b "${part}" ] && continue
    local mp
    mp=$(findmnt -no TARGET "${part}" 2>/dev/null || true)
    if [ -n "${mp}" ]; then
      mountpoints+=("${part}:${mp}")
      log_message "  Found mountpoint: ${part} → ${mp}"
      if [ "${mp}" = "/" ]; then
        has_root=true
        root_dev="${part}"
        local size_bytes
        size_bytes=$(lsblk -bno SIZE "${part}" 2>/dev/null || echo 0)
        root_size_gb=$(( (size_bytes + 1024**3 - 1) / 1024**3 ))
        log_message "  Found root: ${part} (${root_size_gb} GB)"
      fi
    fi
    if echo "${ALL_PVS_CACHE}" | grep -q "^${part}$"; then
      has_lvm=true
      pvs_found+=("${part}")
      log_message "  Found PV: ${part}"
    fi
    if swapon --noheadings --show=NAME 2>/dev/null | awk '{print $1}' | grep -xqF "${part}"; then
      has_swap=true
      local swap_bytes
      swap_bytes=$(blockdev --getsize64 "${part}" 2>/dev/null || echo 0)
      swap_size_gb=$(( (swap_bytes + 1024**3 - 1) / 1024**3 ))
      log_message "  Found swap: ${part} (${swap_size_gb} GB)"
    fi
    # Detect data partitions (non-root, non-LVM, non-swap) — covers NTFS, exFAT, ext4, etc.
    local fs_type
    fs_type=$(blkid -o value -s TYPE "${part}" 2>/dev/null || true)
    if [ -n "${fs_type}" ] && [ "${fs_type}" != "swap" ] && [ "${fs_type}" != "LVM2_member" ]; then
      if [ "${part}" != "${root_dev}" ]; then
        has_data=true
        data_parts+=("${part}")
        data_fs_types+=("${fs_type}")
        log_message "  Found data partition: ${part} type=${fs_type}"
      fi
    fi
  done < <(lsblk -no PATH,TYPE "${disk}" 2>/dev/null | awk '$2=="part" {print $1}')

  # output safe for parsing (no mountpoints line)
  printf 'has_root=%q\n' "${has_root}"
  printf 'has_lvm=%q\n' "${has_lvm}"
  printf 'has_swap=%q\n' "${has_swap}"
  printf 'has_data=%q\n' "${has_data}"
  printf 'root_dev=%q\n' "${root_dev}"
  printf 'root_size_gb=%q\n' "${root_size_gb}"
  printf 'swap_size_gb=%q\n' "${swap_size_gb}"
  printf 'pvs=%q\n' "${pvs_found[*]}"
  printf 'data_parts=%q\n' "${data_parts[*]:-}"
  printf 'data_fs_types=%q\n' "${data_fs_types[*]:-}"
  # note: mountpoints intentionally omitted to avoid parse issues in detect_source_type
}








detect_source_type() {
  log_message "Detecting migration type for source: ${SOURCE_DISK}"

  # Initialize defaults (safe under set -u)
  SOURCE_HAS_ROOT=false
  SOURCE_HAS_LVM=false
  SOURCE_HAS_SWAP=false
  SOURCE_HAS_DATA=false
  SOURCE_ROOT_DEV=""
  SOURCE_ROOT_SIZE_GB=0
  SOURCE_SWAP_SIZE_GB=0
  SOURCE_PVS=()
  SOURCE_DATA_PARTS=()
  SOURCE_DATA_FS_TYPES=()
  # Parse scan output line-by-line (no eval)
  while IFS='=' read -r key val; do
    # strip the surrounding single quotes from val if present
    val=${val#\'}
    val=${val%\'}
    case "$key" in
      has_root) SOURCE_HAS_ROOT="$val" ;;
      has_lvm) SOURCE_HAS_LVM="$val" ;;
      has_swap) SOURCE_HAS_SWAP="$val" ;;
      has_data) SOURCE_HAS_DATA="$val" ;;
      root_dev) SOURCE_ROOT_DEV="$val" ;;
      root_size_gb) SOURCE_ROOT_SIZE_GB="$val" ;;
      swap_size_gb) SOURCE_SWAP_SIZE_GB="$val" ;;
      pvs)
        if [ -n "$val" ]; then
          # split space-separated PVs into array
          IFS=' ' read -r -a SOURCE_PVS <<< "$val"
        else
          SOURCE_PVS=()
        fi
        ;;
      data_parts)
        if [ -n "$val" ]; then
          IFS=' ' read -r -a SOURCE_DATA_PARTS <<< "$val"
        else
          SOURCE_DATA_PARTS=()
        fi
        ;;
      data_fs_types)
        if [ -n "$val" ]; then
          IFS=' ' read -r -a SOURCE_DATA_FS_TYPES <<< "$val"
        else
          SOURCE_DATA_FS_TYPES=()
        fi
        ;;
      mountpoints)
        # currently ignored; kept for future use
        ;;
      *)
        log_message "detect_source_type: unknown key from scan_disk_usage: ${key}"
        ;;
    esac
  done < <(scan_disk_usage "${SOURCE_DISK}")

  log_message "Detection results: root=${SOURCE_HAS_ROOT}, lvm=${SOURCE_HAS_LVM}, data=${SOURCE_HAS_DATA}, root_dev=${SOURCE_ROOT_DEV}, root_size_gb=${SOURCE_ROOT_SIZE_GB}"

  if [ "${SOURCE_HAS_LVM}" = true ]; then
    readarray -t DETECTED_VGS < <(detect_vgs_on_disk "${SOURCE_DISK}")
    if [ "${#DETECTED_VGS[@]}" -gt 0 ]; then
      VG_NAME="${DETECTED_VGS[0]}"
      log_message "Detected primary VG: ${VG_NAME}"
    fi
  fi

  if [ "${SOURCE_HAS_ROOT}" = true ] && [ "${SOURCE_HAS_LVM}" = true ]; then
    MIGRATION_TYPE="full-disk"
  elif [ "${SOURCE_HAS_ROOT}" = true ]; then
    MIGRATION_TYPE="root-only"
  elif [ "${SOURCE_HAS_LVM}" = true ]; then
    MIGRATION_TYPE="lvm-only"
  elif [ "${SOURCE_HAS_DATA}" = true ]; then
    MIGRATION_TYPE="data-clone"
  else
    MIGRATION_TYPE="empty"
  fi
  log_message "Migration type: ${MIGRATION_TYPE}"
}








show_disk_list() {
  echo -e "\n${BOLD}Dispozitive de stocare disponibile:${NC}"
  echo -e "${DIM}(disk-uri fizice: HDD, SSD, NVMe)${NC}\n"

  cache_all_pvs
  echo -e "  ${BOLD}NAME       SIZE   MODEL                          TRAN${NC}"

  while IFS= read -r line; do
    local disk size model tran
    disk=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    tran=$(echo "$line" | awk '{print $NF}')
    model=$(echo "$line" | awk '{$1=""; $2=""; $NF=""; print $0}' | xargs | sed 's/ *$//')
    [ -z "${model}" ] && model="Unknown"
    [ -z "$disk" ] && continue
    [ -b "${disk}" ] || continue

    usage_info=""
    if (lsblk -no MOUNTPOINT "${disk}" 2>/dev/null || true) | grep -xq '^/$'; then
      usage_info="${usage_info}${RED}[Root]${NC} "
    fi
    pv_count=0
    found_vgs=()
    if [ -n "${ALL_PVS_CACHE}" ]; then
      while IFS= read -r pvline; do
        [ -z "${pvline}" ] && continue
        if [[ "${pvline}" =~ ^${disk}(p[0-9]+|[0-9]+)$ ]]; then
          pv_count=$((pv_count + 1))
          vg=$(pvs --noheadings -o vg_name "${pvline}" 2>/dev/null | xargs || true)
          if [ -n "${vg}" ] && [[ ! " ${found_vgs[*]} " =~ " ${vg} " ]]; then
            found_vgs+=("${vg}")
          fi
        fi
      done <<< "${ALL_PVS_CACHE}"
    fi
    if [ "${pv_count}" -gt 0 ]; then
      vg_list=$(IFS=','; echo "${found_vgs[*]}")
      usage_info="${usage_info}${GREEN}[LVM: ${vg_list}]${NC} "
    fi
    mount_count=$( (lsblk -no MOUNTPOINT "${disk}" 2>/dev/null) | grep -c . | tr -d ' ' || true)
    if [ "${mount_count}" -gt 0 ]; then
      usage_info="${usage_info}${YELLOW}[Montat]${NC} "
    fi
    printf "  %-10s %-5s %-30s %-6s %s\n" "${disk}" "${size}" "${model:0:30}" "${tran}" "${usage_info}"
  done < <(lsblk -dn -p -o NAME,SIZE,MODEL,TRAN 2>/dev/null)

#  echo -e "\n${BOLD}Vedere detaliată (cu partiții):${NC}"
#  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE | grep -v loop || true
}

validate_root_size() {
  local size="$1"
  local target_disk_size="$2"

  if ! [[ "${size}" =~ ^[0-9]+$ ]]; then
    print_error "Mărimea root trebuie să fie un număr întreg!"
    return 1
  fi
  if [ "${size}" -lt 10 ]; then
    print_error "Mărimea root trebuie să fie cel puțin 10GB!"
    return 1
  fi
  if [ "${size}" -gt $((target_disk_size - 5)) ]; then
    print_error "Mărimea root (${size}GB) este prea mare pentru disk-ul destinație (${target_disk_size}GB)!"
    print_info "Spațiu disponibil maxim: $((target_disk_size - 5))GB"
    return 1
  fi
  return 0
}

save_migration_metadata() {
  mkdir -p "${BACKUP_DIR}"
  cat > "${METADATA_FILE}" <<EOF
{
  "script_version": "${SCRIPT_VERSION}",
  "migration_date": "$(date -Iseconds)",
  "migration_start": "$(date '+%Y-%m-%d %H:%M:%S')",
  "source_disk": "${SOURCE_DISK}",
  "target_disk": "${TARGET_DISK}",
  "migration_type": "${MIGRATION_TYPE}",
  "boot_mode": "${BOOT_MODE}",
  "source_root_dev": "${SOURCE_ROOT_DEV}",
  "source_root_size_gb": ${SOURCE_ROOT_SIZE_GB:-0},
  "target_root_size_gb": ${TARGET_ROOT_SIZE_GB:-0},
  "source_has_lvm": ${SOURCE_HAS_LVM},
  "source_pvs": [$(printf '"%s",' "${SOURCE_PVS[@]}" | sed 's/,$//')],
  "detected_vgs": [$(printf '"%s",' "${DETECTED_VGS[@]}" | sed 's/,$//')],
  "user": "$(whoami)",
  "hostname": "$(hostname)"
}
EOF
  log_message "Migration metadata saved to ${METADATA_FILE}"
}

check_disk_space() {
  local source_disk="$1"
  local target_disk="$2"

  local source_info target_info
  source_info=$(get_disk_info "${source_disk}")
  target_info=$(get_disk_info "${target_disk}")

  IFS='|' read -r src_size _ _ <<< "${source_info}"
  IFS='|' read -r tgt_size _ _ <<< "${target_info}"

  if [ "${tgt_size}" -lt "${src_size}" ]; then
    print_warning "Disk destinație (${tgt_size}GB) este mai mic decât sursa (${src_size}GB)!"
    if [ "${SOURCE_HAS_ROOT}" = true ]; then
      local used_space_gb
      used_space_gb=$(df --block-size=1G "${SOURCE_ROOT_DEV}" 2>/dev/null | awk 'NR==2 {print $3}' || echo 0)
      if [ "${tgt_size}" -gt "${used_space_gb}" ]; then
        print_info "Dar spațiu folosit (${used_space_gb}GB) încape pe destinație"
        return 0
      else
        print_error "Spațiu folosit (${used_space_gb}GB) NU încape pe destinație!"
        return 1
      fi
    fi
  else
    print_success "Disk destinație (${tgt_size}GB) >= sursă (${src_size}GB) ✓"
  fi
  return 0
}

generate_migration_plan() {
  log_message "Generating migration plan for type: ${MIGRATION_TYPE}"
  echo -e "\n${CYAN}${BOLD}╔════════════════════ PLAN MIGRARE (Analiză) ════════════════════╗${NC}"

  local disk_info
  disk_info=$(get_disk_info "${SOURCE_DISK}")
  IFS='|' read -r src_size src_model src_tran <<< "${disk_info}"
  echo -e "${BOLD}Disk SURSĂ:${NC} ${SOURCE_DISK}"
  echo -e "  Mărime: ${BOLD}${src_size} GB${NC}"
  echo -e "  Model: ${src_model}"
  echo -e "  Transport: ${src_tran}\n"

  echo -e "${BOLD}Conținut disk sursă:${NC}"
  [ "${SOURCE_HAS_ROOT}" = true ] && echo -e "  ${RED}▸${NC} Root filesystem: ${SOURCE_ROOT_DEV} (${SOURCE_ROOT_SIZE_GB} GB)"
  if [ "${SOURCE_HAS_LVM}" = true ]; then
    echo -e "  ${GREEN}▸${NC} LVM Physical Volumes:"
    for pv in "${SOURCE_PVS[@]}"; do
      local vg pv_size pv_used
      vg=$(pvs --noheadings -o vg_name "${pv}" 2>/dev/null | xargs || echo "?")
      pv_size=$(pvs --noheadings --units g -o pv_size "${pv}" 2>/dev/null | xargs || echo "?")
      pv_used=$(pvs --noheadings --units g -o pv_used "${pv}" 2>/dev/null | xargs || echo "?")
      echo -e "    • ${pv} → VG '${vg}' (${pv_used} / ${pv_size} folosit)"
    done
    if [ "${#DETECTED_VGS[@]}" -gt 0 ]; then
      echo -e "  ${GREEN}▸${NC} Volume Groups detectate: ${DETECTED_VGS[*]}"
    fi
  fi
  if [ "${SOURCE_HAS_DATA}" = true ] && [ "${#SOURCE_DATA_PARTS[@]}" -gt 0 ]; then
    echo -e "  ${CYAN}▸${NC} Partiții de date detectate:"
    for i in "${!SOURCE_DATA_PARTS[@]}"; do
      echo -e "    • ${SOURCE_DATA_PARTS[$i]} → ${SOURCE_DATA_FS_TYPES[$i]:-?}"
    done
  fi
  [ "${SOURCE_SWAP_SIZE_GB}" -gt 0 ] && echo -e "  ${YELLOW}▸${NC} Swap: ${SOURCE_SWAP_SIZE_GB} GB"

  disk_info=$(get_disk_info "${TARGET_DISK}")
  IFS='|' read -r tgt_size tgt_model tgt_tran <<< "${disk_info}"
  echo -e "\n${BOLD}Disk DESTINAȚIE:${NC} ${TARGET_DISK}"
  echo -e "  Mărime: ${BOLD}${tgt_size} GB${NC}"
  echo -e "  Model: ${tgt_model}"
  echo -e "  Transport: ${tgt_tran}"
  echo -e "  ${RED}${BOLD}⚠ VA FI ȘTERS COMPLET!${NC}\n"

  echo -e "${BOLD}Tip migrare detectat:${NC} ${MAGENTA}${BOLD}$(echo "${MIGRATION_TYPE}" | tr '[:lower:]' '[:upper:]')${NC}\n"
  case "${MIGRATION_TYPE}" in
    lvm-only)
      echo -e "${DIM}Disk-ul sursă conține doar LVM Physical Volume(s).${NC}"
      echo -e "${DIM}Migrare PV→PV (poate fi online).${NC}\n"
      echo -e "${BOLD}Pași:${NC}"
      echo "  1. Creare partiție LVM pe ${TARGET_DISK}"
      echo "  2. pvcreate pe noua partiție"
      echo "  3. vgextend pentru adăugare în VG"
      echo "  4. pvmove (poate dura ore)"
      echo "  5. vgreduce pe PV vechi"
      ;;
    root-only)
      echo -e "${DIM}Disk-ul sursă conține root filesystem (fără LVM).${NC}"
      echo -e "${DIM}Migrare root + grub.${NC}\n"
      echo -e "${BOLD}Pași:${NC}"
      echo "  1. Creare partiții pe ${TARGET_DISK} (root, swap, ESP/extra)"
      echo "  2. Formatare partiții"
      echo "  3. rsync sistem de fișiere"
      echo "  4. Copiere /etc/default/grub"
      echo "  5. Instalare GRUB (UEFI/BIOS)"
      echo "  6. Actualizare /etc/fstab (atomic)"
      echo "  7. update-initramfs"
      ;;
    full-disk)
      echo -e "${DIM}Disk-ul sursă conține root + LVM.${NC}"
      echo -e "${DIM}Migrare completă: root + LVM.${NC}\n"
      echo -e "${BOLD}Pași:${NC}"
      echo "  1. Creare partiții pe ${TARGET_DISK}"
      echo "  2. Formatare & rsync root"
      echo "  3. Copiere /etc/default/grub"
      echo "  4. Instalare GRUB"
      echo "  5. pvcreate + vgextend"
      echo "  6. pvmove"
      echo "  7. Actualizare fstab (atomic) & initramfs"
      ;;
    data-clone)
      local fs_list="${SOURCE_DATA_FS_TYPES[*]:-necunoscute}"
      echo -e "${DIM}Disc-ul sursă conține partiții de date (${fs_list}).${NC}"
      echo -e "${DIM}Clonare sector-by-sector cu 'dd'. Sistemul de boot nu este modificat.${NC}\n"
      echo -e "${BOLD}Pași:${NC}"
      echo "  1. Demontare partiții sursă și destinație (dacă sunt montate)"
      echo "  2. Clonare sector-by-sector: dd if=${SOURCE_DISK} of=${TARGET_DISK} bs=4M"
      echo "  3. sync — sincronizare buffere"
      echo "  4. Verificare NTFS cu ntfsfix (dacă partiții NTFS)"
      ;;
    empty)
      print_warning "Disk sursă pare gol sau neformatat. Verifică selecția!"
      ;;
  esac

  echo -e "\n${BOLD}Avertismente:${NC}"
  if [ "${MIGRATION_TYPE}" = "lvm-only" ]; then
    echo "  ⚠ pvmove poate dura ore întregi; NU întrerupe!"
    echo "  ✔ Serverul poate rămâne pornit în timpul migrării."
  elif [ "${MIGRATION_TYPE}" = "data-clone" ]; then
    echo "  ⚠ Clonarea unui disc mare (4TB) poate dura 2-6 ore; NU întrerupe!"
    echo "  ⚠ TOATE datele de pe discul destinație (${TARGET_DISK}) vor fi ȘTERSE."
    echo "  ✔ Discul sursă (${SOURCE_DISK}) nu va fi modificat."
  else
    echo "  ⚠ După migrare: oprește serverul și înlocuiește fizic discul."
    echo "  ⚠ Testează boot-ul după înlocuire!"
  fi

  echo -e "\n${BOLD}Validare spațiu:${NC}"
  check_disk_space "${SOURCE_DISK}" "${TARGET_DISK}" || return 1
  return 0
}

show_dry_run() {
  echo -e "\n${MAGENTA}${BOLD}╔════════════════════ DRY-RUN (comenzi ce vor fi rulate) ════════════════════╗${NC}"
  DRY_RUN_MODE=true
  case "${MIGRATION_TYPE}" in
    lvm-only) show_dry_run_lvm ;;
    root-only|full-disk) show_dry_run_root ;;
    data-clone) show_dry_run_data ;;
  esac
  echo -e "\n${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
  DRY_RUN_MODE=false
}

show_dry_run_lvm() {
  print_dry_run "Comenzi pentru migrare LVM PV:"
  log_command parted -s "${TARGET_DISK}" mklabel gpt || true
  log_command parted -s "${TARGET_DISK}" mkpart primary 1MiB 100% || true
  log_command parted -s "${TARGET_DISK}" set 1 lvm on || true
  local target_part; target_part=$(get_part_name "${TARGET_DISK}" 1)
  log_command pvcreate -ff -y "${target_part}" || true
  for pv in "${SOURCE_PVS[@]}"; do
    local vg; vg=$(pvs --noheadings -o vg_name "${pv}" 2>/dev/null | xargs)
    log_command vgextend "${vg}" "${target_part}" || true
    log_command pvmove -i 5 "${pv}" "${target_part}" || true
    log_command vgreduce "${vg}" "${pv}" || true
  done
}

show_dry_run_root() {
  print_dry_run "Comenzi pentru migrare root disk:"
  log_command parted -s "${TARGET_DISK}" mklabel gpt || true
  local root_size="${TARGET_ROOT_SIZE_GB:-${SOURCE_ROOT_SIZE_GB:-37}}"
  local swap_size="${SOURCE_SWAP_SIZE_GB:-1}"
  if [ "${root_size}" -lt 10 ]; then root_size=10; fi
  if [ "${swap_size}" -lt 1 ]; then swap_size=1; fi

  if [ "${BOOT_MODE}" = "UEFI" ]; then
    log_command parted -s "${TARGET_DISK}" mkpart primary ext4 1MiB "${root_size}GiB" || true
    log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${root_size}GiB" "$((root_size + swap_size))GiB" || true
    log_command parted -s "${TARGET_DISK}" mkpart ESP fat32 "$((root_size + swap_size))GiB" 100% || true
    log_command parted -s "${TARGET_DISK}" set 3 boot on || true
    log_command parted -s "${TARGET_DISK}" set 3 esp on || true
    log_command mkfs.ext4 -F -L newroot "$(get_part_name "${TARGET_DISK}" 1)" || true
    log_command mkswap -f -L newswap "$(get_part_name "${TARGET_DISK}" 2)" || true
    log_command mkfs.fat -F32 -n EFI "$(get_part_name "${TARGET_DISK}" 3)" || true
  else
    log_command parted -s "${TARGET_DISK}" mkpart primary 1MiB 2MiB || true
    log_command parted -s "${TARGET_DISK}" set 1 bios_grub on || true
    log_command parted -s "${TARGET_DISK}" mkpart primary ext4 2MiB "${root_size}GiB" || true
    log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${root_size}GiB" "$((root_size + swap_size))GiB" || true
    log_command parted -s "${TARGET_DISK}" mkpart primary "$((root_size + swap_size))GiB" 100% || true
    log_command parted -s "${TARGET_DISK}" set 4 lvm on || true
    log_command mkfs.ext4 -F -L newroot "$(get_part_name "${TARGET_DISK}" 2)" || true
  fi

  local rsync_excludes=(--partial --info=progress2 --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile)
  if findmnt -no TARGET /home >/dev/null 2>&1; then
    rsync_excludes+=(--exclude=/home/*)
  fi
  log_command rsync -aAXH "${rsync_excludes[@]}" / /mnt/newroot || true
  log_command cp /etc/default/grub /mnt/newroot/etc/default/grub || true
  if [ "${BOOT_MODE}" = "UEFI" ]; then
    log_command grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck --no-nvram || true
  else
    log_command grub-install --target=i386-pc "${TARGET_DISK}" || true
  fi
  log_command awk 'BEGIN{print "fstab update (dry-run)"}' /mnt/newroot/etc/fstab || true
}

show_dry_run_data() {
  print_dry_run "Comenzi pentru clonare disc de date (NTFS/exFAT/etc):"
  # Unmount source partitions
  local part
  while IFS= read -r part; do
    log_command umount "${part}" || true
  done < <(lsblk -no PATH,TYPE "${SOURCE_DISK}" 2>/dev/null | awk '$2=="part" {print $1}')
  # Unmount target partitions
  while IFS= read -r part; do
    log_command umount "${part}" || true
  done < <(lsblk -no PATH,TYPE "${TARGET_DISK}" 2>/dev/null | awk '$2=="part" {print $1}')
  # Sector-by-sector clone
  log_command dd if="${SOURCE_DISK}" of="${TARGET_DISK}" bs=4M conv=sync,noerror status=progress || true
  log_command sync || true
  # ntfsfix on first NTFS partition (example)
  local tgt_part1; tgt_part1=$(get_part_name "${TARGET_DISK}" 1)
  log_command ntfsfix -d "${tgt_part1}" || true
}

# ── DD with live progress bar ─────────────────────────────────────────────────
# run_dd_with_progress <src_disk> <dst_disk> <total_bytes>
# Uses pv if available; otherwise monitors /proc/<pid>/io with a custom progress bar.
run_dd_with_progress() {
  local src="$1" dst="$2" total_bytes="${3:-0}"
  local start_ts; start_ts=$(date +%s)

  # ── Option A: pv is installed ──────────────────────────────────────────────
  if command -v pv >/dev/null 2>&1; then
    print_info "pv detectat — se folosește pentru progress bar detaliat."
    ( set -o pipefail
      pv -pterbs "${total_bytes}" -N " Clonare disc" "${src}" | \
        dd of="${dst}" bs=4M conv=noerror,sync 2>>"${LOG_FILE}"
    )
    local rc=$?
    local elapsed=$(( $(date +%s) - start_ts ))
    if [ "${elapsed}" -gt 0 ] && [ "${total_bytes}" -gt 0 ]; then
      local avg_mb=$(( total_bytes / elapsed / 1048576 ))
      print_success "Clonare completă!  Viteză medie: ${avg_mb} MB/s  |  Timp total: $(seconds_to_hms "${elapsed}")"
    fi
    return "${rc}"
  fi

  # ── Option B: custom monitor via /proc/<pid>/io ────────────────────────────
  local dd_log; dd_log=$(mktemp /tmp/dd-progress-XXXXXX)
  # dd writes progress to stderr; we capture it so it does not clutter the terminal
  dd if="${src}" of="${dst}" bs=4M conv=sync,noerror status=progress 2>"${dd_log}" &
  local dd_pid=$!
  log_message "dd started: PID=${dd_pid} src=${src} dst=${dst} total_bytes=${total_bytes}"

  echo ""
  while kill -0 "${dd_pid}" 2>/dev/null; do
    sleep 1

    local now; now=$(date +%s)
    local elapsed=$(( now - start_ts ))
    local elapsed_str; elapsed_str=$(seconds_to_hms "${elapsed}")

    # Primary: read bytes written from /proc/<pid>/io (most accurate)
    local bytes_done=0
    if [ -e "/proc/${dd_pid}/io" ] && [ -r "/proc/${dd_pid}/io" ]; then
      bytes_done=$(awk '/^write_bytes:/{print $2}' "/proc/${dd_pid}/io" 2>/dev/null || echo 0)
    fi
    # Fallback: parse last line of dd's status output
    if ! [[ "${bytes_done}" =~ ^[0-9]+$ ]] || [ "${bytes_done}" -eq 0 ]; then
      local last_line
      last_line=$(tr '\r' '\n' < "${dd_log}" 2>/dev/null | grep -oP '^\d+.*' | tail -1 || echo "")
      bytes_done=$(echo "${last_line}" | grep -oP '^\d+' || echo 0)
      [[ "${bytes_done}" =~ ^[0-9]+$ ]] || bytes_done=0
    fi

    if [ "${bytes_done}" -gt 0 ] && [ "${total_bytes}" -gt 0 ]; then
      local pct=$(( bytes_done * 100 / total_bytes ))
      local speed_bps=0 speed_mb=0 eta_str="--:--:--"
      [ "${elapsed}" -gt 0 ] && speed_bps=$(( bytes_done / elapsed ))
      [ "${speed_bps}" -gt 0 ] && speed_mb=$(( speed_bps / 1048576 ))
      if [ "${speed_bps}" -gt 0 ]; then
        local remaining=$(( total_bytes - bytes_done ))
        [ "${remaining}" -lt 0 ] && remaining=0
        eta_str=$(seconds_to_hms $(( remaining / speed_bps )))
      fi
      draw_transfer_progress "${pct}" "${speed_mb}" "${elapsed_str}" "${eta_str}"
    else
      printf "\r  ⏱  Timp scurs: %s  (așteptare progres...)" "${elapsed_str}"
    fi
  done

  wait "${dd_pid}"
  local rc=$?
  printf "\n"

  # Append dd log to main log
  cat "${dd_log}" >> "${LOG_FILE}" 2>/dev/null || true
  rm -f "${dd_log}"

  local elapsed_final=$(( $(date +%s) - start_ts ))
  log_message "dd completed in ${elapsed_final}s (exit: ${rc})"
  if [ "${elapsed_final}" -gt 0 ] && [ "${total_bytes}" -gt 0 ]; then
    local avg_mb=$(( total_bytes / elapsed_final / 1048576 ))
    print_info "Viteză medie: ${avg_mb} MB/s  |  Timp total dd: $(seconds_to_hms "${elapsed_final}")"
  fi
  return "${rc}"
}

migrate_data_clone() {
  print_info "Începe clonare disc de date (sector-by-sector cu dd)..."

  local src_bytes tgt_bytes
  src_bytes=$(lsblk -bdn -o SIZE "${SOURCE_DISK}" 2>/dev/null || echo 0)
  tgt_bytes=$(lsblk -bdn -o SIZE "${TARGET_DISK}" 2>/dev/null || echo 0)
  if ! [[ "${src_bytes}" =~ ^[0-9]+$ ]]; then src_bytes=0; fi
  if ! [[ "${tgt_bytes}" =~ ^[0-9]+$ ]]; then tgt_bytes=0; fi

  local src_gb tgt_gb
  src_gb=$(( src_bytes / 1024 / 1024 / 1024 ))
  tgt_gb=$(( tgt_bytes / 1024 / 1024 / 1024 ))

  if [ "${tgt_bytes}" -lt "${src_bytes}" ]; then
    print_error "Discul destinație (${tgt_gb}GB) este mai mic decât sursa (${src_gb}GB)!"
    print_error "Clonarea sector-by-sector necesită disc destinație >= sursă."
    return 1
  fi

  if [ "${tgt_bytes}" -gt "${src_bytes}" ]; then
    print_info "Discul destinație (${tgt_gb}GB) > sursă (${src_gb}GB)."
    print_info "Spațiul extra (~$((tgt_gb - src_gb))GB) nu va fi utilizat automat după clonare."
  fi

  # --- Step: unmount partitions ---
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Demontare partiții sursă și destinație"

  local unmount_ok=true disk
  for disk in "${SOURCE_DISK}" "${TARGET_DISK}"; do
    while read -r part; do
      [ -z "${part}" ] && continue
      local mp
      mp=$(findmnt -no TARGET "${part}" 2>/dev/null || true)
      if [ -n "${mp}" ]; then
        print_info "Demontare ${part} (montat la ${mp})..."
        if ! umount "${part}" 2>/dev/null; then
          if ! umount -l "${part}" 2>/dev/null; then
            print_warning "Nu am putut demonta ${part} de la ${mp}. Verifică dacă este în uz."
            unmount_ok=false
          fi
        fi
      fi
    done < <(lsblk -no PATH,TYPE "${disk}" 2>/dev/null | awk '$2=="part" {print $1}')
  done

  if [ "${unmount_ok}" = false ]; then
    print_warning "Unele partiții nu au putut fi demontate. Continuarea poate duce la date corupte."
    if ! confirm_action "Continui oricum (pe propriul risc)?" "no"; then
      return 1
    fi
  else
    print_success "Toate partițiile au fost demontate."
  fi

  udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
  sleep 1

  # --- Step: dd clone ---
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Clonare disc de date (dd sector-by-sector)"
  print_warning "Clonarea unui disc de ${src_gb}GB poate dura câteva ore (4TB ≈ 2-6h)!"
  print_info "Se monitorizează progresul în timp real cu progress bar + ETA."

  if ! run_dd_with_progress "${SOURCE_DISK}" "${TARGET_DISK}" "${src_bytes}"; then
    print_error "Clonare dd a eșuat!"
    return 1
  fi

  print_info "Sincronizare buffere..."
  log_command sync
  print_success "Clonare completă! ${TARGET_DISK} este acum o copie a lui ${SOURCE_DISK}."

  # --- Step: ntfsfix on NTFS partitions ---
  udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
  sleep 2
  log_command partprobe "${TARGET_DISK}" 2>/dev/null || true
  udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
  sleep 1

  if command -v ntfsfix >/dev/null 2>&1; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Verificare și reparare NTFS pe discul clonat"
    local ntfsfix_count=0
    while read -r part; do
      [ -z "${part}" ] && continue
      local fs
      fs=$(blkid -o value -s TYPE "${part}" 2>/dev/null || true)
      if [ "${fs}" = "ntfs" ]; then
        print_info "ntfsfix -d ${part} (marchează partiția NTFS ca curată)..."
        log_command ntfsfix -d "${part}" || print_warning "ntfsfix a returnat o eroare pentru ${part} (poate fi ignorat)"
        ntfsfix_count=$((ntfsfix_count + 1))
      fi
    done < <(lsblk -no PATH,TYPE "${TARGET_DISK}" 2>/dev/null | awk '$2=="part" {print $1}')
    if [ "${ntfsfix_count}" -gt 0 ]; then
      print_success "ntfsfix rulat pe ${ntfsfix_count} partiție(i) NTFS."
    else
      print_info "Nu s-au găsit partiții NTFS pe ${TARGET_DISK} după clonare."
    fi
  else
    print_info "ntfsfix nu este instalat. Partiții NTFS vor fi verificate la prima montare în Windows."
  fi

  print_success "Clonare disc de date completă!"
  return 0
}

cleanup_mounts() {
  local mount_point="$1"
  local cleanup_list=("run" "sys" "proc" "dev/pts" "dev")
  print_info "Curățare mount-uri pentru ${mount_point}..."
  for fs in "${cleanup_list[@]}"; do
    local full_path="${mount_point}/${fs}"
    if mountpoint -q "${full_path}" 2>/dev/null; then
      umount "${full_path}" 2>/dev/null || umount -l "${full_path}" 2>/dev/null || {
        print_warning "Nu am putut face umount pentru ${full_path}"
      }
    fi
  done
  if [ "${BOOT_MODE}" = "UEFI" ] && mountpoint -q "${mount_point}/boot/efi" 2>/dev/null; then
    umount "${mount_point}/boot/efi" 2>/dev/null || umount -l "${mount_point}/boot/efi" 2>/dev/null || {
      print_warning "Nu am putut face umount pentru ${mount_point}/boot/efi"
    }
  fi
  if mountpoint -q "${mount_point}" 2>/dev/null; then
    umount "${mount_point}" 2>/dev/null || umount -l "${mount_point}" 2>/dev/null || {
      print_warning "Nu am putut face umount pentru ${mount_point}"
    }
  fi
}

migrate_lvm_pv() {
  print_info "Începe migrare LVM PV..."
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Creare partiție LVM pe disk destinație"
  log_command parted -s "${TARGET_DISK}" mklabel gpt || { print_error "Eroare la creare tabel partiții"; return 1; }
  log_command parted -s "${TARGET_DISK}" mkpart primary 1MiB 100% || { print_error "Eroare la creare partiție"; return 1; }
  log_command parted -s "${TARGET_DISK}" set 1 lvm on || true
  log_command partprobe "${TARGET_DISK}"
  sleep 2
  local target_pv; target_pv=$(get_part_name "${TARGET_DISK}" 1)
  wait_for_dev "${target_pv}" || return 1
  print_success "Device node: ${target_pv}"

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Creare Physical Volume"
  log_command pvcreate -ff -y "${target_pv}" || { print_error "Eroare la pvcreate"; return 1; }
  print_success "PV creat: ${target_pv}"

  for source_pv in "${SOURCE_PVS[@]}"; do
    local vg_name; vg_name=$(pvs --noheadings -o vg_name "${source_pv}" 2>/dev/null | xargs)
    if [ -z "${vg_name}" ]; then print_warning "Nu am putut determina VG pentru ${source_pv}"; continue; fi

    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Extindere VG '${vg_name}'"
    log_command vgextend "${vg_name}" "${target_pv}" || { print_error "Eroare la vgextend"; return 1; }
    print_success "VG '${vg_name}' extins"

    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Mutare date: ${source_pv} → ${target_pv} (pvmove)"
    print_warning "Mutare date - POATE DURA ORE! NU întrerupe procesul!"
    local pvmove_cmd=(pvmove -i 5 "${source_pv}" "${target_pv}")
    {
      printf '%s\n' "#!/usr/bin/env bash"
      printf '%s\n' "# Resume script for LVM migration. DO NOT EDIT."
      printf '%q ' "${pvmove_cmd[@]}"
      echo
    } > "${RESUME_FILE}"
    chmod +x "${RESUME_FILE}"
    print_info "Comanda de reluare a fost salvată în ${RESUME_FILE}"

    if ! log_interactive_command "${pvmove_cmd[@]}"; then
      print_error "pvmove a eșuat!"
      print_warning "Poți relua manual cu: ${pvmove_cmd[*]}"
      print_warning "Sau poți rula scriptul cu --resume: sudo $0 --resume"
      return 1
    fi

    print_success "pvmove complet pentru ${source_pv}!"
    rm -f "${RESUME_FILE}"

    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Eliminare PV vechi din VG"
    log_command vgreduce "${vg_name}" "${source_pv}" || print_warning "vgreduce a eșuat; verifică manual"
    print_success "PV ${source_pv} eliminat din VG '${vg_name}'"
  done

  print_success "Migrare LVM completă!"
  return 0
}

















migrate_root_disk() {
  print_info "Începe migrare root disk..."
  # requested sizes (GiB)
  local root_size_gib="${TARGET_ROOT_SIZE_GB:-${SOURCE_ROOT_SIZE_GB:-37}}"
  local swap_size_gib="${SOURCE_SWAP_SIZE_GB:-1}"
  if [ "${root_size_gib}" -lt 10 ]; then root_size_gib=10; fi
  if [ "${swap_size_gib}" -lt 1 ]; then swap_size_gib=1; fi

  # convert to MiB (1 GiB = 1024 MiB)
  local root_size_mib=$(( root_size_gib * 1024 ))
  local swap_size_mib=$(( swap_size_gib * 1024 ))

  # get disk size in bytes (disk only)
  local disk_size_bytes
  disk_size_bytes=$(lsblk -bdn -o SIZE "${TARGET_DISK}" 2>/dev/null || echo "")
  if ! [[ "${disk_size_bytes}" =~ ^[0-9]+$ ]]; then
    disk_size_bytes=$(lsblk -bn -o SIZE "${TARGET_DISK}" 2>/dev/null | head -n1 | tr -d '[:space:]' || echo "")
  fi
  if ! [[ "${disk_size_bytes}" =~ ^[0-9]+$ ]] || [ -z "${disk_size_bytes}" ]; then
    print_error "Nu am putut determina mărimea discului ${TARGET_DISK}."
    return 1
  fi
  local disk_size_mib=$(( disk_size_bytes / 1024 / 1024 ))

  print_info "Disk ${TARGET_DISK}: ${disk_size_mib} MiB (~$((disk_size_mib/1024)) GiB)"
  print_info "Plan: root=${root_size_gib}GiB (${root_size_mib}MiB), swap=${swap_size_gib}GiB (${swap_size_mib}MiB)"

  # adjust root automatically if necessary (leave small slack)
  local slack_mib=8
  local max_root_mib=$(( disk_size_mib - swap_size_mib - slack_mib - 1 ))
  if [ "${max_root_mib}" -lt 0 ]; then
    print_error "Spațiu insuficient pe ${TARGET_DISK} pentru swap (${swap_size_gib}GiB)."
    return 1
  fi
  if [ "${root_size_mib}" -gt "${max_root_mib}" ]; then
    local old_root_gib="${root_size_gib}"
    local new_root_gib=$(( max_root_mib / 1024 ))
    if [ "${new_root_gib}" -lt 10 ]; then new_root_gib=10; fi
    root_size_gib="${new_root_gib}"
    root_size_mib=$(( root_size_gib * 1024 ))
    print_warning "Root solicitat (${old_root_gib}GiB) nu încape; ajustat la ${root_size_gib}GiB pentru a încăpea cu swap (${swap_size_gib}GiB)."
  fi

  # partition endpoints in MiB
  local root_start_mib=1
  local root_end_mib=$(( root_start_mib + root_size_mib ))
  local swap_start_mib="${root_end_mib}"
  local swap_end_mib=$(( swap_start_mib + swap_size_mib ))
  local esp_start_mib="${swap_end_mib}"
  local esp_end_mib="${disk_size_mib}"

  if [ "${esp_end_mib}" -le "${esp_start_mib}" ]; then
    print_error "Nu există spațiu pentru ESP după swap. Ajustează root/swap."
    return 1
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Recreare completă partiții pe disk destinație (DESTRUCTIV)"
  print_warning "Se va șterge complet ${TARGET_DISK} și se vor recrea partițiile."
  log_message "Recreating partition table on ${TARGET_DISK}: root=${root_size_gib}GiB swap=${swap_size_gib}GiB boot_mode=${BOOT_MODE}"

  # write fresh GPT and create partitions with precise MiB endpoints
  if ! log_command parted -s "${TARGET_DISK}" mklabel gpt; then
    print_error "Eroare la scriere tabel partitii (mklabel gpt) pe ${TARGET_DISK}"
    return 1
  fi

  if [ "${BOOT_MODE}" = "UEFI" ]; then
    if ! log_command parted -s "${TARGET_DISK}" mkpart primary ext4 "${root_start_mib}MiB" "${root_end_mib}MiB"; then
      print_error "Eroare la creare partiție root (parted)"
      return 1
    fi
    if ! log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${swap_start_mib}MiB" "${swap_end_mib}MiB"; then
      print_error "Eroare la creare partiție swap (parted)"
      return 1
    fi
    if ! log_command parted -s "${TARGET_DISK}" mkpart ESP fat32 "${esp_start_mib}MiB" "${esp_end_mib}MiB"; then
      print_error "Eroare la creare partiție ESP (parted)"
      return 1
    fi
    log_command parted -s "${TARGET_DISK}" set 3 boot on || true
    log_command parted -s "${TARGET_DISK}" set 3 esp on || true

    TARGET_ROOT="$(get_part_name "${TARGET_DISK}" 1)"
    TARGET_SWAP="$(get_part_name "${TARGET_DISK}" 2)"
    TARGET_EXTRA="$(get_part_name "${TARGET_DISK}" 3)"
  else
    if ! log_command parted -s "${TARGET_DISK}" mkpart primary 1MiB 2MiB; then
      print_error "Eroare la creare bios_grub placeholder"
      return 1
    fi
    log_command parted -s "${TARGET_DISK}" set 1 bios_grub on || true
    if ! log_command parted -s "${TARGET_DISK}" mkpart primary ext4 2MiB "${root_end_mib}MiB"; then
      print_error "Eroare la creare partiție root (BIOS)"
      return 1
    fi
    if ! log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${swap_start_mib}MiB" "${swap_end_mib}MiB"; then
      print_error "Eroare la creare partiție swap (BIOS)"
      return 1
    fi
    if ! log_command parted -s "${TARGET_DISK}" mkpart primary "${esp_start_mib}MiB" "${esp_end_mib}MiB"; then
      print_error "Eroare la creare partiție extra (BIOS)"
      return 1
    fi
    log_command parted -s "${TARGET_DISK}" set 4 lvm on || true

    TARGET_ROOT="$(get_part_name "${TARGET_DISK}" 2)"
    TARGET_SWAP="$(get_part_name "${TARGET_DISK}" 3)"
    TARGET_EXTRA="$(get_part_name "${TARGET_DISK}" 4)"
  fi

  # force reread and udev settle
  log_command partprobe "${TARGET_DISK}"
  log_command blockdev --rereadpt "${TARGET_DISK}" || true
  udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
  sleep 1

  # robust wait for partition nodes (USB may be slow)
  for part in "${TARGET_ROOT}" "${TARGET_SWAP}" "${TARGET_EXTRA}"; do
    [ -z "${part}" ] && continue
    local elapsed=0 per_part_timeout=120
    print_info "Aștept device node '${part}' (timeout: ${per_part_timeout}s)..."
    while [ ! -b "${part}" ] && [ "${elapsed}" -lt "${per_part_timeout}" ]; do
      sleep 1
      elapsed=$((elapsed + 1))
      if [ $((elapsed % 10)) -eq 0 ]; then
        blockdev --rereadpt "${TARGET_DISK}" 2>/dev/null || true
        partprobe "${TARGET_DISK}" 2>/dev/null || true
      fi
      udevadm settle --timeout="${UDEV_SETTLE_TIMEOUT}" 2>/dev/null || true
    done
    if [ -b "${part}" ]; then
      print_success "Device '${part}' este disponibil."
    else
      print_error "Timeout! Device '${part}' nu a apărut după ${per_part_timeout}s."
      return 1
    fi
  done

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Formatare partiții"
  log_command mkfs.ext4 -F -L newroot "${TARGET_ROOT}" || { print_error "Eroare la formatare root"; return 1; }
  if [ -b "${TARGET_SWAP}" ]; then
    log_command mkswap -f -L newswap "${TARGET_SWAP}" || { print_error "Eroare la configurare swap"; return 1; }
  fi
  if [ "${BOOT_MODE}" = "UEFI" ]; then
    if [ -z "${TARGET_EXTRA}" ]; then
      print_error "TARGET_EXTRA nu este setat pentru UEFI; nu pot formata ESP"
      return 1
    fi
    log_command mkfs.fat -F32 -n EFI "${TARGET_EXTRA}" || { print_error "Eroare la formatare ESP"; return 1; }
  fi
  print_success "Partițiile au fost formatate."

  # mount target and rsync (robust)
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Montare și sincronizare sistem"
  mkdir -p /mnt/newroot
  if ! log_command mount "${TARGET_ROOT}" /mnt/newroot; then
    print_error "Eroare la montare ${TARGET_ROOT}"
    return 1
  fi
  mkdir -p /mnt/newroot/{dev,proc,sys,run,boot,tmp}

  local rsync_excludes_list=(--exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile)
  if findmnt -no TARGET /home >/dev/null 2>&1; then
    print_info "/home este un mountpoint separat, va fi exclus din rsync."
    rsync_excludes_list+=(--exclude=/home/*)
  else
    print_info "/home este pe partiția root, va fi sincronizat."
  fi

  # run rsync and treat exit 24 as non-fatal
  log_message "About to run rsync -> /mnt/newroot"
  local rsync_start_ts; rsync_start_ts=$(date +%s)
  if ! log_interactive_command rsync -aAXH --partial --info=progress2 "${rsync_excludes_list[@]}" / /mnt/newroot; then
    local rsync_exit=$?
    if [ "${rsync_exit}" -eq 24 ]; then
      print_warning "Rsync a raportat fișiere dispărute (exit 24), dar migrarea continuă."
      log_message "Rsync returned 24 - continuing"
    else
      print_error "Eroare la rsync (exit code: ${rsync_exit})"
      cleanup_mounts /mnt/newroot
      return 1
    fi
  fi
  local rsync_elapsed=$(( $(date +%s) - rsync_start_ts ))
  print_success "Sistem sincronizat în $(seconds_to_hms "${rsync_elapsed}")."

  # bind mounts for chroot
  print_info "Montare pseudo-filesystems..."
  local mount_failed=false
  for fs in dev proc sys run; do
    if ! log_command mount --bind "/${fs}" "/mnt/newroot/${fs}"; then
      print_error "Eroare la bind mount /${fs}"
      mount_failed=true
      break
    fi
  done
  if [ "${mount_failed}" = true ]; then
    cleanup_mounts /mnt/newroot
    return 1
  fi
  if [ -d /dev/pts ]; then
    log_command mount --bind /dev/pts /mnt/newroot/dev/pts 2>/dev/null || print_warning "Nu am putut monta /dev/pts (opțional)"
  fi
  print_success "Pseudo-filesystems montate."

  # copy /etc/default/grub if present
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Copiere configurație GRUB"
  if [ -f /etc/default/grub ]; then
    log_command cp /etc/default/grub /mnt/newroot/etc/default/ || true
    print_success "/etc/default/grub copiat."
  else
    print_warning "/etc/default/grub nu există pe sistemul curent; se va folosi configurația implicită."
  fi

  # install GRUB and update initramfs
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Instalare GRUB și update initramfs"
  if [ "${BOOT_MODE}" = "UEFI" ]; then
    if ! chroot /mnt/newroot dpkg -l grub-efi-amd64 2>/dev/null | grep -q '^ii'; then
      print_info "Instalare grub-efi-amd64 în chroot (dacă lipsesc)..."
      chroot /mnt/newroot apt-get update -qq 2>&1 | tee -a "${LOG_FILE}" || true
      chroot /mnt/newroot apt-get install -y grub-efi-amd64 grub-efi-amd64-bin 2>&1 | tee -a "${LOG_FILE}" || print_warning "Nu am putut instala grub-efi în chroot"
    fi
    mkdir -p /mnt/newroot/boot/efi
    if ! log_command mount "${TARGET_EXTRA}" /mnt/newroot/boot/efi; then
      print_error "Eroare la montare ESP"
      cleanup_mounts /mnt/newroot
      return 1
    fi
    if [ -d /boot/efi ] && [ "$(ls -A /boot/efi 2>/dev/null)" ]; then
      log_command rsync -aAXH /boot/efi/ /mnt/newroot/boot/efi/ || true
    fi
    # Dacă TARGET_DISK este USB, folosește --no-nvram pentru a evita erori NVRAM
    # Utilizatorul va trebui să reinstaleze GRUB după mutarea fizică
    NVRAM_FLAG=""
    if [ "${TARGET_IS_USB}" = true ]; then
      NVRAM_FLAG="--no-nvram"
      print_warning "Folosim --no-nvram pentru instalarea GRUB (disc pe USB)"
    fi
    if ! log_command chroot /mnt/newroot grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck "${NVRAM_FLAG}"; then
      print_error "Eroare la instalare GRUB UEFI"
      cleanup_mounts /mnt/newroot
      return 1
    fi
  else
    if ! chroot /mnt/newroot dpkg -l grub-pc 2>/dev/null | grep -q '^ii'; then
      print_info "Instalare grub-pc în chroot (dacă lipsește)..."
      chroot /mnt/newroot apt-get update -qq 2>&1 | tee -a "${LOG_FILE}" || true
      chroot /mnt/newroot apt-get install -y grub-pc grub-pc-bin 2>&1 | tee -a "${LOG_FILE}" || print_warning "Nu am putut instala grub-pc în chroot"
    fi
    if ! log_command chroot /mnt/newroot grub-install --target=i386-pc --recheck "${TARGET_DISK}"; then
      print_error "Eroare la instalare GRUB BIOS"
      cleanup_mounts /mnt/newroot
      return 1
    fi
  fi
  log_command chroot /mnt/newroot update-grub || true
  log_command chroot /mnt/newroot update-initramfs -u -k all || true
  print_success "GRUB instalat și initramfs actualizat."

  # atomic fstab update (reuse existing logic)
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Actualizare /etc/fstab (metodă robustă)"
  local fstab_path="/mnt/newroot/etc/fstab"
  local fstab_temp="${fstab_path}.tmp"
  mkdir -p "${BACKUP_DIR}"
  [ -f "${fstab_path}" ] && cp "${fstab_path}" "${BACKUP_DIR}/fstab.new.backup.$(date +%Y%m%d_%H%M%S)"
  print_info "Backup fstab (din sistemul nou) salvat."

  local new_root_uuid new_swap_uuid new_esp_uuid
  new_root_uuid=$(blkid -s UUID -o value "${TARGET_ROOT}" 2>/dev/null || true)
  new_swap_uuid=$(blkid -s UUID -o value "${TARGET_SWAP}" 2>/dev/null || true)
  if [ "${BOOT_MODE}" = "UEFI" ]; then new_esp_uuid=$(blkid -s UUID -o value "${TARGET_EXTRA}" 2>/dev/null || true); else new_esp_uuid=""; fi
  if [ -z "${new_root_uuid}" ]; then
    print_error "Nu pot obține UUID root."
    cleanup_mounts /mnt/newroot
    return 1
  fi

  awk -v root_uuid="${new_root_uuid}" \
      -v swap_uuid="${new_swap_uuid}" \
      -v esp_uuid="${new_esp_uuid}" \
      -v boot_mode="${BOOT_MODE}" \
      ' /^[[:space:]]*#/ { print; next }
        NF == 0 { print; next }
        ($2 == "/") { $1 = "UUID=" root_uuid; print; next }
        ($3 == "swap") { if (swap_uuid) { $1 = "UUID=" swap_uuid; print; } else { print; } next }
        ($2 == "/boot/efi") {
            if (boot_mode == "UEFI" && esp_uuid) { $1 = "UUID=" esp_uuid; print; }
            next
        }
        { print } ' "${fstab_path}" > "${fstab_temp}"

  # create mountpoints referenced in fstab_temp
  while read -r mp; do
    [ -z "${mp}" ] && continue
    [ "${mp}" = "/" ] && continue
    [ "${mp}" = "swap" ] && continue
    mkdir -p "/mnt/newroot${mp}" 2>/dev/null || true
  done < <(awk 'NF && $1 !~ /^[[:space:]]*#/ {print $2}' "${fstab_temp}" | sort -u)

  print_info "Validare fstab nou generat (dry-run) ..."
  : > "${FSTAB_VALIDATE_LOG}"
  {
    echo "==== FSTAB VALIDATION CONTEXT ===="
    echo "BOOT_MODE=${BOOT_MODE}"
    echo "TARGET_ROOT=${TARGET_ROOT} UUID=${new_root_uuid}"
    echo "TARGET_SWAP=${TARGET_SWAP} UUID=${new_swap_uuid}"
    [ "${BOOT_MODE}" = "UEFI" ] && echo "TARGET_ESP=${TARGET_EXTRA} UUID=${new_esp_uuid}"
    echo "---- fstab.temp ----"
    cat "${fstab_temp}"
    echo "---- chroot lsblk -f ----"
    chroot /mnt/newroot lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT -f || true
    echo "---- chroot blkid ----"
    chroot /mnt/newroot blkid || true
    echo "---- missing UUIDs referenced in fstab.temp (if any) ----"
    fstab_uuids=$(grep -o 'UUID=[^[:space:]]*' "${fstab_temp}" | sed 's/^UUID=//' | sort -u || true)
    known_uuids=$(chroot /mnt/newroot blkid -o value -s UUID | sort -u || true)
    for u in ${fstab_uuids:-}; do
      if ! echo "${known_uuids}" | grep -qx "${u}"; then
        echo "MISSING UUID: ${u}"
      fi
    done
    echo "---- mount -f -a -v -T /etc/fstab.tmp (inside chroot) ----"
  } >> "${FSTAB_VALIDATE_LOG}" 2>&1

  if chroot /mnt/newroot mount -fav -T /etc/fstab.tmp >> "${FSTAB_VALIDATE_LOG}" 2>&1; then
    print_success "Validare fstab OK."
    log_command mv "${fstab_temp}" "${fstab_path}" || print_warning "Nu am putut muta fstab temporar"
    print_success "fstab actualizat atomic."
  else
    print_error "Validarea noului fstab a eșuat! Modificările NU au fost aplicate."
    print_warning "Verifică fișierul de debug: ${FSTAB_VALIDATE_LOG}"
    cleanup_mounts /mnt/newroot
    return 1
  fi

  # optional fsck
  if confirm_action "Dorești să rulezi fsck pe ${TARGET_ROOT} pentru validare (recomandat)?" "yes"; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Validare filesystem cu fsck"
    cleanup_mounts /mnt/newroot
    if log_command e2fsck -f -y "${TARGET_ROOT}"; then
      print_success "fsck a validat filesystem-ul cu succes."
    else
      local fsck_exit=$?
      if [ "${fsck_exit}" -le 1 ]; then
        print_success "fsck completat (exit code: ${fsck_exit} - minor/no errors)"
      else
        print_warning "fsck a returnat exit code ${fsck_exit} - verifică log-ul."
      fi
    fi
    log_command mount "${TARGET_ROOT}" /mnt/newroot || true
  else
    print_info "Validare fsck omisă de utilizator."
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Curățare mount-uri temporare"
  cleanup_mounts /mnt/newroot
  print_success "Mount-uri curățate."

  # LVM pvmove (unchanged)
  if [ "${MIGRATION_TYPE}" = "full-disk" ] && [ "${#SOURCE_PVS[@]}" -gt 0 ]; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Migrare date LVM (pvmove)"
    for source_pv in "${SOURCE_PVS[@]}"; do
      local vg; vg=$(pvs --noheadings -o vg_name "${source_pv}" 2>/dev/null | xargs)
      print_info "pvmove: ${source_pv} → ${TARGET_EXTRA}"
      print_warning "Poate dura ore! NU întrerupe!"
      local pvmove_cmd_full=(pvmove -i 5 "${source_pv}" "${TARGET_EXTRA}")
      {
        printf '%s\n' "#!/usr/bin/env bash"
        printf '%s\n' "# Resume script for LVM migration. DO NOT EDIT."
        printf '%q ' "${pvmove_cmd_full[@]}"
        echo
      } > "${RESUME_FILE}"
      chmod +x "${RESUME_FILE}"
      print_info "Comanda de reluare salvată în ${RESUME_FILE}"
      if ! log_interactive_command "${pvmove_cmd_full[@]}"; then
        print_error "pvmove a eșuat"
        return 1
      fi
      rm -f "${RESUME_FILE}"
      log_command vgreduce "${vg}" "${source_pv}" || print_warning "vgreduce warning"
    done
  fi

  print_success "Migrare root disk complet!"
  return 0
}




















main() {
  for arg in "$@"; do
    case "$arg" in
      --resume) RESUME_MODE=true ;;
      --check) CHECK_MODE=true ;;
      --debug) DEBUG_MODE=true ;;
      --help|-h)
        echo "Usage: $0 [--check] [--resume] [--debug] [--help]"
        echo ""
        echo "  --check   Pre-validate migration without executing (safe dry-run)"
        echo "  --resume  Resume a failed LVM pvmove operation"
        echo "  --debug   Verbose logging and extra diagnostics"
        echo "  --help    Show this help message"
        exit 0
        ;;
    esac
  done

  clear
  print_header
  setup_logging

  if [ "${RESUME_MODE}" = true ]; then
    print_warning "Mod de reluare (RESUME) activat."
    if [ -f "${RESUME_FILE}" ]; then
      print_info "Fișier de reluare găsit: ${RESUME_FILE}"
      echo -e "\n${YELLOW}Comanda salvată este:${NC}"
      cat "${RESUME_FILE}"
      echo ""
      if confirm_action "Dorești să execuți comanda de reluare salvată?" "yes"; then
        log_message "Executing resume script: ${RESUME_FILE}"
        if ! log_interactive_command bash "${RESUME_FILE}"; then
          print_error "Execuția comenzii de reluare a eșuat. Verifică log-ul."
          exit 1
        fi
        print_success "Comanda de reluare a fost executată cu succes."
        rm -f "${RESUME_FILE}"
        print_info "Verifică starea LVM (pvs, vgs) și rulează vgreduce manual dacă este necesar."
        exit 0
      else
        print_info "Reluare anulată de utilizator."
        exit 0
      fi
    else
      print_error "Mod de reluare specificat, dar nu s-a găsit fișierul: ${RESUME_FILE}"
      exit 1
    fi
  fi

  if [ "${EUID}" -ne 0 ]; then print_error "Scriptul trebuie rulat ca root!"; exit 1; fi
  mkdir -p "${BACKUP_DIR}"

  # ── Mode selection menu ────────────────────────────────────────────────────
  select_operation_mode

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Verificare comenzi necesare"
  required_cmds=(parted lsblk rsync mkfs.ext4 mkswap pvcreate vgextend pvmove vgreduce blkid grub-install update-grub mkfs.fat partprobe udevadm pvs vgs lvs findmnt mount umount chroot blockdev df mountpoint awk e2fsck)
  missing=()
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then missing+=("${cmd}"); fi
  done
  
  
  
  
  
  
  
  
  if [ "${#missing[@]}" -ne 0 ]; then
  print_error "Lipsesc comenzile: ${missing[*]}"

  # mapping command -> package (fallback to command name as package)
  declare -A cmd_pkg=(
    [parted]=parted
    [lsblk]=util-linux
    [rsync]=rsync
    [mkfs.ext4]=e2fsprogs
    [mkswap]=util-linux
    [pvcreate]=lvm2
    [vgextend]=lvm2
    [pvmove]=lvm2
    [vgreduce]=lvm2
    [blkid]=util-linux
    [grub-install]=grub-common
    [update-grub]=grub-common
    [mkfs.fat]=dosfstools
    [partprobe]=parted
    [udevadm]=udev
    [pvs]=lvm2
    [vgs]=lvm2
    [lvs]=lvm2
    [findmnt]=util-linux
    [mount]=util-linux
    [umount]=util-linux
    [chroot]=util-linux
    [blockdev]=util-linux
    [df]=coreutils
    [mountpoint]=util-linux
    [awk]=gawk
    [e2fsck]=e2fsprogs
  )

  # build package list (unique)
  pkg_list=()
  for c in "${missing[@]}"; do
    pkg=${cmd_pkg[$c]:-$c}
    if ! printf '%s\n' "${pkg_list[@]}" | grep -qx "${pkg}"; then
      pkg_list+=("${pkg}")
    fi
  done

  # If BOOT_MODE is UEFI, ensure both EFI and BIOS grub packages are present
  if [ "${BOOT_MODE:-}" = "UEFI" ]; then
    for g in grub-efi-amd64 grub-efi-amd64-bin grub-pc grub-pc-bin; do
      if ! printf '%s\n' "${pkg_list[@]}" | grep -qx "${g}"; then
        pkg_list+=("${g}")
      fi
    done
    print_info "Sistem UEFI detectat: voi adăuga implicit pachetele pentru GRUB EFI și GRUB BIOS în lista de instalare."
  fi

  print_info "Pachete candidate pentru instalare: ${pkg_list[*]}"
  print_info "Comenzile ce vor fi instalate corespund pachetelor de mai sus."

  # Respect dry-run mode: doar afișăm ce s-ar rula
  if [ "${DRY_RUN_MODE}" = true ]; then
    print_dry_run apt-get update
    print_dry_run apt-get install -y --no-install-recommends "${pkg_list[@]}"
    print_warning "Dry-run: nu s-au instalat pachetele. Rulează scriptul normal pentru instalare sau instalează manual pachetele."
    exit 1
  fi

  # Interactive prompt to install
  if confirm_action "Dorești să instalez automat pachetele necesare folosind apt (se va rula apt-get update și apt-get install)?"; then
    # update apt index (best-effort)
    print_info "Actualizez indexul APT..."
    if ! log_command apt-get update -qq; then
      print_warning "apt-get update a eșuat; voi încerca instalarea oricum (s-ar putea să eșueze)."
    fi

    print_info "Instalez pachetele: ${pkg_list[*]}"
    # Keep interactive apt by default to allow grub-pc debconf prompts; use DEBIAN_FRONTEND=noninteractive only if you accept automated answers.
    if ! log_command apt-get install -y --no-install-recommends "${pkg_list[@]}"; then
      print_error "Instalarea pachetelor a eșuat. Verifică conexiunea la internet și APT. Comenzile recomandate manual:"
      echo "  sudo apt-get update && sudo apt-get install -y ${pkg_list[*]}"
      exit 1
    fi

    print_success "Pachetele au fost instalate. Relansăm verificarea comenzilor..."
    # re-check availability
    missing=()
    for cmd in "${required_cmds[@]}"; do
      if ! command -v "${cmd}" >/dev/null 2>&1; then missing+=("${cmd}"); fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
      print_error "După instalare încă lipsesc comenzile: ${missing[*]}. Verifică manual care pachet conține comanda respectivă."
      exit 1
    fi
    print_success "Toate comenzile necesare sunt disponibile"
  else
    print_info "Nu s-a instalat nimic. Instalează manual pachetele listate înainte de a continua."
    exit 1
  fi
fi

  
  
  
  
  
  
  
  
  print_success "Toate comenzile necesare sunt disponibile"

  # ── Boot mode detection (only needed for OS migration) ────────────────────
  if [ "${USER_MODE_CHOICE}" != "data-clone" ]; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Detectare mod boot (UEFI / BIOS)"
    if [ -d /sys/firmware/efi ]; then BOOT_MODE="UEFI"; else BOOT_MODE="BIOS"; fi
    print_info "Sistem detectat ca: ${GREEN}${BOLD}${BOOT_MODE}${NC}"
    read -rp "$(echo -e ${CYAN}Confirmi ${BOOT_MODE} sau schimbi? [BIOS/UEFI/ENTER păstrează]: ${NC})" USER_BOOT
    if [[ -n "${USER_BOOT}" && "${USER_BOOT}" =~ ^(BIOS|UEFI)$ ]]; then BOOT_MODE="${USER_BOOT}"; print_warning "Boot mode suprascris: ${BOOT_MODE}"; fi
    print_success "Boot mode: ${BOLD}${BOOT_MODE}${NC}"
  else
    # For data-clone, boot mode is irrelevant; default to BIOS to satisfy any downstream checks
    BOOT_MODE="N/A"
    print_info "Mod clonare disc: detecție UEFI/BIOS omisă."
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Detectare root curent"
  CURRENT_ROOT_DEV=$(findmnt -no SOURCE /)
  if [ -z "${CURRENT_ROOT_DEV}" ]; then print_error "Nu pot detecta root device!"; exit 1; fi
  pkname=$(lsblk -no PKNAME "${CURRENT_ROOT_DEV}" 2>/dev/null || true)
  if [ -n "${pkname}" ]; then CURRENT_ROOT_DISK="/dev/${pkname}"; else CURRENT_ROOT_DISK=$(echo "${CURRENT_ROOT_DEV}" | sed -E 's/p?[0-9]+$//'); fi
  CURRENT_ROOT_DISK=$(readlink -f "${CURRENT_ROOT_DISK}" 2>/dev/null || echo "${CURRENT_ROOT_DISK}")
  print_success "Root curent: ${BOLD}${CURRENT_ROOT_DEV}${NC} pe ${BOLD}${CURRENT_ROOT_DISK}${NC}"

  HOME_SOURCE=$(findmnt -no SOURCE /home 2>/dev/null || true)
  if [ -n "${HOME_SOURCE}" ] && lvs "${HOME_SOURCE}" >/dev/null 2>&1; then
    LV_NAME=$(lvs --noheadings -o lv_name "${HOME_SOURCE}" 2>/dev/null | xargs || true)
    [ -n "${LV_NAME}" ] && print_success "/home pe LVM: ${BOLD}${LV_NAME}${NC}"
  fi

  # select source
  while true; do
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Selectare disk SURSĂ (cel care va fi înlocuit)"
    show_disk_list
    select_disk_from_list SOURCE_DISK "Selectare disk SURSĂ" "false"
    if [ -n "${SOURCE_DISK}" ] && [ -b "${SOURCE_DISK}" ]; then
      SOURCE_DISK=$(readlink -f "${SOURCE_DISK}")
      print_success "Sursă: ${SOURCE_DISK}"
      break
    fi
    print_error "Disk invalid. Încearcă din nou."
  done

  # select target
  while true; do
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Selectare disk DESTINAȚIE (noul disk)"
    show_disk_list
	echo
	echo
    select_disk_from_list TARGET_DISK "Selectare disk DESTINAȚIE (noul disk)" "true"
    if [ -z "${TARGET_DISK}" ] || [ ! -b "${TARGET_DISK}" ]; then
      print_error "Disk invalid sau nimic selectat. Încearcă din nou."
      continue
    fi
    TARGET_DISK=$(readlink -f "${TARGET_DISK}")
    if [ "${SOURCE_DISK}" = "${TARGET_DISK}" ]; then print_error "Sursa și ținta sunt identice."; continue; fi
    if [ "${TARGET_DISK}" = "${CURRENT_ROOT_DISK}" ]; then print_error "Ținta nu poate fi discul root curent."; continue; fi
    print_success "Țintă: ${TARGET_DISK}"
    break
  done

  # Detectare tip migrare ÎNAINTE de avertismentul USB (pentru mesaje contextuale)
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Analiză configurație și tip migrare"
  detect_source_type

  # ── Apply user mode choice override ───────────────────────────────────────
  if [ "${USER_MODE_CHOICE}" = "data-clone" ]; then
    if [ "${MIGRATION_TYPE}" != "data-clone" ]; then
      if [ "${SOURCE_HAS_ROOT}" = true ]; then
        print_warning "Discul sursă conține un sistem de operare, dar modul 'Clonare disc' a fost ales explicit."
        print_info "Se va folosi clonare sector-by-sector (dd). Sistemul de pe sursa NU va fi modificat."
      fi
      MIGRATION_TYPE="data-clone"
    fi
  elif [ "${USER_MODE_CHOICE}" = "os-migration" ] && [ "${MIGRATION_TYPE}" = "data-clone" ]; then
    print_error "Discul sursă nu pare să conțină un sistem de operare detectabil!"
    print_info "Încearcă modul 'Auto-detectare' sau 'Clonare disc de date'."
    exit 1
  fi

  case "${MIGRATION_TYPE}" in
    lvm-only)   print_info "Tip migrare: LVM PV-ONLY" ;;
    root-only)  print_info "Tip migrare: ROOT DISK" ;;
    full-disk)  print_info "Tip migrare: FULL DISK (Root + LVM)" ;;
    data-clone) print_info "Tip migrare: CLONARE DISC DE DATE (${SOURCE_DATA_FS_TYPES[*]:-NTFS/exFAT/ext4})" ;;
    empty)      print_error "Disk sursă pare gol sau fără date detectabile!"; exit 1 ;;
    *)          print_error "Tip migrare necunoscut: ${MIGRATION_TYPE}"; exit 1 ;;
  esac

  # Detectare USB și avertisment (conștient de tipul de migrare)
  TARGET_IS_USB=false
  if lsblk -dno TRAN "${TARGET_DISK}" 2>/dev/null | grep -qE '^usb'; then
    TARGET_IS_USB=true
    print_warning "⚠️  Discul destinație ${TARGET_DISK} este conectat prin USB!"
    if [ "${MIGRATION_TYPE}" = "data-clone" ]; then
      echo -e "${YELLOW}${BOLD}IMPORTANT - Clonare disc de date USB:${NC}"
      echo -e "  Discul sursă ${SOURCE_DISK} va fi clonat sector-by-sector pe ${TARGET_DISK}."
      echo -e "  Discul destinație va fi COMPLET SUPRASCRIS."
      echo -e "  Nu sunt necesari pași suplimentari după clonare (fără GRUB, fără reboot)."
    else
      echo -e "${YELLOW}${BOLD}IMPORTANT:${NC}"
      echo -e "  După ce migrarea se termină, va trebui să:"
      echo -e "  1. Oprești calculatorul complet"
      echo -e "  2. Muți fizic noul SSD intern (în locul celui vechi)"
      echo -e "  3. Bootezi de pe un USB Live Linux"
      echo -e "  4. Reinstalezi GRUB pe noul disc (acum intern):"
      echo -e "     ${CYAN}sudo grub-install /dev/sda && sudo update-grub${NC}"
      echo -e "  5. SAU folosești scriptul generat automat care va fi salvat în ${BACKUP_DIR}"
    fi
    echo ""
    if ! confirm_action "Ai înțeles acești pași și vrei să continui?" "no"; then
      print_info "Operațiune anulată."
      exit 0
    fi
  fi

  if [ "${CHECK_MODE}" = false ]; then
    echo -e "\n${RED}${BOLD}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  [!] AVERTISMENT: TOATE DATELE DE PE ${TARGET_DISK} VOR FI ȘTERSE! [!]           ║${NC}"
    echo -e "${RED}${BOLD}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"
    if ! confirm_action "Confirmă ștergerea COMPLETĂ a ${TARGET_DISK}" "no"; then
      print_info "Anulat."
      exit 0
    fi
  fi

  if [[ "${MIGRATION_TYPE}" == "root-only" || "${MIGRATION_TYPE}" == "full-disk" ]]; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Configurare mărime partiție root"
    local default_root_size=${SOURCE_ROOT_SIZE_GB:-37}
    local target_disk_info target_disk_size
    target_disk_info=$(get_disk_info "${TARGET_DISK}")
    IFS='|' read -r target_disk_size _ _ <<< "${target_disk_info}"

    while true; do
      read -rp "$(echo -e ${CYAN}Introdu mărimea pentru noua partiție root GiB [Default: ${default_root_size}]: ${NC})" user_root_size
      TARGET_ROOT_SIZE_GB=${user_root_size:-$default_root_size}
      if validate_root_size "${TARGET_ROOT_SIZE_GB}" "${target_disk_size}"; then
        print_success "Mărime root destinație: ${BOLD}${TARGET_ROOT_SIZE_GB} GiB${NC}"
        break
      fi
      print_warning "Încearcă din nou cu o valoare validă."
    done
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Generare plan migrare și DRY-RUN"
  generate_migration_plan || { print_error "Eroare la generare plan"; exit 1; }
  if confirm_action "Vrei să vezi planul complet (DRY-RUN) înainte de execuție?" "yes"; then show_dry_run; fi

  if [ "${CHECK_MODE}" = true ]; then
    echo -e "\n${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  ✔ VERIFICARE COMPLETĂ - Migrarea este POSIBILĂ (mod CHECK)                ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"
    print_info "Mod CHECK: Nicio modificare a fost făcută."
    print_info "Pentru a executa migrarea, rulează scriptul fără --check"
    exit 0
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Confirmare finală"
  local src_info2 tgt_info2 src_size tgt_size src_model tgt_model src_tran tgt_tran
  src_info2=$(get_disk_info "${SOURCE_DISK}")
  tgt_info2=$(get_disk_info "${TARGET_DISK}")
  IFS='|' read -r src_size src_model src_tran <<< "${src_info2}"
  IFS='|' read -r tgt_size tgt_model tgt_tran <<< "${tgt_info2}"

  echo -e "\n${YELLOW}${BOLD}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}Rezumat operațiune:${NC}"
  echo -e "  • Sursă: ${RED}${SOURCE_DISK}${NC} (${src_size} GB)"
  echo -e "  • Țintă: ${GREEN}${TARGET_DISK}${NC} (${tgt_size} GB) ${RED}[VA FI ȘTERS!]${NC}"
  echo -e "  • Tip: ${MAGENTA}${MIGRATION_TYPE}${NC}"
  echo -e "  • Boot: ${BOOT_MODE}"
  if [[ "${MIGRATION_TYPE}" == "root-only" || "${MIGRATION_TYPE}" == "full-disk" ]]; then
    echo -e "  • Mărime root destinație: ${BOLD}${TARGET_ROOT_SIZE_GB} GiB${NC}"
  fi
  if [ "${#DETECTED_VGS[@]}" -gt 0 ]; then
    echo -e "  • Volume Groups: ${BOLD}${DETECTED_VGS[*]}${NC}"
  fi
  echo -e "${YELLOW}${BOLD}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"

  if ! confirm_action "Confirmă începerea migrării REALE?" "no"; then
    print_info "Operațiune anulată de utilizator."; exit 0
  fi

  save_migration_metadata
  print_info "Metadata migrare salvată în ${METADATA_FILE}"

  log_message "=== MIGRATION START ==="
  log_command cp /etc/fstab "${BACKUP_DIR}/fstab.original.backup.$(date +%Y%m%d_%H%M%S)" || true

  case "${MIGRATION_TYPE}" in
    lvm-only)
      migrate_lvm_pv || { print_error "Migrare LVM a eșuat!"; log_message "Migration FAILED: lvm-only"; exit 1; }
      ;;
    root-only|full-disk)
      migrate_root_disk || { print_error "Migrare root disk a eșuat!"; log_message "Migration FAILED: root-disk"; exit 1; }
      ;;
    data-clone)
      migrate_data_clone || { print_error "Clonare disc a eșuat!"; log_message "Migration FAILED: data-clone"; exit 1; }
      ;;
  esac

  log_message "=== MIGRATION COMPLETED ==="

  # Generare script de reinstalare GRUB pentru cazul USB (nu pentru data-clone)
  if [ "${MIGRATION_TYPE}" != "lvm-only" ] && [ "${MIGRATION_TYPE}" != "data-clone" ] && [ "${TARGET_IS_USB}" = true ]; then
    print_info "Generare script de reinstalare GRUB pentru discul USB mutat intern..."
    cat > "${BACKUP_DIR}/reinstall-grub-after-move.sh" <<'REINSTALL_EOF'
#!/usr/bin/env bash
# Script generat automat de storage-migrate.sh
# Rulează acest script DUPĂ ce ai mutat fizic noul SSD intern
# Bootează de pe USB Live Linux, apoi rulează:
#   sudo bash /path/to/this/script

set -euo pipefail

echo "=== Reinstalare GRUB după mutarea fizică a discului ==="
echo ""
echo "⚠️  Acest script presupune că noul SSD este acum /dev/sda (primul disc intern)"
echo "⚠️  Verifică cu: lsblk -f"
echo ""
read -rp "Continuă? [y/N]: " response
[[ "$response" =~ ^[Yy]$ ]] || { echo "Anulat."; exit 0; }

NEW_DISK="/dev/sda"  # Ajustează dacă este altceva
ROOT_PART=$(lsblk -nlo NAME,LABEL,FSTYPE "${NEW_DISK}" | awk '$2=="newroot" || $3=="ext4" {print "/dev/"$1; exit}')
EFI_PART=$(lsblk -nlo NAME,FSTYPE "${NEW_DISK}" | awk '$2=="vfat" {print "/dev/"$1; exit}')

[ -z "$ROOT_PART" ] && { echo "Nu am găsit partiția root!"; exit 1; }

echo "Montez $ROOT_PART..."
mkdir -p /mnt/newroot
mount "$ROOT_PART" /mnt/newroot

if [ -n "$EFI_PART" ]; then
  echo "Sistem UEFI detectat. Montez $EFI_PART..."
  mkdir -p /mnt/newroot/boot/efi
  mount "$EFI_PART" /mnt/newroot/boot/efi
fi

for fs in dev proc sys run; do
  mount --bind "/$fs" "/mnt/newroot/$fs"
done

echo "Instalez GRUB pe $NEW_DISK..."
if [ -n "$EFI_PART" ]; then
  chroot /mnt/newroot grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
else
  chroot /mnt/newroot grub-install --target=i386-pc --recheck "$NEW_DISK"
fi

echo "Actualizez configurația GRUB..."
chroot /mnt/newroot update-grub

echo ""
echo "✅ GRUB reinstalat cu succes!"
echo "Poți face reboot acum."

# Cleanup
for fs in run sys proc dev; do
  umount "/mnt/newroot/$fs" 2>/dev/null || true
done
[ -n "$EFI_PART" ] && umount /mnt/newroot/boot/efi 2>/dev/null || true
umount /mnt/newroot 2>/dev/null || true
REINSTALL_EOF

    chmod +x "${BACKUP_DIR}/reinstall-grub-after-move.sh"
    print_success "Script de reinstalare GRUB salvat: ${BACKUP_DIR}/reinstall-grub-after-move.sh"
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Rezumat final"
  echo -e "\n${GREEN}${BOLD}✔ MIGRARE COMPLETATĂ CU SUCCES!${NC}\n"
  echo -e "${CYAN}${BOLD}Rezumat migrare:${NC}"
  echo -e "  • Tip migrare: ${BOLD}${MIGRATION_TYPE}${NC}"
  echo -e "  • Disk sursă: ${BOLD}${SOURCE_DISK}${NC}"
  echo -e "  • Disk destinație: ${BOLD}${TARGET_DISK}${NC}"
  echo -e "  • Boot mode: ${BOLD}${BOOT_MODE}${NC}"
  echo -e "  • Metadata: ${BOLD}${METADATA_FILE}${NC}"
  if [ "${#DETECTED_VGS[@]}" -gt 0 ]; then
    echo -e "  • Volume Groups: ${BOLD}${DETECTED_VGS[*]}${NC}"
  fi
  echo -e "\n${CYAN}Log complet: ${BOLD}${LOG_FILE}${NC}"
  echo -e "Fstab validate log: ${BOLD}${FSTAB_VALIDATE_LOG}${NC}"
  echo -e "Backup-uri: ${BOLD}${BACKUP_DIR}${NC}\n"

  if [ "${MIGRATION_TYPE}" = "data-clone" ]; then
    echo -e "${GREEN}${BOLD}✔ CE FACI MAI DEPARTE (Clonare disc de date):${NC}"
    echo -e "  • Discul ${TARGET_DISK} este acum o copie exactă a lui ${SOURCE_DISK}."
    echo -e "  • Verifică discul clonat: ${DIM}sudo lsblk -f ${TARGET_DISK}${NC}"
    echo -e "  • Montează read-only pentru verificare:"
    echo -e "    ${DIM}sudo mount -o ro $(get_part_name "${TARGET_DISK}" 1) /mnt && ls /mnt${NC}"
    echo ""
    print_warning "Discul sursă ${SOURCE_DISK} nu a fost modificat."
    echo -e "${YELLOW}Verifică integritatea datelor înainte de a folosi discul clonat!${NC}\n"
  elif [ "${MIGRATION_TYPE}" != "lvm-only" ]; then
    echo -e "${RED}${BOLD}⚠ CE FACI MAI DEPARTE :${NC}"
    echo -e "  1) Oprește serverul: ${DIM}sudo poweroff${NC}"
    echo -e "  2) Înlocuiește fizic discul: scoate ${SOURCE_DISK} și pune ${TARGET_DISK} în locul său"
    if [ "${TARGET_IS_USB}" = true ]; then
      echo -e "  3) ${RED}${BOLD}IMPORTANT${NC}: Bootează de pe USB Live Linux"
      echo -e "  4) ${RED}${BOLD}Reinstalează GRUB${NC} folosind scriptul generat:"
      echo -e "     ${CYAN}sudo bash ${BACKUP_DIR}/reinstall-grub-after-move.sh${NC}"
      echo -e "  5) Pornește serverul și verifică boot-ul"
      echo -e "  6) După boot, verifică: ${DIM}df -h; lsblk; mount | grep ' / '${NC}\n"
    else
      echo -e "  3) Pornește serverul și verifică boot-ul"
      echo -e "  4) După boot, verifică: ${DIM}df -h; lsblk; mount | grep ' / '${NC}\n"
    fi
    echo -e "${YELLOW}Nu șterge inca discul ${SOURCE_DISK} nu se stie niciodata :)${NC}\n"
  else
    echo -e "${GREEN}${BOLD}Status LVM final:${NC}"
    pvs -o pv_name,vg_name,pv_size,pv_free,pv_used 2>/dev/null || true
    vgs -o vg_name,vg_size,vg_free 2>/dev/null || true
    echo -e "\n${YELLOW}${BOLD}Pași următori:${NC}"
    echo "  1) Verifică status LVM: pvs && vgs && lvs"
    echo "  2) Verifică /home dacă este pe LVM: df -h /home"
    if [ "${#SOURCE_PVS[@]}" -gt 0 ]; then
      echo "  3) (Opțional) Poți șterge vechiul PV: pvremove ${SOURCE_PVS[*]}"
    fi
  fi

  log_message "Script completed successfully"
  log_message "=========================================="
  echo -e "\n${GREEN}${BOLD}✔ Gata! Succes cu migrarea!${NC}\n"
}

trap 'print_error "Script întrerupt la linia ${LINENO}"; log_message "ERROR at line ${LINENO}"; exit 1' ERR

main "$@"
exit 0