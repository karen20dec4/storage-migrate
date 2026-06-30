#!/usr/bin/env bash
#
# Debian Storage Migration Script V2.9 - debug+fstab validation improvements
# Author: karen20ced4 + Copilot revisions
# Repository: https://github.com/karen20ced4/NVME-Migrate
# Version: 2.9
# Date: 2025-10-27
#
# Scop: migrare disc root si/sau LVM PV intre drive-uri. Include: dry-run, check, resume,
#        robust fstab update, better device detection, resume for pvmove, metadata save.
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.9"
SCRIPT_DATE="2025-10-27"
SCRIPT_AUTHOR="karen20ced4"
SCRIPT_REPO="https://github.com/karen20ced4/NVME-Migrate"

LOG_FILE="/var/log/storage-migrate.log"
DRY_RUN_MODE=false
RESUME_MODE=false
CHECK_MODE=false
DEBUG_MODE=false
BACKUP_DIR="/root/storage-migrate-backups"
RESUME_FILE="${BACKUP_DIR}/lvm-resume.sh"
METADATA_FILE="${BACKUP_DIR}/migration-metadata.json"
FSTAB_VALIDATE_LOG="${BACKUP_DIR}/fstab-validate.log"

# Migration variables
SOURCE_DISK=""
TARGET_DISK=""
MIGRATION_TYPE=""
SOURCE_HAS_ROOT=false
SOURCE_HAS_LVM=false
SOURCE_PVS=()
SOURCE_ROOT_DEV=""
SOURCE_ROOT_SIZE_GB=0
SOURCE_SWAP_SIZE_GB=0
CURRENT_ROOT_DISKS=()

# Target partition variables
TARGET_ROOT=""
TARGET_SWAP=""
TARGET_EXTRA=""   # păstrat pentru compatibilitate (= ESP la UEFI, = LVM la BIOS)
TARGET_ESP=""     # FIX (M3): partiția ESP, separată explicit
TARGET_LVM=""     # FIX (M3): partiția LVM țintă, separată explicit
TARGET_ROOT_SIZE_GB=0

# Non-interactive: sare peste prompt-urile de confirmare (PERICULOS)
ASSUME_YES=false

# Argumente pentru mod complet non-interactiv (gol = mod interactiv pentru acel câmp)
ARG_SOURCE=""
ARG_TARGET=""
ARG_ROOT_SIZE=""
ARG_BOOT_MODE=""

# Dimensiunea ESP (UEFI), în MiB
ESP_SIZE_MIB=1024

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
  if [ "${ASSUME_YES}" = true ]; then
    log_message "AUTO-CONFIRM (--yes): ${prompt}"
    return 0
  fi
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

read_cli_value() {
  local option="$1"
  local value="${2-}"
  if [ -z "${value}" ] || [[ "${value}" == --* ]]; then
    print_error "Lipsește valoarea pentru ${option}." >&2
    exit 1
  fi
  printf "%s" "${value}"
}

add_unique_root_disk() {
  local disk="$1"
  [ -n "${disk}" ] || return 0
  disk=$(readlink -f "${disk}" 2>/dev/null || echo "${disk}")
  local existing
  for existing in "${CURRENT_ROOT_DISKS[@]}"; do
    [ "${existing}" = "${disk}" ] && return 0
  done
  CURRENT_ROOT_DISKS+=("${disk}")
}

get_parent_disk() {
  local dev="$1"
  local cur type pk
  cur=$(readlink -f "${dev}" 2>/dev/null || echo "${dev}")
  while [ -b "${cur}" ]; do
    type=$(lsblk -ndo TYPE "${cur}" 2>/dev/null | head -n1 | xargs || true)
    if [ "${type}" = "disk" ]; then
      printf "%s" "${cur}"
      return 0
    fi
    pk=$(lsblk -ndo PKNAME "${cur}" 2>/dev/null | head -n1 | xargs || true)
    [ -n "${pk}" ] || break
    cur="/dev/${pk}"
  done
  return 1
}

detect_current_root_disks() {
  local root_source="$1"
  local disk pv
  CURRENT_ROOT_DISKS=()

  disk=$(get_parent_disk "${root_source}" 2>/dev/null || true)
  [ -n "${disk}" ] && add_unique_root_disk "${disk}"

  if command -v lvs >/dev/null 2>&1; then
    while IFS= read -r pv; do
      pv="${pv%%(*}"
      pv=$(echo "${pv}" | xargs)
      [ -b "${pv}" ] || continue
      disk=$(get_parent_disk "${pv}" 2>/dev/null || true)
      [ -n "${disk}" ] && add_unique_root_disk "${disk}"
    done < <(lvs --noheadings -o devices "${root_source}" 2>/dev/null | tr ',' '\n' || true)
  fi
}

is_current_root_disk() {
  local candidate="$1"
  local disk
  candidate=$(readlink -f "${candidate}" 2>/dev/null || echo "${candidate}")
  for disk in "${CURRENT_ROOT_DISKS[@]}"; do
    [ "${candidate}" = "${disk}" ] && return 0
  done
  return 1
}

# select_disk_from_list
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
    if [ "${exclude_root}" = "true" ] && is_current_root_disk "${disk}"; then
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
        # FIX: IFS global e $'\n\t', deci ${found_vgs[*]} se unește cu \n (nu spațiu);
        # testul de apartenență trebuie făcut cu IFS=' ' (altfel apar VG-uri duplicate).
        if [ -n "${vg}" ] && ! ( IFS=' '; [[ " ${found_vgs[*]:-} " == *" ${vg} "* ]] ); then
          found_vgs+=("${vg}")
        fi
      fi
    done <<< "${ALL_PVS_CACHE}"
  fi

  printf '%s\n' "${found_vgs[@]}"
}

