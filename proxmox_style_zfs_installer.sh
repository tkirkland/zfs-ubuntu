#!/bin/bash
# Kubuntu ZFS Installation Script with Proxmox-Style Architecture
# Combines Kubuntu 3-pool design with Proxmox installer framework
# Supports encrypted ZFS-on-root with RAID configurations
# Version 2.1 - Fixed partition path handling for by-id paths

set -euo pipefail

# =============================================================================
# CONFIGURATION AND CONSTANTS
# =============================================================================


# =============================================================================
# LOGGING AND ERROR HANDLING
# =============================================================================

#######################################
# Setup logging directory and rotation.
# Globals:
#   log_dir, max_log_files, log_file
# Arguments:
#   None
# Outputs:
#   Creates a log file and writes header
#######################################
setup_logging() {
    # Create a logs directory if it doesn't exist
    mkdir -p "${log_dir}"

    # Rotate old logs - keep only max_log_files most recent
    local log_count
    log_count=$(find "${log_dir}" -name "zfs-install-*.log" 2>/dev/null | wc -l)

    if [[ ${log_count} -ge ${max_log_files} ]]; then
        # Remove the oldest logs to maintain max count
        local logs_to_remove=$((log_count - max_log_files + 1))
        find "${log_dir}" -name "zfs-install-*.log" -type f -printf '%T+ %p\n' 2>/dev/null | \
            sort | head -n "${logs_to_remove}" | cut -d' ' -f2- | \
            while IFS= read -r old_log; do
                rm -f "${old_log}"
            done
    fi

    # Create a new log file
    log_file="${log_dir}/zfs-install-$(date +%Y%m%d-%H%M%S).log"
    touch "${log_file}"

    # Log startup information
    {
        echo "==================================================="
        echo "ZFS Installation Log - $(date)"
        echo "Script Version: ${script_version}"
        echo "==================================================="
        echo ""
    } >> "${log_file}"
}

#######################################
# Log a message with timestamp and level.
# Globals:
#   log_file
# Arguments:
#   Level string (INFO, WARN, ERROR)
#   Message to log
# Outputs:
#   Writes a formatted message to stdout and log file
#######################################
log() {
    local level="$1"
    shift
    local message
    message="[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*"

    # Write to log a file only, not to stdout/stderr
    if [[ -n "${log_file:-}" ]]; then
        echo "${message}" >> "${log_file}"
    fi

    # Only show errors and critical warnings on the console
    if [[ "${level}" == "ERROR" ]]; then
        echo "${message}" >&2
    fi
}

#######################################
# Log an informational message.
# Arguments:
#   Message to log
#######################################
log_info() {
    log "INFO" "$@"
}

#######################################
# Log a warning message.
# Arguments:
#   Message to log
#######################################
log_warn() {
    log "WARN" "$@"
}

#######################################
# Log an error message.
# Arguments:
#   Message to log
#######################################
log_error() {
    log "ERROR" "$@"
}

#######################################
# Log error message, cleanup, and exit.
# Globals:
#   None
# Arguments:
#   Error message
# Returns:
#   Exit status 1
#######################################
die() {
    log_error "$@"
    cleanup_on_error
    exit 1
}

#######################################
# Clean up resources on error.
# Globals:
#   target_dir
#   boot_pool_name, root_pool_name, home_pool_name
#   temp_dir
# Arguments:
#   None
#######################################
cleanup_on_error() {
    local pool
    # Check if cleanup is already in progress
    if [[ ${cleanup_done:-0} -eq 1 ]]; then
        return 0
    fi

    echo ""
    echo "Performing cleanup..."
    log_info "Performing cleanup due to error or interruption..."

    # Unmount any mounted filesystems
    if [[ -n "${target_dir:-}" ]] && mountpoint -q "${target_dir}" 2>/dev/null; then
        echo "Unmounting filesystems..."
        umount -R "${target_dir}" 2>/dev/null || true
    fi

    # Export any imported pools
    if command -v zpool >/dev/null 2>&1; then
        echo "Checking for imported ZFS pools..."
        for pool in "${boot_pool_name}" "${root_pool_name}" "${home_pool_name}"; do
            if zpool list "${pool}" >/dev/null 2>&1; then
                echo "Exporting ZFS pool ${pool}..."
                log_info "Exporting ZFS pool ${pool}"
                zpool export "${pool}" 2>/dev/null || true
            fi
        done
    fi

    # Clean up temporary directory
    if [[ -d ${temp_dir:-} ]]; then
        echo "Removing temporary files..."
        rm -rf "${temp_dir}"
    fi

    echo "Cleanup completed"
    log_info "Cleanup completed"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

#######################################
# Prompt for user confirmation.
# Arguments:
#   Prompt message
# Returns:
#   0 if the user confirms (yes), 1 otherwise
#######################################
confirm() {
    local prompt="${1:-Are you sure?}"
    local response

    while true; do
        read -r -p "${prompt} (y/n): " response
        case "${response}" in
            [yY]|[yY][eE][sS])
                return 0
                ;;
            [nN]|[nN][oO])
                return 1
                ;;
            *)
                echo "Please answer yes (y) or no (n)."
                ;;
        esac
    done
}

#######################################
# Update and display installation progress.
# Arguments:
#   Current progress percentage
#   Progress description text
#######################################
update_progress() {
    local current="$1"
    local text="$2"

    echo "Progress: ${current}% - ${text}"
    log_info "[${current}%] ${text}"
}

#######################################
# Execute command with logging and error handling.
# Arguments:
#   Command to execute
# Returns:
#   Exit status of command or exits on failure
#######################################
syscmd() {
    local cmd="$*"
    log_info "Executing: ${cmd}"

    if ! eval "${cmd}"; then
        die "Command failed: ${cmd}"
    fi
}

#######################################
# Wait for a block device to be ready.
# Arguments:
#   Device path
#   Timeout in seconds (optional, default 10)
# Returns:
#   0 if the device is ready, 1 if the device has timed out
#######################################
wait_for_device() {
    local device="$1"
    local timeout="${2:-10}"
    local elapsed=0

    log_info "Waiting for device $device to be ready..."

    while [[ $elapsed -lt $timeout ]]; do
        if [[ -b "$device" ]]; then
            # Device exists, make sure it's ready
            blockdev --rereadpt "$device" 2>/dev/null || true
            udevadm settle --exit-if-exists="$device" --timeout=1
            log_info "Device $device is ready"
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done

    log_warn "Timeout waiting for device $device"
    return 1
}

#######################################
# Check system requirements for installation.
# Globals:
#   EUID
# Arguments:
#   None
# Returns:
#   0 if requirements met, exits on failure
#######################################
check_requirements() {
    log_info "Checking system requirements..."

    # Check if running as root
    if ((EUID != 0)); then
        die "This script must be run as root"
    fi

    # Check for required commands
    local required_cmds=(
        "zpool" "zfs" "sgdisk" "partprobe" "mkfs.vfat"
        "debootstrap" "chroot" "mount" "umount"
    )

    local cmd
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            die "Required command not found: ${cmd}"
        fi
    done

    # Check if EFI system
    if [[ ! -d /sys/firmware/efi ]]; then
        die "This script requires UEFI/EFI system"
    fi

    # Check available memory
    local mem_kb
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    local mem_mb
    mem_mb=$((mem_kb / 1024))

    if ((mem_mb < 1024)); then
        die "Insufficient memory: ${mem_mb}MB available, 1GB minimum required"
    fi

    log_info "System requirements check passed"
}

# =============================================================================
# DISK DISCOVERY AND VALIDATION
# =============================================================================

#######################################
# Get disk information (size, model, block size).
# Arguments:
#   Disk device path
# Outputs:
#   Writes "size_bytes:model:logical_block_size" to stdout
# Returns:
#   0 on success
#######################################
get_disk_info() {
    local disk="$1"
    local size_bytes
    local model
    local logical_bsize

    # Get disk size in bytes
    size_bytes="$(blockdev --getsize64 "${disk}" 2>/dev/null || echo "0")"

    # Get disk model
    model="$(lsblk -no MODEL "${disk}" 2>/dev/null | head -1 | xargs ||
        echo "Unknown")"

    # Get logical block size
    logical_bsize="$(blockdev --getss "${disk}" 2>/dev/null || echo "512")"

    echo "${size_bytes}:${model}:${logical_bsize}"
}