scan_disk_usage() {
  local disk="$1"
  local has_root=false has_lvm=false has_swap=false
  local -a pvs_found=()
  local -a mountpoints=()
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
  done < <(lsblk -no PATH,TYPE "${disk}" 2>/dev/null | awk '$2=="part" {print $1}')

  # FIX (M1): join cu spațiu EXPLICIT (IFS global e \n\t) și valori încadrate
  # în ghilimele, altfel `eval` din detect_source_type interpretează al doilea
  # cuvânt ca o comandă (ex. pvs=/dev/sda1 /dev/sda2 -> încearcă să execute /dev/sda2).
  local pvs_str mp_str
  pvs_str=$(IFS=' '; printf '%s' "${pvs_found[*]:-}")
  mp_str=$(IFS=' '; printf '%s' "${mountpoints[*]:-}")
  echo "has_root='${has_root}'"
  echo "has_lvm='${has_lvm}'"
  echo "has_swap='${has_swap}'"
  echo "root_dev='${root_dev}'"
  echo "root_size_gb='${root_size_gb}'"
  echo "swap_size_gb='${swap_size_gb}'"
  echo "pvs='${pvs_str}'"
  echo "mountpoints='${mp_str}'"
}

detect_source_type() {
  log_message "Detecting migration type for source: ${SOURCE_DISK}"
  local scan_result
  scan_result=$(scan_disk_usage "${SOURCE_DISK}")
  eval "${scan_result}"

  SOURCE_HAS_ROOT=${has_root}
  SOURCE_HAS_LVM=${has_lvm}
  if [ -n "${pvs:-}" ]; then
    IFS=' ' read -r -a SOURCE_PVS <<< "${pvs}"
  else
    SOURCE_PVS=()
  fi
  SOURCE_ROOT_DEV="${root_dev}"
  SOURCE_ROOT_SIZE_GB="${root_size_gb}"
  SOURCE_SWAP_SIZE_GB="${swap_size_gb}"
  log_message "Detection results: root=${SOURCE_HAS_ROOT}, lvm=${SOURCE_HAS_LVM}"

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
    local disk size model tran usage_info pv_count mount_count vg vg_list pvline
    local -a found_vgs
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
          # FIX: vezi nota din detect_vgs_on_disk - join cu IFS=' ' pentru dedup corect.
          if [ -n "${vg}" ] && ! ( IFS=' '; [[ " ${found_vgs[*]:-} " == *" ${vg} "* ]] ); then
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

  echo -e "\n${BOLD}Vedere detaliată (cu partiții):${NC}"
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE | grep -v loop || true
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
    empty)
      print_warning "Disk sursă pare gol sau neformatat. Verifică selecția!"
      ;;
  esac

  echo -e "\n${BOLD}Avertismente:${NC}"
  if [ "${MIGRATION_TYPE}" = "lvm-only" ]; then
    echo "  ⚠ pvmove poate dura ore întregi; NU întrerupe!"
    echo "  ✔ Serverul poate rămâne pornit în timpul migrării."
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
  log_command wipefs -a "${TARGET_DISK}" || true
  log_command parted -s "${TARGET_DISK}" mklabel gpt || true
  local root_size="${TARGET_ROOT_SIZE_GB:-${SOURCE_ROOT_SIZE_GB:-37}}"
  local swap_size="${SOURCE_SWAP_SIZE_GB:-1}"
  if [ "${root_size}" -lt 10 ]; then root_size=10; fi
  if [ "${swap_size}" -lt 1 ]; then swap_size=1; fi
  local esp_mib=${ESP_SIZE_MIB}
  local root_mib=$(( root_size * 1024 )) swap_mib=$(( swap_size * 1024 ))
  local is_full=false; [ "${MIGRATION_TYPE}" = "full-disk" ] && is_full=true

  if [ "${BOOT_MODE}" = "UEFI" ]; then
    local esp_end=$(( 1 + esp_mib )) root_end swap_end
    root_end=$(( esp_end + root_mib )); swap_end=$(( root_end + swap_mib ))
    log_command parted -s "${TARGET_DISK}" mkpart ESP fat32 1MiB "${esp_end}MiB" || true
    log_command parted -s "${TARGET_DISK}" set 1 esp on || true
    log_command parted -s "${TARGET_DISK}" set 1 boot on || true
    log_command parted -s "${TARGET_DISK}" mkpart primary ext4 "${esp_end}MiB" "${root_end}MiB" || true
    log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${root_end}MiB" "${swap_end}MiB" || true
    log_command mkfs.fat -F32 -n EFI "$(get_part_name "${TARGET_DISK}" 1)" || true
    log_command mkfs.ext4 -F -L newroot "$(get_part_name "${TARGET_DISK}" 2)" || true
    log_command mkswap -f -L newswap "$(get_part_name "${TARGET_DISK}" 3)" || true
    if [ "${is_full}" = true ]; then
      log_command parted -s "${TARGET_DISK}" mkpart primary "${swap_end}MiB" 100% || true
      log_command parted -s "${TARGET_DISK}" set 4 lvm on || true
      log_command pvcreate -ff -y "$(get_part_name "${TARGET_DISK}" 4)" || true
    fi
  else
    local bios_end=2 root_end swap_end
    root_end=$(( bios_end + root_mib )); swap_end=$(( root_end + swap_mib ))
    log_command parted -s "${TARGET_DISK}" mkpart primary 1MiB "${bios_end}MiB" || true
    log_command parted -s "${TARGET_DISK}" set 1 bios_grub on || true
    log_command parted -s "${TARGET_DISK}" mkpart primary ext4 "${bios_end}MiB" "${root_end}MiB" || true
    log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${root_end}MiB" "${swap_end}MiB" || true
    log_command mkfs.ext4 -F -L newroot "$(get_part_name "${TARGET_DISK}" 2)" || true
    log_command mkswap -f -L newswap "$(get_part_name "${TARGET_DISK}" 3)" || true
    if [ "${is_full}" = true ]; then
      log_command parted -s "${TARGET_DISK}" mkpart primary "${swap_end}MiB" 100% || true
      log_command parted -s "${TARGET_DISK}" set 4 lvm on || true
      log_command pvcreate -ff -y "$(get_part_name "${TARGET_DISK}" 4)" || true
    fi
  fi

  local rsync_excludes=(--partial --info=progress2 --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile)
  # Reflectă în dry-run aceleași excluderi ca migrarea reală: orice mountpoint separat.
  local _mp _src
  while IFS=' ' read -r _mp _src; do
    [ -z "${_mp}" ] && continue
    [ "${_mp}" = "/" ] && continue
    case "${_src}" in /dev/*) ;; *) continue ;; esac
    rsync_excludes+=(--exclude="${_mp}/*")
  done < <(findmnt -rno TARGET,SOURCE 2>/dev/null)
  log_command rsync -aAXH "${rsync_excludes[@]}" / /mnt/newroot || true
  log_command cp /etc/default/grub /mnt/newroot/etc/default/grub || true
  if [ "${BOOT_MODE}" = "UEFI" ]; then
    log_command grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck --no-nvram || true
  else
    log_command grub-install --target=i386-pc "${TARGET_DISK}" || true
  fi
  log_command awk 'BEGIN{print "fstab update (dry-run)"}' /mnt/newroot/etc/fstab || true
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
  log_command wipefs -a "${TARGET_DISK}" || print_warning "wipefs a întâmpinat probleme (continuă)."
  log_command parted -s "${TARGET_DISK}" mklabel gpt || { print_error "Eroare la creare tabel partiții"; return 1; }
  log_command parted -s "${TARGET_DISK}" mkpart primary 1MiB 100% || { print_error "Eroare la creare partiție"; return 1; }
  log_command parted -s "${TARGET_DISK}" set 1 lvm on || true
    log_command partprobe "${TARGET_DISK}" || { print_error "partprobe a eșuat pentru ${TARGET_DISK}"; return 1; }
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
  local root_size="${TARGET_ROOT_SIZE_GB:-${SOURCE_ROOT_SIZE_GB:-37}}"
  local swap_size="${SOURCE_SWAP_SIZE_GB:-1}"
  if [ "${root_size}" -lt 10 ]; then root_size=10; fi
  if [ "${swap_size}" -lt 1 ]; then swap_size=1; fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Creare partiții pe disk destinație"

  # FIX (M3/M4): calcul offset-uri în MiB pentru o schemă contiguă și corectă.
  # ESP mic și dedicat (nu mai ocupă tot discul), iar partiția LVM e separată de ESP.
  local esp_mib=${ESP_SIZE_MIB}
  local root_mib=$(( root_size * 1024 ))
  local swap_mib=$(( swap_size * 1024 ))
  local is_full=false
  [ "${MIGRATION_TYPE}" = "full-disk" ] && is_full=true

    if [ "${is_full}" = true ]; then
      print_info "Schema: ESP/BIOS + Root=${root_size}GiB + Swap=${swap_size}GiB + LVM(rest)"
    else
      print_info "Schema: ESP/BIOS + Root=${root_size}GiB + Swap=${swap_size}GiB (rest liber)"
    fi

    # Verifică schema înainte de orice operație destructivă pe discul țintă.
    local disk_bytes disk_mib required_mib
    disk_bytes=$(blockdev --getsize64 "${TARGET_DISK}" 2>/dev/null || echo 0)
    disk_mib=$(( disk_bytes / 1024 / 1024 ))
    if [ "${BOOT_MODE}" = "UEFI" ]; then
      required_mib=$(( 1 + esp_mib + root_mib + swap_mib ))
    else
      required_mib=$(( 2 + root_mib + swap_mib ))
    fi
    if [ "${disk_mib}" -gt 0 ] && [ "${required_mib}" -ge $(( disk_mib - 16 )) ]; then
      print_error "Schema (boot+root+swap = ${required_mib}MiB) nu încape pe disc (${disk_mib}MiB)."
      print_info "Reduceți mărimea root (sau swap-ul sursă) înainte de a reîncerca."
      return 1
    fi

    # FIX (M7): curăță semnăturile vechi (LVM/FS/partition table) de pe disc
    log_command wipefs -a "${TARGET_DISK}" || print_warning "wipefs a întâmpinat probleme (continuă)."
    log_command parted -s "${TARGET_DISK}" mklabel gpt || { print_error "Eroare la creare tabel GPT"; return 1; }

    TARGET_ESP=""; TARGET_LVM=""
    if [ "${BOOT_MODE}" = "UEFI" ]; then
      local esp_start=1
      local esp_end=$(( esp_start + esp_mib ))
      local root_end=$(( esp_end + root_mib ))
      local swap_end=$(( root_end + swap_mib ))
      log_command parted -s "${TARGET_DISK}" mkpart ESP fat32 "${esp_start}MiB" "${esp_end}MiB" || { print_error "Eroare la creare ESP"; return 1; }
      log_command parted -s "${TARGET_DISK}" set 1 esp on || { print_error "Eroare la setare flag ESP"; return 1; }
      log_command parted -s "${TARGET_DISK}" set 1 boot on || print_warning "Nu am putut seta flag boot pe ESP (continui)."
      log_command parted -s "${TARGET_DISK}" mkpart primary ext4 "${esp_end}MiB" "${root_end}MiB" || { print_error "Eroare la creare partiție root"; return 1; }
      log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${root_end}MiB" "${swap_end}MiB" || { print_error "Eroare la creare partiție swap"; return 1; }
      TARGET_ESP="$(get_part_name "${TARGET_DISK}" 1)"
      TARGET_ROOT="$(get_part_name "${TARGET_DISK}" 2)"
      TARGET_SWAP="$(get_part_name "${TARGET_DISK}" 3)"
      if [ "${is_full}" = true ]; then
        log_command parted -s "${TARGET_DISK}" mkpart primary "${swap_end}MiB" 100% || { print_error "Eroare la creare partiție LVM"; return 1; }
        log_command parted -s "${TARGET_DISK}" set 4 lvm on || { print_error "Eroare la setare flag LVM"; return 1; }
        TARGET_LVM="$(get_part_name "${TARGET_DISK}" 4)"
      fi
    else
      local bios_end=2
      local root_end=$(( bios_end + root_mib ))
      local swap_end=$(( root_end + swap_mib ))
      log_command parted -s "${TARGET_DISK}" mkpart primary 1MiB "${bios_end}MiB" || { print_error "Eroare la creare partiție BIOS boot"; return 1; }
      log_command parted -s "${TARGET_DISK}" set 1 bios_grub on || { print_error "Eroare la setare flag bios_grub"; return 1; }
      log_command parted -s "${TARGET_DISK}" mkpart primary ext4 "${bios_end}MiB" "${root_end}MiB" || { print_error "Eroare la creare partiție root"; return 1; }
      log_command parted -s "${TARGET_DISK}" mkpart primary linux-swap "${root_end}MiB" "${swap_end}MiB" || { print_error "Eroare la creare partiție swap"; return 1; }
      TARGET_ROOT="$(get_part_name "${TARGET_DISK}" 2)"
      TARGET_SWAP="$(get_part_name "${TARGET_DISK}" 3)"
      if [ "${is_full}" = true ]; then
        log_command parted -s "${TARGET_DISK}" mkpart primary "${swap_end}MiB" 100% || { print_error "Eroare la creare partiție LVM"; return 1; }
        log_command parted -s "${TARGET_DISK}" set 4 lvm on || { print_error "Eroare la setare flag LVM"; return 1; }
        TARGET_LVM="$(get_part_name "${TARGET_DISK}" 4)"
      fi
    fi
  # Compatibilitate înapoi: TARGET_EXTRA = ESP (UEFI) sau LVM (BIOS)
  if [ "${BOOT_MODE}" = "UEFI" ]; then TARGET_EXTRA="${TARGET_ESP}"; else TARGET_EXTRA="${TARGET_LVM}"; fi

    # Plasă de siguranță: schema (ESP/BIOS + root + swap) trebuie să încapă pe disc.
    if [ "${disk_mib}" -gt 0 ] && [ "${swap_end}" -ge $(( disk_mib - 16 )) ]; then
      print_error "Schema (ESP/BIOS+root+swap = ${swap_end}MiB) nu încape pe disc (${disk_mib}MiB)."
      print_info "Reduceți mărimea root (sau swap-ul sursă)."
      return 1
    fi
    print_success "Schema de partiționare scrisă pe disc."

    log_command partprobe "${TARGET_DISK}" || { print_error "partprobe a eșuat pentru ${TARGET_DISK}"; return 1; }
  # FIX (M2): așteaptă NECONDIȚIONAT fiecare partiție (wait_for_dev are timeout propriu)
  for part in "${TARGET_ESP}" "${TARGET_ROOT}" "${TARGET_SWAP}" "${TARGET_LVM}"; do
    [ -n "${part}" ] || continue
    wait_for_dev "${part}" || { print_error "Partiția ${part} nu a apărut după partprobe."; return 1; }
  done

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Formatare partiții"
  log_command mkfs.ext4 -F -L newroot "${TARGET_ROOT}" || { print_error "Eroare la formatare root"; return 1; }
  if [ -b "${TARGET_SWAP}" ]; then
    log_command mkswap -f -L newswap "${TARGET_SWAP}" || { print_error "Eroare la configurare swap"; return 1; }
  fi
  if [ "${BOOT_MODE}" = "UEFI" ] && [ -n "${TARGET_ESP}" ]; then
    log_command mkfs.fat -F32 -n EFI "${TARGET_ESP}" || { print_error "Eroare la formatare ESP"; return 1; }
  fi
  print_success "Partițiile au fost formatate."

  # FIX (M3): LVM pe partiția DEDICATĂ (TARGET_LVM), pentru AMBELE moduri de boot
  if [ "${is_full}" = true ] && [ -n "${TARGET_LVM}" ] && [ -n "${VG_NAME}" ]; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Configurare LVM pe partiția dedicată"
    log_command pvcreate -ff -y "${TARGET_LVM}" || { print_error "Eroare la pvcreate"; return 1; }
    log_command vgextend "${VG_NAME}" "${TARGET_LVM}" || { print_error "Eroare la vgextend"; return 1; }
    print_success "PV creat și adăugat în VG '${VG_NAME}' (${TARGET_LVM})"
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Montare și sincronizare sistem"
  mkdir -p /mnt/newroot
  log_command mount "${TARGET_ROOT}" /mnt/newroot || { print_error "Eroare la montare ${TARGET_ROOT}"; return 1; }
  mkdir -p /mnt/newroot/{dev,proc,sys,run,boot,tmp}

  local rsync_excludes_list=(--exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile)
  # FIX: exclude din rsync ORICE filesystem montat separat sub / (pe alt disc/partiție):
  # /data, /home, /boot, /boot/efi etc. Datele lor stau pe partițiile proprii și NU trebuie
  # copiate în noul root (l-ar umfla sau depăși). Directorul punct-de-montare rămâne gol,
  # iar fstab-ul le remontează după boot. (Versiunea veche excludea doar /home.)
  local _mp _src
  while IFS=' ' read -r _mp _src; do
    [ -z "${_mp}" ] && continue
    [ "${_mp}" = "/" ] && continue
    case "${_src}" in /dev/*) ;; *) continue ;; esac
    rsync_excludes_list+=(--exclude="${_mp}/*")
    print_info "Mountpoint separat exclus din rsync: ${_mp} (rămâne pe ${_src})"
  done < <(findmnt -rno TARGET,SOURCE 2>/dev/null)

    local rsync_exit=0
    if log_interactive_command rsync -aAXH --partial --info=progress2 "${rsync_excludes_list[@]}" / /mnt/newroot; then
      rsync_exit=0
    else
      rsync_exit=$?
      if [ "${rsync_exit}" -eq 24 ]; then
        print_warning "Rsync a raportat fișiere dispărute (exit 24), dar migrarea continuă."
        log_message "Rsync completed with exit code 24 - continuing"
      else
        print_error "Eroare la rsync (exit code: ${rsync_exit})"
        cleanup_mounts /mnt/newroot
        return 1
      fi
    fi
  print_success "Sistem sincronizat."

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
      log_command mount --bind /dev/pts /mnt/newroot/dev/pts || print_warning "Nu am putut monta /dev/pts (opțional)"
    fi
  print_success "Pseudo-filesystems montate."

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Copiere configurație GRUB"
  if [ -f /etc/default/grub ]; then
    log_command cp /etc/default/grub /mnt/newroot/etc/default/ || true
    # FIX (G2): elimină orice resume= învechit din linia de kernel (swap-ul se schimbă)
    if [ -f /mnt/newroot/etc/default/grub ]; then
      sed -i 's/\([[:space:]"]\)resume=[^"[:space:]]*/\1/g' \
        /mnt/newroot/etc/default/grub || true
      log_message "Stripped stale resume= from target /etc/default/grub"
    fi
    print_success "/etc/default/grub copiat (resume= învechit eliminat)."
  else
    print_warning "/etc/default/grub nu există pe sistemul curent; se va folosi configurația implicită."
  fi

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Instalare GRUB și update initramfs"
  if [ "${BOOT_MODE}" = "UEFI" ]; then
    if ! chroot /mnt/newroot dpkg -l grub-efi-amd64 2>/dev/null | grep -q '^ii'; then
      print_info "Instalare grub-efi-amd64 în chroot (dacă lipsesc)..."
      chroot /mnt/newroot apt-get update -qq 2>&1 | tee -a "${LOG_FILE}" || true
      chroot /mnt/newroot apt-get install -y grub-efi-amd64 grub-efi-amd64-bin 2>&1 | tee -a "${LOG_FILE}" || print_warning "Nu am putut instala grub-efi în chroot"
    fi
    mkdir -p /mnt/newroot/boot/efi
    if ! log_command mount "${TARGET_ESP}" /mnt/newroot/boot/efi; then
      print_error "Eroare la montare ESP"
      cleanup_mounts /mnt/newroot
      return 1
    fi
    if [ -d /boot/efi ] && [ "$(ls -A /boot/efi 2>/dev/null)" ]; then
      log_command rsync -aAXH /boot/efi/ /mnt/newroot/boot/efi/ || true
    fi
    if ! log_command chroot /mnt/newroot grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-nvram; then
      print_error "Eroare la instalare GRUB UEFI"
      cleanup_mounts /mnt/newroot
      return 1
    fi
    # FIX (G3): instalare suplimentară pe calea removable (/EFI/BOOT/BOOTX64.EFI),
    # ca discul să pornească și fără o intrare NVRAM validă (ex. mutat în alt sistem).
    log_command chroot /mnt/newroot grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck --no-nvram \
      || print_warning "grub-install --removable a eșuat (opțional, dar recomandat)."
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
  # FIX (G1): scrie conf.d/resume cu noul UUID de swap ÎNAINTE de update-initramfs,
  # altfel initramfs păstrează swap-ul vechi (boot blocat ~30s căutând resume inexistent).
  local _new_swap_uuid resume_conf="/mnt/newroot/etc/initramfs-tools/conf.d/resume"
  _new_swap_uuid=$(blkid -s UUID -o value "${TARGET_SWAP}" 2>/dev/null || true)
  mkdir -p "$(dirname "${resume_conf}")"
  if [ -n "${_new_swap_uuid}" ]; then
    echo "RESUME=UUID=${_new_swap_uuid}" > "${resume_conf}"
    log_message "Set RESUME=UUID=${_new_swap_uuid} in target initramfs conf"
    print_info "Resume configurat pe noul swap (UUID=${_new_swap_uuid})."
  else
    echo "RESUME=none" > "${resume_conf}"
    log_message "No target swap detected; set RESUME=none"
    print_info "Niciun swap țintă; resume dezactivat (RESUME=none)."
  fi

  # FIX (G11): nu mai ascunde eșecurile cu '|| true'; raportează corect starea.
  local grub_ok=true initramfs_ok=true
  if ! log_command chroot /mnt/newroot update-grub; then
    grub_ok=false; print_warning "update-grub a eșuat (vezi ${LOG_FILE})."
  fi
  if ! log_command chroot /mnt/newroot update-initramfs -u -k all; then
    initramfs_ok=false; print_warning "update-initramfs a eșuat (vezi ${LOG_FILE})."
  fi
  if [ "${grub_ok}" = true ] && [ "${initramfs_ok}" = true ]; then
    print_success "GRUB instalat și initramfs actualizat."
  else
    print_warning "GRUB/initramfs au raportat probleme; rulează storage-post-migration.sh după boot."
  fi

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
  if [ "${BOOT_MODE}" = "UEFI" ]; then new_esp_uuid=$(blkid -s UUID -o value "${TARGET_ESP}" 2>/dev/null || true); else new_esp_uuid=""; fi
  if [ -z "${new_root_uuid}" ]; then
    print_error "Nu pot obține UUID root."
    cleanup_mounts /mnt/newroot
    return 1
  fi

  # Build new fstab.tmp; in BIOS mode we drop /boot/efi entries
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
            # else: BIOS mode -> drop /boot/efi lines
            next
        }
        { print } ' "${fstab_path}" > "${fstab_temp}"

  # Ensure mountpoints exist for any entries in the temp fstab (excluding root and swap)
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
    [ "${BOOT_MODE}" = "UEFI" ] && echo "TARGET_ESP=${TARGET_ESP} UUID=${new_esp_uuid}"
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
    echo -e "${DIM}Noul fstab:"; sed 's/^/  /' "${fstab_path}"; echo -e "${NC}"
  else
    print_error "Validarea noului fstab a eșuat! Modificările NU au fost aplicate."
    print_warning "Verifică fișierul de debug: ${FSTAB_VALIDATE_LOG}"
    # Hint for common BIOS /boot/efi leftover (should already be dropped, but keep guidance)
    if [ "${BOOT_MODE}" = "BIOS" ] && grep -qE '^[[:space:]]*[^#].*[[:space:]]/boot/efi[[:space:]]' "${fstab_temp}" 2>/dev/null; then
      print_warning "BIOS mode: intrări /boot/efi detectate. Ar trebui eliminate din fstab."
    fi
    cleanup_mounts /mnt/newroot
    return 1
  fi

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

  if [ "${MIGRATION_TYPE}" = "full-disk" ] && [ "${#SOURCE_PVS[@]}" -gt 0 ]; then
    if [ -z "${TARGET_LVM}" ]; then
      print_error "Migrare full-disk dar nu există partiție LVM țintă (TARGET_LVM gol)!"
      return 1
    fi
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Migrare date LVM (pvmove)"
    for source_pv in "${SOURCE_PVS[@]}"; do
      local vg; vg=$(pvs --noheadings -o vg_name "${source_pv}" 2>/dev/null | xargs)
      print_info "pvmove: ${source_pv} → ${TARGET_LVM}"
      print_warning "Poate dura ore! NU întrerupe!"
      local pvmove_cmd_full=(pvmove -i 5 "${source_pv}" "${TARGET_LVM}")
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
  while [ $# -gt 0 ]; do
    local _val=""
    case "$1" in *=*) _val="${1#*=}" ;; esac
    case "$1" in
      --resume) RESUME_MODE=true ;;
      --check) CHECK_MODE=true ;;
      --debug) DEBUG_MODE=true ;;
      --yes|-y) ASSUME_YES=true ;;
      --source=*) ARG_SOURCE="$(read_cli_value "--source" "${_val}")" ;;
      --source)   ARG_SOURCE="$(read_cli_value "$1" "${2-}")"; shift ;;
      --target=*) ARG_TARGET="$(read_cli_value "--target" "${_val}")" ;;
      --target)   ARG_TARGET="$(read_cli_value "$1" "${2-}")"; shift ;;
      --root-size=*) ARG_ROOT_SIZE="$(read_cli_value "--root-size" "${_val}")" ;;
      --root-size)   ARG_ROOT_SIZE="$(read_cli_value "$1" "${2-}")"; shift ;;
      --boot-mode=*) ARG_BOOT_MODE="$(read_cli_value "--boot-mode" "${_val}")" ;;
      --boot-mode)   ARG_BOOT_MODE="$(read_cli_value "$1" "${2-}")"; shift ;;
      --help|-h)
        cat <<EOF