#######################################
# Get a by-id path for a disk device.
# Arguments:
#   Device path (e.g., /dev/sda)
# Outputs:
#   Writes by-id path to stdout
# Returns:
#   0 on success
#######################################
get_disk_by_id_path() {
    local device="$1" by_id_path="" id_path

    # Find the by-id path for this device
    for id_path in /dev/disk/by-id/*; do
        if [[ -L "$id_path" ]] && [[ ! "$id_path" =~ -part[0-9]+$ ]]; then
            local target
            target="$(readlink -f "$id_path")"
            if [[ "$target" == "$device" ]]; then
                by_id_path="$id_path"
                # Prefer ata- or nvme-prefixed paths over wwn-
                if [[ "$id_path" =~ /(ata-|nvme-) ]]; then
                    echo "$id_path"
                    return 0
                fi
            fi
        fi
    done

    # Return any by-id path found if no ata/nvme path
    if [[ -n "$by_id_path" ]]; then
        echo "$by_id_path"
        return 0
    fi

    # Fallback to a device path if no by-id found
    echo "$device"
    return 1
}

#######################################
# Detect existing OS on a disk.
# Arguments:
#   Disk device path
# Outputs:
#   Writes OS name to stdout if detected
# Returns:
#   0 on success
#######################################
detect_os_on_disk() {
    local disk="$1"
    local os_detected=""

    # Check for Windows signatures
    if command -v ntfsfix >/dev/null 2>&1; then
        # Look for NTFS partitions that might contain Windows
        local parts
        parts=$(lsblk -nlo NAME,FSTYPE "$disk" 2>/dev/null | grep -E 'ntfs|NTFS' | awk '{print "/dev/"$1}')
        if [[ -n "$parts" ]]; then
            # Try to detect Windows boot files
            for part in $parts; do
                # Check if we can probe the filesystem
                if blkid "$part" 2>/dev/null | grep -qi 'LABEL=".*[Ww]indows.*"'; then
                    os_detected="Windows"
                    break
                elif blkid "$part" 2>/dev/null | grep -qi 'LABEL="System Reserved"'; then
                    os_detected="Windows"
                    break
                fi
            done
            if [[ -z "$os_detected" ]] && [[ -n "$parts" ]]; then
                # NTFS found but can't confirm Windows
                os_detected="NTFS filesystem"
            fi
        fi
    fi

    # Check for Linux installations
    if [[ -z "$os_detected" ]]; then
        local linux_parts
        linux_parts=$(lsblk -nlo NAME,FSTYPE "$disk" 2>/dev/null | grep -E 'ext[234]|btrfs|xfs' | awk '{print "/dev/"$1}')
        if [[ -n "$linux_parts" ]]; then
            for part in $linux_parts; do
                # Try to identify specific Linux distros
                local label
                label=$(blkid "$part" 2>/dev/null | grep -oP 'LABEL="\K[^"]+')
                if [[ -n "$label" ]]; then
                    case "$label" in
                        *[Uu]buntu*) os_detected="Ubuntu Linux" ; break ;;
                        *[Kk]ubuntu*) os_detected="Kubuntu Linux" ; break ;;
                        *[Dd]ebian*) os_detected="Debian Linux" ; break ;;
                        *[Ff]edora*) os_detected="Fedora Linux" ; break ;;
                        *[Cc]ent[Oo][Ss]*|*[Rr]ed[Hh]at*|*RHEL*) os_detected="RedHat/CentOS Linux" ; break ;;
                        *[Aa]rch*) os_detected="Arch Linux" ; break ;;
                        *[Ss]use*|*SUSE*) os_detected="SUSE Linux" ; break ;;
                        *[Mm]int*) os_detected="Linux Mint" ; break ;;
                        *) os_detected="Linux" ;;
                    esac
                fi
            done
            if [[ -z "$os_detected" ]] && [[ -n "$linux_parts" ]]; then
                os_detected="Linux"
            fi
        fi
    fi

    # Check for ZFS pools
    if [[ -z "$os_detected" ]] && command -v zpool >/dev/null 2>&1; then
        # Check if disk has ZFS labels
        if zpool labelclear -n "$disk" 2>&1 | grep -q "labels cleared"; then
            os_detected="ZFS pool"
        fi
    fi

    echo "$os_detected"
}

#######################################
# Discover suitable disks for installation.
# Arguments:
#   None
# Outputs:
#   Writes associative info: "device:by-id-path:size:model:os" to stdout
# Returns:
#   0 on success, exits if no disks found
#######################################
discover_disks() {
    log_info "Discovering available disks..."

    local disks=() processed_devices=() device real_device

    # Find all block devices
    while IFS= read -r device; do
        local device_path="/dev/$device"

        # Skip loop devices, partitions, etc.
        if [[ "$device" =~ ^loop ]] || [[ "$device" =~ ^ram ]] || [[ "$device" =~ ^zram ]]; then
            continue
        fi

        # Skip if already processed (handles symlink duplicates)
        real_device="$(readlink -f "$device_path")"
        if printf '%s\n' "${processed_devices[@]}" | grep -q "^${real_device}$"; then
            continue
        fi
        processed_devices+=("$real_device")

        # Skip if the disk is mounted
        if grep -q "^${device_path}" /proc/mounts 2>/dev/null; then
            log_info "Skipping ${device_path}: currently mounted"
            continue
        fi

        # Skip if the disk is part of a RAID array
        if [[ -f "/proc/mdstat" ]] && grep -q "${device}" /proc/mdstat 2>/dev/null; then
            log_info "Skipping ${device_path}: part of RAID array"
            continue
        fi

        # Get disk info
        local disk_info
        disk_info="$(get_disk_info "${device_path}")"
        local size_bytes="${disk_info%%:*}"
        local rest="${disk_info#*:}"
        local model="${rest%:*}"
        local size_gb
        size_gb=$((size_bytes / 1024 / 1024 / 1024))

        # Skip if the disk is too small (minimum 167GB for 3-pool design)
        if ((size_gb < 167)); then
            log_warn "Skipping disk ${device_path}: too small (${size_gb} GB < 167 GB minimum)"
            continue
        fi

        # Get a by-id path for ZFS operations
        local by_id_path
        by_id_path="$(get_disk_by_id_path "${device_path}")"

        # Detect existing OS on the disk
        local existing_os
        existing_os="$(detect_os_on_disk "${device_path}")"

        # Store the mapping (include OS info)
        disks+=("${device_path}:${by_id_path}:${size_gb}:${model}:${existing_os}")

        # Log disk info with OS detection
        if [[ -n "$existing_os" ]]; then
            log_info "Found disk: ${device_path} (${size_gb} GB, ${model}) - ${existing_os} detected"
        else
            log_info "Found disk: ${device_path} (${size_gb} GB, ${model})"
        fi
        log_info "  By-ID path: ${by_id_path}"
    done < <(lsblk -ndo NAME,TYPE | awk '$2=="disk" {print $1}')

    if ((${#disks[@]} == 0)); then
        die "No suitable disks found for installation (minimum 167GB required)"
    fi

    printf '%s\n' "${disks[@]}"
}

#######################################
# Check 4K sector size compatibility.
# Arguments:
#   Logical block size in bytes
# Returns:
#   0 if compatible, exits if incompatible
#######################################
legacy_bios_4k_check() {
    local logical_bsize="$1"

    # Since we already checked for an EFI system, this should not be an issue
    # But keeping the check for completeness
    if ((logical_bsize == 4096)); then
        log_warn "4K native drive detected - ensuring EFI boot mode"
        if [[ ! -d /sys/firmware/efi ]]; then
            die "4K native drives are not supported in legacy BIOS mode"
        fi
    fi
}

#######################################
# Check disk size compatibility for mirroring.
# Arguments:
#   Expected size in bytes
#   Actual size in bytes
# Returns:
#   0 if compatible, exits if incompatible
#######################################
zfs_mirror_size_check() {
    local expected="$1" diff actual="$2" tolerance

    # Allow 10% size difference tolerance
    diff=$((expected > actual ? expected - actual : actual - expected))
    tolerance=$((expected / 10))

    if ((diff > tolerance)); then
        die "Disk size mismatch: expected ~${expected} bytes, got ${actual} bytes " \
            "(difference: ${diff} bytes > ${tolerance} tolerance)"
    fi
}

# =============================================================================
# ZFS POOL MANAGEMENT
# =============================================================================

#######################################
# Load ZFS kernel module with retry logic.
# Arguments:
#   None
# Returns:
#   0 on success, exits on failure
#######################################
load_zfs_module() {
    log_info "Loading ZFS kernel module..."

    local retries=5
    local i

    for ((i = retries; i > 0; i--)); do
        modprobe zfs 2>/dev/null || true
        # Trigger device creation for zfs
        udevadm trigger --subsystem-match=misc --action=add
        # Wait for /dev/zfs to appear
        if udevadm settle --exit-if-exists=/dev/zfs --timeout=2; then
            if [[ -c /dev/zfs ]]; then
                log_info "ZFS module loaded successfully"
                return 0
            fi
        fi
        log_warn "ZFS module not ready, retrying... ($i attempts remaining)"
    done

    die "Unable to load ZFS kernel module"
}

#######################################
# Check for existing ZFS pools that might conflict.
# Globals:
#   boot_pool_name, root_pool_name, home_pool_name
# Arguments:
#   None
# Returns:
#   0 if no conflicts, exits on conflict
#######################################
check_existing_pools() {
    local pool_name existing_pools

    log_info "Checking for existing ZFS pools..."

    # First, check if any of our pool names are already imported
    for pool_name in "$boot_pool_name" "$root_pool_name" "$home_pool_name"; do
        if zpool list "${pool_name}" >/dev/null 2>&1; then
            die "Pool ${pool_name} is already imported. Please export or destroy it first."
        fi
    done

    # Check for importable pools
    existing_pools="$(zpool import -d /dev 2>&1 | grep -E "^\s+pool:" | awk '{print $2}' || true)"

    if [[ -n $existing_pools ]]; then
        log_warn "Found existing ZFS pools:"
        echo "$existing_pools" | while read -r pool; do
            log_warn "  - $pool"
        done

        # Check for conflicts with our 3 pool names
        for pool_name in "$boot_pool_name" "$root_pool_name" "$home_pool_name"; do
            if echo "$existing_pools" | grep -q "^$pool_name$"; then
                log_error "Pool name conflict: '$pool_name' already exists"
                echo "Please destroy or rename the existing pool:"
                echo "  zpool import $pool_name"
                echo "  zpool destroy $pool_name  # WARNING: Destroys data!"
                echo "OR"
                echo "  zpool export $pool_name"
                die "Cannot proceed with existing pool name conflict"
            fi
        done
    fi
}

#######################################
# Calculate optimal ZFS ARC maximum size.
# Globals:
#   zfs_opts
# Arguments:
#   None
#######################################
calculate_arc_max() {
    local total_memory_kb total_memory_mb=$((total_memory_kb / 1024))
    total_memory_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

    # More conservative ARC sizing:
    # - Systems ≤4GB: 25% of RAM (min 256MB)
    # - Systems ≤8GB: 25% of RAM (1-2GB)
    # - Systems ≤16GB: 25% of RAM (2-4GB)
    # - Systems ≤32GB: 20% of RAM (3-6GB)
    # - Systems >32GB: Max 8GB (plenty for caching)

    local arc_max_mb

    if [[ $total_memory_mb -le 4096 ]]; then
        # ≤4GB: Use 25%, min 256MB
        arc_max_mb=$((total_memory_mb / 4))
        if [[ $arc_max_mb -lt 256 ]]; then
            arc_max_mb=256
        fi
    elif [[ $total_memory_mb -le 8192 ]]; then
        # ≤8GB: Use 25%
        arc_max_mb=$((total_memory_mb / 4))
    elif [[ $total_memory_mb -le 16384 ]]; then
        # ≤16GB: Use 25%
        arc_max_mb=$((total_memory_mb / 4))
    elif [[ $total_memory_mb -le 32768 ]]; then
        # ≤32GB: Use 20%
        arc_max_mb=$((total_memory_mb / 5))
    else
        # >32GB: Cap at 8GB
        arc_max_mb=8192
    fi

    # Ensure we leave at least 1GB for the system
    local max_allowed=$((total_memory_mb - 1024))
    if [[ $arc_max_mb -gt $max_allowed ]] && [[ $max_allowed -gt 256 ]]; then
        arc_max_mb=$max_allowed
    fi

    zfs_opts["arc_max"]=$arc_max_mb
    log_info "Calculated ZFS ARC max size: ${arc_max_mb}MB " \
        "(Total memory: ${total_memory_mb}MB)"
}

#######################################
# Get ZFS RAID vdev specification.
# Arguments:
#   Filesystem type
#   Disk array
# Outputs:
#   Writes vdev specification to stdout
#######################################
get_zfs_raid_setup() {
    local filesystem="$1"
    shift
    local disks=("$@")
    local disk_count=${#disks[@]}
    local vdev_spec=""

    case "$filesystem" in
    "zfs-raid0" | "zfs (RAID0)")
        if [[ $disk_count -lt 1 ]]; then
            die "RAID0 requires at least 1 disk"
        fi
        vdev_spec="${disks[*]}"
        ;;

    "zfs-raid1" | "zfs (RAID1)")
        if [[ $disk_count -lt 2 ]]; then
            die "RAID1 requires at least 2 disks"
        fi

        # Check disk sizes
        local expected_size
        local disk_info
        disk_info=$(get_disk_info "${disks[0]}")
        expected_size="${disk_info%%:*}"

        for disk in "${disks[@]}"; do
            disk_info=$(get_disk_info "$disk")
            local actual_size="${disk_info%%:*}"
            zfs_mirror_size_check "$expected_size" "$actual_size"
        done

        vdev_spec="mirror ${disks[*]}"
        ;;

    "zfs-raid10" | "zfs (RAID10)")
        if [[ $disk_count -lt 4 ]]; then
            die "RAID10 requires at least 4 disks"
        fi
        if [[ $((disk_count % 2)) -ne 0 ]]; then
            die "RAID10 requires an even number of disks"
        fi

        # Create mirror pairs
        local i
        for ((i = 0; i < disk_count; i += 2)); do
            local disk1="${disks[i]}"
            local disk2="${disks[i + 1]}"

            # Check sizes of a mirror pair
            local disk1_info disk2_info
            disk1_info=$(get_disk_info "$disk1")
            disk2_info=$(get_disk_info "$disk2")
            local size1="${disk1_info%%:*}"
            local size2="${disk2_info%%:*}"
            zfs_mirror_size_check "$size1" "$size2"

            vdev_spec+=" mirror $disk1 $disk2"
        done
        vdev_spec="${vdev_spec# }" # Remove the leading space
        ;;

    "zfs-raidz1" | "zfs (RAIDZ-1)")
        if [[ $disk_count -lt 3 ]]; then
            die "RAIDZ-1 requires at least 3 disks"
        fi

        # Check disk sizes
        local expected_size
        local disk_info
        disk_info=$(get_disk_info "${disks[0]}")
        expected_size="${disk_info%%:*}"

        for disk in "${disks[@]}"; do
            disk_info=$(get_disk_info "$disk")
            local actual_size="${disk_info%%:*}"
            zfs_mirror_size_check "$expected_size" "$actual_size"
        done

        vdev_spec="raidz1 ${disks[*]}"
        ;;

    "zfs-raidz2" | "zfs (RAIDZ-2)")
        if [[ $disk_count -lt 4 ]]; then
            die "RAIDZ-2 requires at least 4 disks"
        fi

        # Check disk sizes
        local expected_size
        local disk_info
        disk_info=$(get_disk_info "${disks[0]}")
        expected_size="${disk_info%%:*}"

        for disk in "${disks[@]}"; do
            disk_info=$(get_disk_info "$disk")
            local actual_size="${disk_info%%:*}"
            zfs_mirror_size_check "$expected_size" "$actual_size"
        done

        vdev_spec="raidz2 ${disks[*]}"
        ;;

    "zfs-raidz3" | "zfs (RAIDZ-3)")
        if [[ $disk_count -lt 5 ]]; then
            die "RAIDZ-3 requires at least 5 disks"
        fi

        # Check disk sizes
        local expected_size
        local disk_info
        disk_info=$(get_disk_info "${disks[0]}")
        expected_size="${disk_info%%:*}"

        for disk in "${disks[@]}"; do
            disk_info=$(get_disk_info "$disk")
            local actual_size="${disk_info%%:*}"
            zfs_mirror_size_check "$expected_size" "$actual_size"
        done

        vdev_spec="raidz3 ${disks[*]}"
        ;;

    *)
        die "Unknown ZFS RAID type: $filesystem"
        ;;
    esac

    echo "$vdev_spec"
}

# =============================================================================
# DISK PREPARATION AND PARTITIONING
# =============================================================================

#######################################
# Wipe the disk and clear all data.
# Arguments:
#   Disk device path
#######################################
wipe_disk() {
    local disk="$1"

    log_info "Wiping disk $disk..."

    # Unmount any mounted partitions
    local mounted_parts part
    mounted_parts="$(lsblk -lno NAME,MOUNTPOINT "${disk}" | awk '$2 != "" {print "/dev/"$1}' || true)"

    if [[ -n $mounted_parts ]]; then
        while IFS= read -r part; do
            log_info "Unmounting $part"
            umount "$part" 2>/dev/null || true
        done <<<"$mounted_parts"
    fi

    # Deactivate any LVM volumes
    if command -v vgchange >/dev/null 2>&1; then
        vgchange -an 2>/dev/null || true
    fi

    # Clear ZFS labels
    if command -v zpool >/dev/null 2>&1; then
        zpool labelclear -f "$disk" 2>/dev/null || true
    fi

    # Wipe partition table and filesystem signatures
    wipefs -af "$disk" 2>/dev/null || true

    # Zero out the first and last few MB
    dd if=/dev/zero of="$disk" bs=1M count=10 2>/dev/null || true
    local disk_size_sectors
    disk_size_sectors="$(blockdev --getsz "${disk}")"
    dd if=/dev/zero of="${disk}" bs=1M count=10 \
        seek=$((disk_size_sectors / 2048 - 10)) 2>/dev/null || true

    # Inform the kernel of partition table changes and wait for the device to settle
    partprobe "$disk" 2>/dev/null || true
    # Trigger re-scan of the disk
    udevadm trigger --name-match="$disk" --action=change
    udevadm settle --timeout=5

    log_info "Disk $disk wiped successfully"
}

#######################################
# Create partitions on a bootable disk (Kubuntu 5-partition layout).
# Arguments:
#   Disk device path (can be by-id path)
#   Disk number (1, 2, 3, etc.)
#   Total number of disks
# Outputs:
#   Writes partition info to stdout
#######################################
partition_bootable_disk() {
    local disk="$1"
    local disk_num="$2"
    local total_disks="$3"

    log_info "Partitioning disk ${disk} (disk ${disk_num}/${total_disks}) with Kubuntu layout..."

    # Get disk info
    local disk_info
    disk_info=$(get_disk_info "$disk")
    local logical_bsize="${disk_info##*:}"

    # Check 4K sector compatibility
    legacy_bios_4k_check "$logical_bsize"

    # Create a GPT partition table
    sgdisk --clear "$disk"

    echo "Creating partitions on $disk:"

    # Standard partitions on ALL disks (consistent partition numbers)
    # Partition 1: EFI System Partition (512MB)
    echo "  - EFI System Partition (512MB)"
    sgdisk -n1:1M:+512M -t1:EF00 -c1:"EFI" "$disk"

    # Partition 2: Boot pool partition (2GB for bpool)
    echo "  - Boot pool partition (${boot_pool_size})"
    sgdisk -n2:0:+${boot_pool_size} -t2:BE00 -c2:"bpool" "$disk"

    # Partition 3: Root pool partition (400GB for rpool)
    echo "  - Root pool partition (${root_pool_size})"
    sgdisk -n3:0:+${root_pool_size} -t3:BF00 -c3:"rpool" "$disk"

    # Partition 4: Home pool partition (remaining space, or less on disk 1)
    if [[ $disk_num -eq 1 ]]; then
        # Leave space for swap at the end
        echo "  - Home pool partition (remaining space minus ${swap_size} for swap)"
        sgdisk -n4:0:-${swap_size} -t4:BF00 -c4:"hpool" "$disk"

        # Partition 5: Swap partition (8GB at the end - only on the first disk)
        echo "  - Swap partition (${swap_size})"
        sgdisk -n5:0:0 -t5:8200 -c5:"swap" "$disk"
    else
        # Use all remaining space for home
        echo "  - Home pool partition (remaining space)"
        sgdisk -n4:0:0 -t4:BF00 -c4:"hpool" "$disk"
    fi

    # Wait for partitions to be created
    partprobe "$disk"
    # Trigger udev to ensure all partition events are generated
    udevadm trigger --subsystem-match=block --action=change
    udevadm settle --timeout=10

    # Construct partition paths based on disk type
    local efi_part bpool_part rpool_part hpool_part swap_part

    if [[ $disk =~ ^/dev/disk/by-id/ ]]; then
        # For by-id paths, use -part suffix
        efi_part="${disk}-part1"
        bpool_part="${disk}-part2"
        rpool_part="${disk}-part3"
        hpool_part="${disk}-part4"
        if [[ $disk_num -eq 1 ]]; then
            swap_part="${disk}-part5"
        else
            swap_part="none"
        fi
    elif [[ $disk =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
        # For direct NVMe paths, use p suffix
        efi_part="${disk}p1"
        bpool_part="${disk}p2"
        rpool_part="${disk}p3"
        hpool_part="${disk}p4"
        if [[ $disk_num -eq 1 ]]; then
            swap_part="${disk}p5"
        else
            swap_part="none"
        fi
    else
        # For direct SATA/SAS paths, no suffix needed
        efi_part="${disk}1"
        bpool_part="${disk}2"
        rpool_part="${disk}3"
        hpool_part="${disk}4"
        if [[ $disk_num -eq 1 ]]; then
            swap_part="${disk}5"
        else
            swap_part="none"
        fi
    fi

    # Wait for specific partition devices to appear
    local part_to_check
    if [[ $disk_num -eq 1 ]]; then
        # Check all 5 partitions on disk 1
        for part_to_check in "$efi_part" "$bpool_part" "$rpool_part" "$hpool_part" "$swap_part"; do
            if [[ "$part_to_check" != "none" ]]; then
                log_info "Waiting for partition $part_to_check to appear..."
                if ! udevadm settle --exit-if-exists="$part_to_check" --timeout=10; then
                    log_warn "Timeout waiting for $part_to_check, continuing..."
                fi
            fi
        done
    else
        # Check 4 partitions on other disks
        for part_to_check in "$efi_part" "$bpool_part" "$rpool_part" "$hpool_part"; do
            log_info "Waiting for partition $part_to_check to appear..."
            if ! udevadm settle --exit-if-exists="$part_to_check" --timeout=10; then
                log_warn "Timeout waiting for $part_to_check, continuing..."
            fi
        done
    fi

    # Verify partitions exist
    if [[ $disk_num -eq 1 ]]; then
        for part in "$efi_part" "$bpool_part" "$rpool_part" "$hpool_part" "$swap_part"; do
            if [[ "$part" != "none" ]] && [[ ! -b "$part" ]]; then
                die "Partition $part was not created"
            fi
        done
    else
        for part in "$efi_part" "$bpool_part" "$rpool_part" "$hpool_part"; do
            if [[ ! -b "$part" ]]; then
                die "Partition $part was not created"
            fi
        done
    fi

    log_info "Disk $disk partitioned successfully"

    # Note about wasted space on non-swap disks
    if [[ $disk_num -ne 1 ]]; then
        log_info "Note: ${swap_size} will be unused on hpool due to partition size matching requirements"
    fi

    # Return consistent ordering: efi, bpool, rpool, hpool, swap (or none)
    echo "$efi_part:$bpool_part:$rpool_part:$hpool_part:$swap_part:$logical_bsize"
}

# =============================================================================
# ZFS POOL AND DATASET CREATION
# =============================================================================

#######################################
# Create a boot pool (bpool) with GRUB-compatible features.
# Arguments:
#   Vdev specification for boot partitions
#   UUID for dataset naming
#######################################
create_boot_pool() {
    local vdev_spec="$1"
    local uuid="$2"

    log_info "Creating boot pool (bpool) with GRUB-compatible features..."

    # Create a boot pool with limited features for GRUB compatibility
    syscmd "zpool create -f \\
        -o ashift=${zfs_opts["ashift"]} \\
        -o autotrim=on \\
        -o cachefile=/etc/zfs/zpool.cache \\
        -o compatibility=grub2 \\
        -o feature@livelist=enabled \\
        -o feature@zpool_checkpoint=enabled \\
        -O devices=off \\
        -O acltype=posixacl -O xattr=sa \\
        -O compression=lz4 \\
        -O normalization=formD \\
        -O relatime=on \\
        -O canmount=off -O mountpoint=/boot -R ${target_dir} \\
        ${boot_pool_name} $vdev_spec"

    # Create a dataset hierarchy
    syscmd "zfs create -o canmount=off -o mountpoint=none ${boot_pool_name}/BOOT"
    syscmd "zfs create -o mountpoint=/boot ${boot_pool_name}/BOOT/kubuntu_${uuid}"

    log_info "Boot pool created successfully"
}

#######################################
# Create an encrypted root pool (rpool).
# Arguments:
#   Vdev specification for root partitions
#   UUID for dataset naming
#######################################
create_root_pool() {
    local vdev_spec="$1"
    local uuid="$2"

    # Build encryption options based on user choice
    local encryption_opts=""
    if [[ "${zfs_encryption}" == "yes" ]]; then
        log_info "Creating encrypted root pool (rpool)..."
        echo "You will be prompted to enter an encryption passphrase for the root pool."
        echo "IMPORTANT: Remember this passphrase! You cannot recover data without it!"
        echo ""
        encryption_opts="-O encryption=on -O keylocation=prompt -O keyformat=passphrase"
    else
        log_info "Creating root pool (rpool) without encryption..."
    fi

    # Create a root pool
    syscmd "zpool create -f \\
        -o ashift=${zfs_opts["ashift"]} \\
        -o autotrim=on \\
        ${encryption_opts} \\
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \\
        -O compression=lz4 \\
        -O normalization=formD \\
        -O relatime=on \\
        -O canmount=off -O mountpoint=/ -R ${target_dir} \\
        ${root_pool_name} $vdev_spec"

    # Create a dataset hierarchy
    syscmd "zfs create -o canmount=off -o mountpoint=none ${root_pool_name}/ROOT"
    syscmd "zfs create -o mountpoint=/ \\
        -o com.ubuntu.zsys:bootfs=yes \\
        -o com.ubuntu.zsys:last-used=\"$(date +%s)\" \\
        ${root_pool_name}/ROOT/kubuntu_${uuid}"

    # Create system subdatasets
    create_system_subdatasets "$uuid"

    log_info "Root pool created successfully"
}

#######################################
# Create an encrypted home pool (hpool).
# Arguments:
#   Vdev specification for home partitions
#   UUID for dataset naming
#######################################
create_home_pool() {
    local vdev_spec="$1"
    local uuid="$2"

    # Build encryption options based on user choice
    local encryption_opts=""
    if [[ "${zfs_encryption}" == "yes" ]]; then
        log_info "Creating encrypted home pool (hpool)..."
        echo "You will be prompted to enter an encryption passphrase for the home pool."
        echo "IMPORTANT: Remember this passphrase! You cannot recover data without it!"
        echo ""
        encryption_opts="-O encryption=on -O keylocation=prompt -O keyformat=passphrase"
    else
        log_info "Creating home pool (hpool) without encryption..."
    fi

    # Create a home pool
    syscmd "zpool create -f \\
        -o ashift=${zfs_opts["ashift"]} \\
        -o autotrim=on \\
        ${encryption_opts} \\
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \\
        -O compression=lz4 \\
        -O normalization=formD \\
        -O relatime=on \\
        -O canmount=off -O mountpoint=/home -R ${target_dir} \\
        ${home_pool_name} $vdev_spec"

    # Create a dataset hierarchy
    syscmd "zfs create -o canmount=off -o mountpoint=none ${home_pool_name}/HOME"
    syscmd "zfs create -o mountpoint=/home ${home_pool_name}/HOME/kubuntu_${uuid}"

    log_info "Home pool created successfully"
}

#######################################
# Create system subdatasets for the root pool.
# Arguments:
#   UUID for dataset naming
#######################################
create_system_subdatasets() {
    local uuid="$1"

    log_info "Creating system subdatasets..."

    # System component datasets
    syscmd "zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \\
        ${root_pool_name}/ROOT/kubuntu_${uuid}/usr"
    syscmd "zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \\
        ${root_pool_name}/ROOT/kubuntu_${uuid}/var"

    # Critical system directories
    local dataset
    for dataset in var/lib var/log var/spool var/cache var/tmp \
        var/lib/apt var/lib/dpkg var/snap \
        var/lib/AccountsService var/lib/NetworkManager \
        usr/local srv; do
        syscmd "zfs create ${root_pool_name}/ROOT/kubuntu_${uuid}/${dataset}"
    done

    chmod 1777 "${target_dir}"/var/tmp

    # Create user data datasets
    syscmd "zfs create -o canmount=off -o mountpoint=/ ${root_pool_name}/USERDATA"
    syscmd "zfs create -o com.ubuntu.zsys:bootfs-datasets=\"${root_pool_name}/ROOT/kubuntu_${uuid}\" \\
        -o canmount=on -o mountpoint=/root \\
        ${root_pool_name}/USERDATA/root_${uuid}"

    chmod 700 "${target_dir}"/root
}

#######################################
# Setup ZFS module configuration.
# Arguments:
#   Target directory
#######################################
setup_zfs_module_config() {
    local target_dir="$1"

    log_info "Setting up ZFS module configuration..."

    local modprobe_dir="$target_dir/etc/modprobe.d"
    mkdir -p "$modprobe_dir"

    # Calculate ARC max in bytes
    local arc_max_bytes=$((zfs_opts["arc_max"] * 1024 * 1024))

    # Write ZFS module configuration
    cat >"$modprobe_dir/zfs.conf" <<EOF
# ZFS module configuration
# Generated by Kubuntu ZFS installer v${script_version} on $(date)

# Maximum ARC size (${zfs_opts["arc_max"]}MB)
options zfs zfs_arc_max=$arc_max_bytes

# Additional tuning for desktop use
options zfs zfs_vdev_scheduler=deadline
options zfs zfs_prefetch_disable=0
EOF

    log_info "ZFS module configuration written to $modprobe_dir/zfs.conf"
}

# =============================================================================
# FILESYSTEM CREATION AND MOUNTING
# =============================================================================

#######################################
# Create EFI filesystems on boot partitions.
# Arguments:
#   Reference to a bootdev_info array
#######################################
create_efi_filesystems() {
    local -n bootdev_info=$1

    log_info "Creating EFI filesystems..."

    for device_info in "${bootdev_info[@]}"; do
        IFS=':' read -r efi_part bpool_part rpool_part hpool_part swap_part logical_bsize <<<"$device_info"

        # Determine vfat options based on logical block size
        local vfat_opts="-F32"
        if [[ $logical_bsize == "4096" ]]; then
            vfat_opts="-s1 -F32"
        fi

        echo "Creating FAT32 filesystem on ${efi_part}..."
        log_info "Creating FAT32 filesystem on ${efi_part} " \
            "(logical block size: ${logical_bsize})"
        syscmd "mkfs.vfat $vfat_opts $efi_part"
    done

    log_info "EFI filesystems created successfully"
}

# =============================================================================
# SYSTEM INSTALLATION
# =============================================================================

#######################################
# Mount Kubuntu filesystems for installation.
# Arguments:
#   None
#######################################
mount_kubuntu_filesystems() {

    log_info "Mounting Kubuntu ZFS filesystems..."

    # Filesystems should already be mounted at /mnt from pool creation
    # Just create additional mount points
    mkdir -p "$target_dir/boot/efi"
    mkdir -p "$target_dir/var/lib"
    mkdir -p "$target_dir/mnt/hostrun"
    mkdir -p "$target_dir/run"

    # Create runtime filesystem
    mount -t tmpfs tmpfs "$target_dir/run"
    mkdir "$target_dir/run/lock"

    log_info "Filesystems mounted successfully"
}

#######################################
# Install a Kubuntu system with a desktop environment.
# Arguments:
#   Target directory
#   UUID for dataset naming
#######################################
install_kubuntu_system() {
    local target_dir="$1"
    local uuid="$2"

    log_info "Installing Kubuntu system with KDE desktop..."

    # Create basic filesystem structure
    mkdir -p "$target_dir"/{dev,proc,sys,tmp,var/cache/apt/archives}

    # Mount essential filesystems for chroot
    mount -t proc proc "$target_dir/proc"
    mount -t sysfs sysfs "$target_dir/sys"
    mount -t devtmpfs devtmpfs "$target_dir/dev"
    mount -t devpts devpts "$target_dir/dev/pts"
    mount -t tmpfs tmpfs "$target_dir/tmp"

    # Mount efivarfs for EFI operations in chroot
    if [[ -d /sys/firmware/efi/efivars ]] && ! mountpoint -q "$target_dir/sys/firmware/efi/efivars" 2>/dev/null; then
        mount -t efivarfs efivarfs "$target_dir/sys/firmware/efi/efivars"
        log_info "Mounted efivarfs for EFI operations"
    fi

    # Install base system using debootstrap
    local mirror="https://archive.ubuntu.com/ubuntu"
    local release="${ubuntu_version}"

    log_info "Running debootstrap for Ubuntu ${release}..."
    debootstrap --arch=amd64 \
        --include=openssh-server,locales,sudo,wget,curl,nano,vim,cryptsetup \
        "${release}" "${target_dir}" "${mirror}"

    # Configure hostname
    echo "${default_hostname}" >"$target_dir/etc/hostname"

    # Configure hosts file
    cat >"$target_dir/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${default_hostname}
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Configure apt sources
    cat >"$target_dir/etc/apt/sources.list" <<EOF
deb http://archive.ubuntu.com/ubuntu ${release} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${release}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${release}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${release}-security main restricted universe multiverse
EOF

    # Configure locale
    echo "en_US.UTF-8 UTF-8" >"$target_dir/etc/locale.gen"
    chroot "$target_dir" locale-gen
    echo 'LANG="en_US.UTF-8"' >"$target_dir/etc/default/locale"

    # Update and install ZFS utilities
    chroot "$target_dir" apt-get update
    chroot "$target_dir" apt-get install -y zfsutils-linux zfs-initramfs

    # Install KDE desktop environment
    log_info "Installing KDE Plasma desktop environment..."
    chroot "$target_dir" apt-get install -y kubuntu-desktop-minimal plasma-workspace-wayland

    # Create a default user account
    log_info "Creating user account: ${username}"
    chroot "$target_dir" useradd -m -s /bin/bash -G sudo,adm,cdrom,dip,plugdev,lpadmin,sambashare "${username}"

    # Set the user password (prompt for it)
    echo "Please set a password for user ${username}:"
    while ! chroot "$target_dir" passwd "${username}"; do
        echo "Password setting failed. Please try again:"
    done

    # Create a user's home dataset on hpool
    if [[ -n "${uuid}" ]]; then
        syscmd "zfs create -o mountpoint=/home/${username} ${home_pool_name}/HOME/kubuntu_${uuid}/${username}"
        chroot "$target_dir" chown -R "${username}:${username}" "/home/${username}"
    fi

    # Enable passwordless sudo for initial setup (optional - can be removed for security)
    echo "${username} ALL=(ALL) NOPASSWD: ALL" > "$target_dir/etc/sudoers.d/99-installer"
    chmod 440 "$target_dir/etc/sudoers.d/99-installer"

    # Copy ZFS cache
    mkdir -p "$target_dir/etc/zfs"
    cp /etc/zfs/zpool.cache "$target_dir/etc/zfs/"

    # Configure network
    local interface
    interface="$(ip route | grep default | awk '{print $5}' | head -1)"

    mkdir -p "$target_dir/etc/netplan"

    # Use NetworkManager for Kubuntu desktop (handles dynamic interfaces better)
    # But if we detected a specific interface, also configure it
    if [[ -n "$interface" ]]; then
        log_info "Detected primary network interface: $interface"
        cat >"$target_dir/etc/netplan/01-network-manager-all.yaml" <<EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    $interface:
      dhcp4: true
      dhcp6: true
EOF
    else
        # Fallback to generic NetworkManager config
        log_info "No specific network interface detected, using generic NetworkManager config"
        cat >"$target_dir/etc/netplan/01-network-manager-all.yaml" <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
    fi

    log_info "Kubuntu system installation completed"
}

# =============================================================================
# BOOTLOADER CONFIGURATION
# =============================================================================

#######################################
# Install and configure the Kubuntu bootloader.
# Arguments:
#   Target directory
#   UUID for dataset naming
#   Reference to disk_info_array
#######################################
install_kubuntu_bootloader() {
    local target_dir="$1"
    local uuid="$2"
    local -n disk_info_ref=$3

    log_info "Installing and configuring Kubuntu bootloader..."

    # Install GRUB and related packages
    chroot "${target_dir}" apt-get install -y \
        grub-efi-amd64 grub-efi-amd64-signed \
        linux-image-generic shim-signed

    # Mount EFI partitions and setup redundancy
    local efi_mount_count=0
    for device_info in "${disk_info_ref[@]}"; do
        IFS=':' read -r efi_part bpool_part rpool_part hpool_part swap_part logical_bsize <<<"$device_info"

        if [[ $efi_mount_count -eq 0 ]]; then
            # Primary EFI partition
            log_info "Mounting primary EFI partition $efi_part"
            mount "$efi_part" "$target_dir/boot/efi"

            # Add to fstab
            local efi_uuid
            efi_uuid="$(blkid -s UUID -o value "$efi_part")"
            echo "UUID=${efi_uuid} /boot/efi vfat defaults 0 1" >>"$target_dir/etc/fstab"
        else
            # Backup EFI partitions
            local efi_backup_dir="$target_dir/boot/efi${efi_mount_count}"
            mkdir -p "$efi_backup_dir"

            # Add to fstab as noauto
            local efi_uuid
            efi_uuid="$(blkid -s UUID -o value "$efi_part")"
            echo "UUID=${efi_uuid} /boot/efi${efi_mount_count} vfat noauto,defaults 0 0" >>"$target_dir/etc/fstab"
        fi

        ((efi_mount_count++))
    done

    # Configure GRUB for ZFS with encryption
    configure_kubuntu_grub "$target_dir" "$uuid"

    # Install GRUB to all EFI partitions for redundancy
    log_info "Installing GRUB with redundancy..."

    # Primary installation
    chroot "${target_dir}" grub-install --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=kubuntu --recheck --no-floppy

    # Backup installations
    efi_mount_count=1
    for device_info in "${disk_info_ref[@]:1}"; do
        local efi_backup_dir="/boot/efi${efi_mount_count}"

        # Mount backup partition
        IFS=':' read -r efi_part bpool_part rpool_part hpool_part swap_part logical_bsize <<<"$device_info"
        mount "$efi_part" "$target_dir${efi_backup_dir}"

        # Install GRUB backup
        chroot "${target_dir}" grub-install --target=x86_64-efi \
            --efi-directory="${efi_backup_dir}" \
            --bootloader-id="kubuntu-backup${efi_mount_count}" --recheck --no-floppy

        # Unmount backup partition
        umount "$target_dir${efi_backup_dir}"

        ((efi_mount_count++))
    done

    # Update initramfs
    chroot "$target_dir" update-initramfs -c -k all

    # Update GRUB configuration
    chroot "$target_dir" update-grub

    log_info "Kubuntu bootloader installation completed"
}

#######################################
# Configure GRUB for Kubuntu ZFS boot with encryption.
# Arguments:
#   Target directory
#   UUID for dataset naming
#######################################
configure_kubuntu_grub() {
    local target_dir="$1"
    local uuid="$2"

    log_info "Configuring GRUB for Kubuntu ZFS with encryption..."

    # Configure GRUB defaults
    cat >"$target_dir/etc/default/grub" <<EOF
# GRUB configuration for Kubuntu ZFS root
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Kubuntu"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash init_on_alloc=0"
GRUB_CMDLINE_LINUX="root=ZFS=${root_pool_name}/ROOT/kubuntu_${uuid}"
GRUB_TERMINAL=console
GRUB_ENABLE_CRYPTODISK=true
GRUB_PRELOAD_MODULES="zfs"
GRUB_RECORDFAIL_TIMEOUT=5

# Enable os-prober to detect other operating systems
GRUB_DISABLE_OS_PROBER=true
EOF

    # Enable ZFS support in initramfs
    echo "zfs" >>"$target_dir/etc/initramfs-tools/modules"

    # Configure ZFS for boot
    mkdir -p "$target_dir/etc/zfs/zfs-list.cache"
    touch "$target_dir/etc/zfs/zfs-list.cache"/{bpool,rpool,hpool}

    log_info "GRUB configuration for Kubuntu ZFS completed"
}

#######################################
# Finalize Kubuntu installation.
# Arguments:
#   Target directory
#   Reference to disk_info_array
#######################################
finalize_kubuntu_installation() {
    local target_dir="$1"
    local -n disk_info_final=$2

    log_info "Finalizing Kubuntu installation..."

    # Configure swap (first disk only, which has swap partition)
    local swap_configured=0
    for device_info in "${disk_info_final[@]}"; do
        if [[ $swap_configured -eq 0 ]]; then
            IFS=':' read -r efi_part bpool_part rpool_part hpool_part swap_part logical_bsize <<<"$device_info"

            # Only configure swap if it exists (not "none")
            if [[ "$swap_part" != "none" ]] && [[ -b "$swap_part" ]]; then
                log_info "Setting up swap on $swap_part"
                mkswap -f -L swap1 "$swap_part"

                local swap_uuid
                swap_uuid="$(blkid -s UUID -o value "$swap_part")"
                echo "UUID=${swap_uuid} none swap defaults,pri=1 0 0" >>"$target_dir/etc/fstab"

                swap_configured=1
            fi
        fi
    done

    # Configure services
    chroot "$target_dir" systemctl enable sddm
    chroot "$target_dir" systemctl enable NetworkManager
    chroot "$target_dir" systemctl enable zfs-import-cache
    chroot "$target_dir" systemctl enable zfs-mount
    chroot "$target_dir" systemctl enable zfs.target

    # Set up autologin for the default user (optional - comment out for security)
    mkdir -p "$target_dir/etc/sddm.conf.d"
    cat >"$target_dir/etc/sddm.conf.d/autologin.conf" <<EOF
[Autologin]
User=${username}
Session=plasma
EOF

    # Create ZFS mount helper script for encrypted pools
    cat >"$target_dir/usr/local/bin/mount-encrypted-pools.sh" <<'SCRIPT'
#!/bin/bash
# Helper script to mount encrypted pools at boot

echo "Loading encryption keys for ZFS pools..."

# Load key for rpool if needed
if zfs get -H -o value keystatus rpool >/dev/null 2>&1 && \
   zfs get -H -o value keystatus rpool | grep -q "unavailable"; then
    echo "Unlocking rpool..."
    zfs load-key rpool
fi

# Load key for hpool if needed
if zfs get -H -o value keystatus hpool >/dev/null 2>&1 && \
   zfs get -H -o value keystatus hpool | grep -q "unavailable"; then
    echo "Unlocking hpool..."
    zfs load-key hpool
fi

# Mount all datasets
zfs mount -a

echo "ZFS pools mounted successfully"
SCRIPT

    chmod +x "$target_dir/usr/local/bin/mount-encrypted-pools.sh"

    # Re-enable sync for normal operation
    syscmd "zfs set sync=standard ${boot_pool_name}"
    syscmd "zfs set sync=standard ${root_pool_name}"
    syscmd "zfs set sync=standard ${home_pool_name}"

    # Unmount filesystems
    umount -R "$target_dir/boot/efi"* 2>/dev/null || true
    # Explicitly unmount efivarfs if mounted
    if mountpoint -q "$target_dir/sys/firmware/efi/efivars" 2>/dev/null; then
        umount "$target_dir/sys/firmware/efi/efivars" 2>/dev/null || true
    fi
    umount -R "$target_dir/dev" 2>/dev/null || true
    umount -R "$target_dir/proc" 2>/dev/null || true
    umount -R "$target_dir/sys" 2>/dev/null || true
    umount -R "$target_dir/tmp" 2>/dev/null || true
    umount -R "$target_dir/run" 2>/dev/null || true

    # Export pools
    syscmd "zfs umount -a"
    syscmd "zpool export ${boot_pool_name}"
    syscmd "zpool export ${root_pool_name}"
    syscmd "zpool export ${home_pool_name}"

    log_info "Kubuntu installation finalized. System is ready for reboot."
}

# =============================================================================
# MAIN INSTALLATION PROCESS
# =============================================================================

#######################################
# Extract data and perform installation.
# Globals:
#   Various pool-related constants and target_dir
# Arguments:
#   RAID type
#   Reference to a selected_disks array
#######################################
extract_data() {
    local raid_type="$1"
    local -n selected_disks_ref=$2

    update_progress 0 "Starting Kubuntu ZFS installation"

    # Generate unique installation UUID
    local uuid
    uuid="$(dd if=/dev/urandom bs=1 count=100 2>/dev/null | tr -dc 'a-z0-9' | cut -c-6)"
    log_info "Installation UUID: ${uuid}"

    # Phase 1: Preparation
    update_progress 5 "Loading ZFS module and checking requirements"
    load_zfs_module
    calculate_arc_max

    # Phase 2: Disk preparation
    update_progress 10 "Preparing disks with Kubuntu partition layout"
    local disk_info_array=()
    local bpool_parts=()
    local rpool_parts=()
    local hpool_parts=()
    local disk_num=1
    local total_disks=${#selected_disks_ref[@]}

    for disk in "${selected_disks_ref[@]}"; do
        log_info "Processing disk ${disk_num}/${total_disks}: $disk"
        wipe_disk "$disk"

        local partition_info
        partition_info=$(partition_bootable_disk "$disk" "$disk_num" "$total_disks")
        disk_info_array+=("$partition_info")

        # Extract partition paths
        IFS=':' read -r efi_part bpool_part rpool_part hpool_part swap_part logical_bsize <<<"$partition_info"
        bpool_parts+=("$bpool_part")
        rpool_parts+=("$rpool_part")
        hpool_parts+=("$hpool_part")

        log_info "Disk $disk partitioned: EFI=$efi_part, BPOOL=$bpool_part, RPOOL=$rpool_part, HPOOL=$hpool_part"
        ((disk_num++))
    done

    # Wait for udev to process all disk changes
    log_info "Waiting for all device nodes to settle..."
    udevadm settle --timeout=10

    # Additional sync to ensure all disk operations are complete
    sync

    # Phase 3: Create three ZFS pools
    update_progress 25 "Creating ZFS pools (bpool, rpool, hpool)"

    # Check for existing pools before creating new ones
    check_existing_pools

    # Get vdev specifications for each pool
    local bpool_vdev rpool_vdev hpool_vdev
    bpool_vdev=$(get_zfs_raid_setup "$raid_type" "${bpool_parts[@]}")
    rpool_vdev=$(get_zfs_raid_setup "$raid_type" "${rpool_parts[@]}")
    hpool_vdev=$(get_zfs_raid_setup "$raid_type" "${hpool_parts[@]}")

    # Create a boot pool (unencrypted, GRUB-compatible)
    update_progress 30 "Creating boot pool (bpool)"
    create_boot_pool "$bpool_vdev" "$uuid"

    # Create a root pool (encrypted)
    update_progress 40 "Creating encrypted root pool (rpool)"
    create_root_pool "$rpool_vdev" "$uuid"

    # Create a home pool (encrypted)
    update_progress 50 "Creating encrypted home pool (hpool)"
    create_home_pool "$hpool_vdev" "$uuid"

    # Phase 4: Filesystem setup
    update_progress 60 "Creating and mounting filesystems"
    create_efi_filesystems disk_info_array
    mount_kubuntu_filesystems

    # Phase 5: System installation
    update_progress 70 "Installing Kubuntu base system and desktop"
    install_kubuntu_system "$target_dir" "$uuid"

    # Phase 6: ZFS configuration
    update_progress 80 "Configuring ZFS"
    setup_zfs_module_config "$target_dir"

    # Phase 7: Bootloader installation
    update_progress 85 "Installing and configuring bootloader"
    install_kubuntu_bootloader "${target_dir}" "$uuid" disk_info_array

    # Phase 8: Final configuration
    update_progress 95 "Finalizing installation"
    finalize_kubuntu_installation "$target_dir" disk_info_array

    update_progress 100 "Kubuntu ZFS installation completed successfully"
}

# =============================================================================
# USER INTERFACE AND CONFIGURATION
# =============================================================================

#######################################
# Display script usage information.
# Globals:
#   script_name
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout
#######################################
show_usage() {
    cat <<EOF
Usage: $script_name [OPTIONS]

Kubuntu ZFS installation script with 3-pool encrypted design.

OPTIONS:
    -r, --raid-type TYPE     RAID type: raid0, raid1, raid10,
                             raidz1, raidz2, raidz3
    -d, --disks DISK,DISK    Comma-separated list of disks (/dev/sdX)
    -t, --target-dir DIR     Target directory (default: ${default_target_dir})
    -u, --username USER      Username for the new user (default: ${default_username})
    -h, --help               Show this help message

RAID TYPES:
    raid0    - Stripe across disks (1+ disks, no redundancy)
    raid1    - Mirror disks (2+ disks, 1 disk failure tolerance)
    raid10   - Striped mirrors (4+ even disks, 1 disk per mirror failure
               tolerance)
    raidz1   - Single parity (3+ disks, 1 disk failure tolerance)
    raidz2   - Double parity (4+ disks, 2 disk failure tolerance)
    raidz3   - Triple parity (5+ disks, 3 disk failure tolerance)

EXAMPLES:
    # Install with RAIDZ1 on 3 disks
    $script_name --raid-type raidz1 --disks /dev/sda,/dev/sdb,/dev/sdc

    # Install with RAID1 mirror on 2 disks, custom pool name
    $script_name --pool-name tank --raid-type raid1 \\
        --disks /dev/nvme0n1,/dev/nvme1n1

EOF
}

#######################################
# Parse command line arguments.
# Globals:
#   pool_name, raid_type, selected_disks, hdsize, target_dir
# Arguments:
#   Command line arguments
#######################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -r | --raid-type)
            raid_type="zfs-$2"
            shift 2
            ;;
        -d | --disks)
            IFS=',' read -ra selected_disks <<<"$2"
            shift 2
            ;;
        -t | --target-dir)
            target_dir="$2"
            shift 2
            ;;
        -u | --username)
            username="$2"
            shift 2
            ;;
        -h | --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_usage
            exit 1
            ;;
        esac
    done
}

#######################################
# Interactive setup for disk and RAID configuration.
# Globals:
#   Multiple global variables
# Arguments:
#   None
#######################################
interactive_setup() {
    echo "=== Kubuntu ZFS Installation Setup ==="
    echo "Log file: ${log_file}"
    echo

    # Discover available disks
    echo "Discovering available disks..."
    local available_disks
    mapfile -t available_disks < <(discover_disks)

    if ((${#available_disks[@]} == 0)); then
        die "No suitable disks found for installation"
    fi

    # Parse disk information and create arrays
    local display_names=()
    local by_id_paths=()
    local disk_sizes=()
    local disk_models=()
    local disk_entry

    # Store disk info in arrays (but don't display yet)
    for disk_entry in "${available_disks[@]}"; do
        local dev_path by_id_path size_gb model os_info
        IFS=':' read -r dev_path by_id_path size_gb model os_info <<<"$disk_entry"
        display_names+=("$dev_path")
        by_id_paths+=("$by_id_path")
        disk_sizes+=("$size_gb")
        disk_models+=("$model")
    done

    # RAID type selection
    if [[ -z $raid_type ]]; then
        local num_disks=${#available_disks[@]}
        local valid_options=()
        local recommended=""

        echo "Select RAID configuration for your ZFS array:"
        echo

        # RAID0 - always available
        if [[ $num_disks -eq 1 ]]; then
            echo "  1) RAID0 (stripe, no redundancy, 1+ disks) [RECOMMENDED]"
            recommended="1"
        else
            echo "  1) RAID0 (stripe, no redundancy, 1+ disks)"
        fi
        valid_options+=(1)

        # RAID1 - needs 2+ disks
        if [[ $num_disks -ge 2 ]]; then
            if [[ $num_disks -eq 2 ]]; then
                echo "  2) RAID1 (mirror, 1 disk failure tolerance, 2+ disks) [RECOMMENDED]"
                recommended="2"
            else
                echo "  2) RAID1 (mirror, 1 disk failure tolerance, 2+ disks)"
            fi
            valid_options+=(2)
        else
            echo "  2) RAID1 (mirror, 1 disk failure tolerance, 2+ disks) (not enough disks)"
        fi

        # RAID10 - needs 4+ even disks
        if [[ $num_disks -ge 4 ]] && [[ $((num_disks % 2)) -eq 0 ]]; then
            echo "  3) RAID10 (striped mirrors, 1 disk per mirror failure, 4+ even disks)"
            valid_options+=(3)
            recommended="3"
        else
            echo "  3) RAID10 (striped mirrors, 1 disk per mirror failure, 4+ even disks) (not enough disks)"
        fi

        # RAIDZ1 - needs 3+ disks
        if [[ $num_disks -ge 3 ]]; then
            if [[ $num_disks -eq 3 ]]; then
                echo "  4) RAIDZ1 (single parity, 1 disk failure tolerance, 3+ disks) [RECOMMENDED]"
                recommended="4"
            else
                echo "  4) RAIDZ1 (single parity, 1 disk failure tolerance, 3+ disks)"
            fi
            valid_options+=(4)
        else
            echo "  4) RAIDZ1 (single parity, 1 disk failure tolerance, 3+ disks) (not enough disks)"
        fi

        # RAIDZ2 - needs 4+ disks
        if [[ $num_disks -ge 4 ]]; then
            if [[ $num_disks -ge 4 ]] && [[ $num_disks -le 6 ]] && [[ $recommended != "3" ]]; then
                echo "  5) RAIDZ2 (double parity, 2 disk failure tolerance, 4+ disks) [RECOMMENDED]"
                recommended="5"
            else
                echo "  5) RAIDZ2 (double parity, 2 disk failure tolerance, 4+ disks)"
            fi
            valid_options+=(5)
        else
            echo "  5) RAIDZ2 (double parity, 2 disk failure tolerance, 4+ disks) (not enough disks)"
        fi

        # RAIDZ3 - needs 5+ disks
        if [[ $num_disks -ge 5 ]]; then
            if [[ $num_disks -ge 7 ]]; then
                echo "  6) RAIDZ3 (triple parity, 3 disk failure tolerance, 5+ disks) [RECOMMENDED]"
                recommended="6"
            else
                echo "  6) RAIDZ3 (triple parity, 3 disk failure tolerance, 5+ disks)"
            fi
            valid_options+=(6)
        else
            echo "  6) RAIDZ3 (triple parity, 3 disk failure tolerance, 5+ disks) (not enough disks)"
        fi
        echo

        # Build valid options string for prompt
        local valid_str="${valid_options[*]}"
        valid_str="${valid_str// /,}"

        local raid_choice
        read -r -p "ZFS array configuration? ($valid_str) [$recommended]: " raid_choice
        raid_choice="${raid_choice:-$recommended}"

        # Validate choice is in valid options
        local valid_choice=false
        local opt
        for opt in "${valid_options[@]}"; do
            if [[ "$raid_choice" == "$opt" ]]; then
                valid_choice=true
                break
            fi
        done

        if [[ $valid_choice == false ]]; then
            die "Invalid RAID type selection: ${raid_choice}. Valid options: $valid_str"
        fi

        case "${raid_choice}" in
        1) raid_type="zfs-raid0" ;;
        2) raid_type="zfs-raid1" ;;
        3) raid_type="zfs-raid10" ;;
        4) raid_type="zfs-raidz1" ;;
        5) raid_type="zfs-raidz2" ;;
        6) raid_type="zfs-raidz3" ;;
        esac
    fi

    # Validate minimum disk requirements
    local required_disks
    case "${raid_type}" in
    "zfs-raid0") required_disks=1 ;;
    "zfs-raid1") required_disks=2 ;;
    "zfs-raid10") required_disks=4 ;;
    "zfs-raidz1") required_disks=3 ;;
    "zfs-raidz2") required_disks=4 ;;
    "zfs-raidz3") required_disks=5 ;;
    esac

    echo
    echo "You need ${required_disks} disks for this array type."
    echo

    echo "Available disks:"
    echo
    local k=1
    for disk_entry in "${available_disks[@]}"; do
        IFS=':' read -r dev_path by_id_path size_gb model os_info <<<"$disk_entry"

        # Build the display string
        local display_str="  $k) $dev_path - ${size_gb}GB - $model"
        if [[ -n "$os_info" ]]; then
            display_str="${display_str} (${os_info} detected)"
        fi
        echo "$display_str"
        ((k++))
    done
    echo

    # Disk selection - store by-id paths for ZFS operations
    local selected_display=()
    local selected_by_id=()

    if ((${#selected_disks[@]} == 0)); then
        # Smart selection: if available disks exactly match requirements, auto-select all
        if ((${#available_disks[@]} == required_disks)); then
            echo "Exact match detected - auto-selecting all ${required_disks} disks for ${raid_type#zfs-}:"
            echo
            for ((k=0; k<${#display_names[@]}; k++)); do
                echo "  ✓ ${display_names[$k]}"
            done
            echo
            selected_display=("${display_names[@]}")
            selected_by_id=("${by_id_paths[@]}")
        else
            # Manual selection needed
            local disk_numbers
            read -r -p "Choose disks: " disk_numbers

            local num
            for num in $disk_numbers; do
                if ((num > 0 && num <= ${#available_disks[@]})); then
                    local idx=$((num - 1))
                    selected_display+=("${display_names[$idx]}")
                    selected_by_id+=("${by_id_paths[$idx]}")
                else
                    die "Invalid disk number: $num"
                fi
            done
        fi

        # Store the by-id paths for ZFS operations
        selected_disks=("${selected_by_id[@]}")
    fi

    # Validate disk selection for RAID type
    if ((${#selected_disks[@]} < required_disks)); then
        die "RAID type ${raid_type#zfs-} requires at least ${required_disks} " \
            "disks, but only ${#selected_disks[@]} selected"
    fi

    if [[ ${raid_type} == "zfs-raid10" ]] && ((${#selected_disks[@]} % 2 != 0)); then
        die "RAID10 requires an even number of disks"
    fi

    echo
    echo "Installation Configuration:"
    echo "  RAID type: ${raid_type#zfs-}"
    echo "  Selected disks for display:"
    local j
    for ((j=0; j<${#selected_display[@]}; j++)); do
        echo "    - ${selected_display[$j]}"
    done
    echo "  Using by-id paths for ZFS:"
    for ((j=0; j<${#selected_disks[@]}; j++)); do
        echo "    - ${selected_disks[$j]}"
    done
    echo "  Target directory: $target_dir"
    echo "  EFI Partitions: 512MB on EACH disk for redundancy (${#selected_disks[@]} total)"
    echo "  3 Pools: bpool (boot), rpool (root), hpool (home)"

    # Report wasted space due to swap partition on disk 1 only
    if [[ ${#selected_disks[@]} -gt 1 ]]; then
        local wasted_space_gb=$(( (${#selected_disks[@]} - 1) * 8 ))
        echo ""
        echo "Note: Due to ZFS partition size matching requirements, approximately ${wasted_space_gb}GB"
        echo "      will be unused across the array (swap is only on disk 1)."
    fi
    echo

    # Ask about encryption
    local use_encryption="no"
    echo "Note: The boot pool cannot be encrypted (GRUB limitation)"
    if confirm "Enable encryption for rpool and hpool?"; then
        use_encryption="yes"
        echo
        echo "Updated Installation Configuration:"
        echo "  RAID type: ${raid_type#zfs-}"
        echo "  Selected disks: ${#selected_disks[@]}"
        echo "  EFI Partitions: 512MB on EACH disk for redundancy (${#selected_disks[@]} total)"
        echo "  3 Pools: bpool (boot), rpool (root, ENCRYPTED), hpool (home, ENCRYPTED)"
        echo
        echo "You'll be prompted for passphrases during pool creation."
    else
        use_encryption="no"
        echo "Encryption will be disabled."
    fi
    echo

    echo "WARNING: This will DESTROY all data on the selected disks!"
    echo

    # Final confirmation before destructive operations
    if ! confirm "Proceed with installation? This action CANNOT be undone!"; then
        echo "Installation cancelled by user."
        exit 0
    fi

    # Export encryption choice for pool creation functions
    export zfs_encryption="${use_encryption}"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

#######################################
# Main installation function.
# Globals:
#   All global variables
# Arguments:
#   Command line arguments
# Returns:
#   0 on success, exits on failure
#######################################
main() {
    if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
        return 0
    fi

    # Variable to track if cleanup has already run
    cleanup_done=0

    # Set up signal handlers for proper cleanup
    trap 'if [[ $cleanup_done -eq 0 ]]; then cleanup_done=1; cleanup_on_error; fi' EXIT
    trap 'echo ""; log_error "Installation interrupted by user"; cleanup_done=1; cleanup_on_error; exit 130' INT TERM

    readonly temp_dir="/tmp/zfs-install-$"

    # Setup logging and temp directory
    setup_logging
    mkdir -p "$temp_dir"

    script_name=""
    script_name="$(basename "$0")"
    readonly script_name

    # System Configuration
    raid_type=""
    # Script version and metadata
    readonly script_version="1.1"
    readonly ubuntu_version="${UBUNTU_VERSION:-noble}"
    readonly default_username="${DEFAULT_USERNAME:-kubu}"
    readonly default_hostname="${DEFAULT_HOSTNAME:-kubuntu-zfs}"

    # Allow username to be overridden via environment or command line
    username="${default_username}"

    # Installation target directory
    readonly default_target_dir="/mnt"
    target_dir="${default_target_dir}"

    # Pool sizes (Kubuntu-style)
    readonly boot_pool_size="2G"
    readonly root_pool_size="400G"
    readonly swap_size="8G"

    # Pool names (Kubuntu 3-pool design)
    readonly boot_pool_name="bpool"
    readonly root_pool_name="rpool"
    readonly home_pool_name="hpool"

    # Logging configuration
    readonly log_dir="./logs"
    readonly max_log_files=5

    selected_disks=()

    log_info "Starting $script_name"
    log_info "Command line: $*"

    # Parse arguments
    parse_arguments "$@"

    # Check requirements
    check_requirements

    # Interactive setup if install not fully configured via arguments
    if [[ -z ${raid_type} ]] || ((${#selected_disks[@]} == 0)); then
        interactive_setup
    fi

    # Final validation
    if [[ -z ${raid_type} ]] || ((${#selected_disks[@]} == 0)); then
        die "Missing required configuration parameters"
    fi

    # Show the final configuration
    log_info "Final configuration:"
    log_info "  RAID type: $raid_type"
    log_info "  Selected disks: ${selected_disks[*]}"
    log_info "  Target directory: $target_dir"
    log_info "  Pools: bpool, rpool (encrypted), hpool (encrypted)"

    # Perform installation
    extract_data "$raid_type" selected_disks

    # Clear the trap since we completed successfully
    trap - EXIT

    echo
    echo "================================================================"
    echo "Kubuntu ZFS Installation Completed Successfully!"
    echo "================================================================"
    echo "Pools created:"
    echo "  Boot pool: ${boot_pool_name} (unencrypted, GRUB-compatible)"
    echo "  Root pool: ${root_pool_name} (encrypted)"
    echo "  Home pool: ${home_pool_name} (encrypted)"
    echo ""
    echo "RAID type: ${raid_type#zfs-}"
    echo "Selected disks: ${selected_disks[*]}"
    echo "Log file: $log_file"
    echo ""
    echo "IMPORTANT:"
    echo "1. Save your encryption passphrases!"
    echo "2. The system will prompt for passphrases at boot"
    echo "3. Remove installation media before reboot"
    echo ""
    echo "Login credentials:"
    echo "  Username: ${username}"
    echo "  Password: (as set during installation)"
    echo ""
    echo "The system is ready for reboot."
    echo "================================================================"
}

main "$@"