Usage: $0 [optiuni]

Mod interactiv (implicit): rulează fără argumente de disc.

Opțiuni generale:
  --check            Pre-validează migrarea fără execuție (dry-run sigur)
  --resume           Reia o operațiune pvmove LVM eșuată
  --debug            Logging detaliat și diagnostice suplimentare
  --help             Afișează acest mesaj

Mod NON-INTERACTIV (toate confirmările sunt sărite):
  --source <disk>    Disk SURSĂ (ex: /dev/sda) - cel care va fi înlocuit
  --target <disk>    Disk DESTINAȚIE (ex: /dev/nvme0n1) - VA FI ȘTERS COMPLET
  --root-size <GiB>  Mărimea partiției root (root-only/full-disk)
  --boot-mode <M>    Suprascrie modul de boot: BIOS sau UEFI (implicit: auto-detectat)
  --yes, -y          Răspunde automat DA la toate confirmările (PERICULOS)

Exemplu non-interactiv complet:
  $0 --source /dev/sda --target /dev/nvme0n1 --root-size 40 --yes

NOTĂ: pentru execuție 100% fără prompt-uri sunt necesare --source, --target și
--yes (plus --root-size pentru migrări de tip root). Lipsa lor revine la prompt.
EOF
        exit 0
        ;;
      *) print_error "Argument necunoscut: $1 (vezi --help)"; exit 1 ;;
    esac
    shift
  done

  # Auto-activează --yes dacă s-au dat sursă+țintă (intenție clară de non-interactiv)?
  # NU: păstrăm --yes explicit pentru siguranță (ștergere de disc).
  if { [ -n "${ARG_SOURCE}" ] || [ -n "${ARG_TARGET}" ]; } && [ "${ASSUME_YES}" = false ]; then
    print_warning "Ai dat --source/--target dar nu --yes: confirmările vor fi cerute interactiv."
  fi

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

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Verificare comenzi necesare"
  required_cmds=(parted lsblk rsync mkfs.ext4 mkswap pvcreate vgextend pvmove vgreduce blkid grub-install update-grub mkfs.fat partprobe udevadm pvs vgs lvs findmnt mount umount chroot blockdev df mountpoint awk e2fsck wipefs)
  missing=()
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then missing+=("${cmd}"); fi
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    print_error "Lipsesc comenzile: ${missing[*]}"
    print_info "Instalează pachetele necesare: apt install parted rsync lvm2 grub-pc-bin grub-efi-amd64-bin dosfstools util-linux coreutils gawk e2fsprogs"
    exit 1
  fi
  print_success "Toate comenzile necesare sunt disponibile"

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Detectare mod boot (UEFI / BIOS)"
  if [ -d /sys/firmware/efi ]; then BOOT_MODE="UEFI"; else BOOT_MODE="BIOS"; fi
  print_info "Sistem detectat ca: ${GREEN}${BOLD}${BOOT_MODE}${NC}"
  if [ -n "${ARG_BOOT_MODE}" ]; then
    # Non-interactiv: folosește valoarea din --boot-mode (validată)
    local _bm; _bm=$(echo "${ARG_BOOT_MODE}" | tr '[:lower:]' '[:upper:]')
    if [[ "${_bm}" =~ ^(BIOS|UEFI)$ ]]; then
      [ "${_bm}" != "${BOOT_MODE}" ] && print_warning "Boot mode suprascris prin argument: ${_bm}"
      BOOT_MODE="${_bm}"
    else
      print_error "Valoare --boot-mode invalidă: ${ARG_BOOT_MODE} (acceptat: BIOS|UEFI)"; exit 1
    fi
  elif [ "${ASSUME_YES}" = true ]; then
    print_info "Mod non-interactiv: păstrez modul auto-detectat (${BOOT_MODE})."
  else
    read -rp "$(echo -e ${CYAN}Confirmi ${BOOT_MODE} sau schimbi? [BIOS/UEFI/ENTER păstrează]: ${NC})" USER_BOOT
    if [[ -n "${USER_BOOT}" && "${USER_BOOT}" =~ ^(BIOS|UEFI)$ ]]; then BOOT_MODE="${USER_BOOT}"; print_warning "Boot mode suprascris: ${BOOT_MODE}"; fi
  fi
  print_success "Boot mode: ${BOLD}${BOOT_MODE}${NC}"

    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Detectare root curent"
    CURRENT_ROOT_DEV=$(findmnt -no SOURCE /)
    if [ -z "${CURRENT_ROOT_DEV}" ]; then print_error "Nu pot detecta root device!"; exit 1; fi
    detect_current_root_disks "${CURRENT_ROOT_DEV}"
    if [ "${#CURRENT_ROOT_DISKS[@]}" -gt 0 ]; then
      CURRENT_ROOT_DISK="${CURRENT_ROOT_DISKS[0]}"
    else
      pkname=$(lsblk -no PKNAME "${CURRENT_ROOT_DEV}" 2>/dev/null || true)
      if [ -n "${pkname}" ]; then CURRENT_ROOT_DISK="/dev/${pkname}"; else CURRENT_ROOT_DISK=$(echo "${CURRENT_ROOT_DEV}" | sed -E 's/p?[0-9]+$//'); fi
      CURRENT_ROOT_DISK=$(readlink -f "${CURRENT_ROOT_DISK}" 2>/dev/null || echo "${CURRENT_ROOT_DISK}")
      add_unique_root_disk "${CURRENT_ROOT_DISK}"
    fi
    print_success "Root curent: ${BOLD}${CURRENT_ROOT_DEV}${NC} pe ${BOLD}${CURRENT_ROOT_DISKS[*]}${NC}"

  HOME_SOURCE=$(findmnt -no SOURCE /home 2>/dev/null || true)
  if [ -n "${HOME_SOURCE}" ] && lvs "${HOME_SOURCE}" >/dev/null 2>&1; then
    LV_NAME=$(lvs --noheadings -o lv_name "${HOME_SOURCE}" 2>/dev/null | xargs || true)
    [ -n "${LV_NAME}" ] && print_success "/home pe LVM: ${BOLD}${LV_NAME}${NC}"
  fi

  # select source
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Selectare disk SURSĂ (cel care va fi înlocuit)"
  if [ -n "${ARG_SOURCE}" ]; then
    # Non-interactiv: validează --source
    if [ ! -b "${ARG_SOURCE}" ]; then print_error "Disk SURSĂ invalid (--source ${ARG_SOURCE}): nu e un dispozitiv bloc."; exit 1; fi
    SOURCE_DISK=$(readlink -f "${ARG_SOURCE}")
    print_success "Sursă (din argument): ${SOURCE_DISK}"
  else
    while true; do
      show_disk_list
      select_disk_from_list SOURCE_DISK "Selectare disk SURSĂ" "false"
      if [ -n "${SOURCE_DISK}" ] && [ -b "${SOURCE_DISK}" ]; then
        SOURCE_DISK=$(readlink -f "${SOURCE_DISK}")
        print_success "Sursă: ${SOURCE_DISK}"
        break
      fi
      print_error "Disk invalid. Încearcă din nou."
    done
  fi

  # select target
  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Selectare disk DESTINAȚIE (noul disk)"
  if [ -n "${ARG_TARGET}" ]; then
    # Non-interactiv: validează --target
      if [ ! -b "${ARG_TARGET}" ]; then print_error "Disk DESTINAȚIE invalid (--target ${ARG_TARGET}): nu e un dispozitiv bloc."; exit 1; fi
      TARGET_DISK=$(readlink -f "${ARG_TARGET}")
      if [ "${SOURCE_DISK}" = "${TARGET_DISK}" ]; then print_error "Sursa și ținta sunt identice (${TARGET_DISK})."; exit 1; fi
      if is_current_root_disk "${TARGET_DISK}"; then print_error "Ținta nu poate fi un disc root curent (${CURRENT_ROOT_DISKS[*]})."; exit 1; fi
    print_success "Țintă (din argument): ${TARGET_DISK}"
  else
    while true; do
      show_disk_list
      select_disk_from_list TARGET_DISK "Selectare disk DESTINAȚIE" "true"
      if [ -z "${TARGET_DISK}" ] || [ ! -b "${TARGET_DISK}" ]; then
        print_error "Disk invalid sau nimic selectat. Încearcă din nou."
        continue
        fi
        TARGET_DISK=$(readlink -f "${TARGET_DISK}")
        if [ "${SOURCE_DISK}" = "${TARGET_DISK}" ]; then print_error "Sursa și ținta sunt identice."; continue; fi
        if is_current_root_disk "${TARGET_DISK}"; then print_error "Ținta nu poate fi un disc root curent (${CURRENT_ROOT_DISKS[*]})."; continue; fi
      print_success "Țintă: ${TARGET_DISK}"
      break
    done
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

  CURRENT_STEP=$((CURRENT_STEP + 1))
  print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Analiză configurație și tip migrare"
  detect_source_type
  case "${MIGRATION_TYPE}" in
    lvm-only) print_info "Tip migrare: LVM PV-ONLY" ;;
    root-only) print_info "Tip migrare: ROOT DISK" ;;
    full-disk) print_info "Tip migrare: FULL DISK (Root + LVM)" ;;
    empty) print_error "Disk sursă pare gol sau fără date detectabile!"; exit 1 ;;
    *) print_error "Tip migrare necunoscut: ${MIGRATION_TYPE}"; exit 1 ;;
  esac

  if [[ "${MIGRATION_TYPE}" == "root-only" || "${MIGRATION_TYPE}" == "full-disk" ]]; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    print_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "Configurare mărime partiție root"
    local default_root_size=${SOURCE_ROOT_SIZE_GB:-37}
    local target_disk_info target_disk_size
    target_disk_info=$(get_disk_info "${TARGET_DISK}")
    IFS='|' read -r target_disk_size _ _ <<< "${target_disk_info}"

    if [ -n "${ARG_ROOT_SIZE}" ]; then
      # Non-interactiv: validează --root-size
      TARGET_ROOT_SIZE_GB="${ARG_ROOT_SIZE}"
      if ! validate_root_size "${TARGET_ROOT_SIZE_GB}" "${target_disk_size}"; then
        print_error "Valoare --root-size invalidă: ${ARG_ROOT_SIZE} GiB (disc țintă: ${target_disk_size} GB)"; exit 1
      fi
      print_success "Mărime root destinație (din argument): ${BOLD}${TARGET_ROOT_SIZE_GB} GiB${NC}"
    elif [ "${ASSUME_YES}" = true ]; then
      # Non-interactiv fără --root-size: folosește mărimea sursei ca implicit
      TARGET_ROOT_SIZE_GB="${default_root_size}"
      if ! validate_root_size "${TARGET_ROOT_SIZE_GB}" "${target_disk_size}"; then
        print_error "Mărimea root implicită (${default_root_size} GiB) nu e validă pentru discul țintă (${target_disk_size} GB). Folosește --root-size."; exit 1
      fi
      print_info "Mod non-interactiv: folosesc mărimea root implicită ${BOLD}${TARGET_ROOT_SIZE_GB} GiB${NC} (= sursă)."
    else
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
  esac

  log_message "=== MIGRATION COMPLETED ==="

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

  if [ "${MIGRATION_TYPE}" != "lvm-only" ]; then
    echo -e "${RED}${BOLD}⚠ CE FACI MAI DEPARTE :${NC}"
    echo -e "  1) Oprește serverul: ${DIM}sudo poweroff${NC}"
    echo -e "  2) Înlocuiește fizic discul: scoate ${SOURCE_DISK} și pune ${TARGET_DISK} în locul său"
    echo -e "  3) Pornește serverul și verifică boot-ul"
    echo -e "  4) După boot, verifică: ${DIM}df -h; lsblk; mount | grep ' / '${NC}\n"
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

# FIX (M5): la eroare, curăță mount-urile rămase din /mnt/newroot înainte de a ieși.
cleanup_on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-?}"
  print_error "Script întrerupt (cod ${rc}) în jurul liniei ${line}"
  log_message "ERROR (rc=${rc}) near line ${line}"
  if mountpoint -q /mnt/newroot 2>/dev/null; then
    print_warning "Curăț mount-urile temporare rămase din /mnt/newroot..."
    cleanup_mounts /mnt/newroot 2>/dev/null || true
  fi
  exit "${rc:-1}"
}
trap cleanup_on_error ERR

main "$@"
exit 0
