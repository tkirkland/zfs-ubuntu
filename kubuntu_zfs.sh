#!/bin/bash
#
# Kubuntu 3-Disk RAIDZ1 ZFS Installation Script
# Automated installation of Kubuntu with ZFS RAIDZ1 across 3 disks
# Based on Ubuntu ZFS documentation and best practices
# Version 2.0 - Fixed for NVMe and persistent paths

set -euo pipefail

################################################################################
# Constants and Environment Variables
################################################################################

readonly SCRIPT_VERSION="1.1"
readonly UBUNTU_VERSION="${UBUNTU_VERSION:-noble}"
readonly DEFAULT_USERNAME="${DEFAULT_USERNAME:-kubu}"
readonly DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-kubuntu-zfs}"

# Pool sizes
readonly BOOT_POOL_SIZE="2G"
readonly ROOT_POOL_SIZE="400G"
readonly SWAP_SIZE="8G"

# Installation paths and files
readonly LOG_DIR="/tmp/kubuntu-zfs-install"
readonly CHECKPOINT_FILE="${LOG_DIR}/checkpoint"
readonly INSTALL_VARS_FILE="/mnt/root/install-vars.sh"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

################################################################################
# Utility Functions
################################################################################

#######################################
# Print colored log message to stdout and log file
# Globals:
#   GREEN, NC, log_file
# Arguments:
#   Message to log
#######################################
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "${log_file}"
}

#######################################
# Print warning message
# Globals:
#   YELLOW, NC, log_file
# Arguments:
#   Warning message
#######################################
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${log_file}"
}

#######################################
# Print error message
# Globals:
#   RED, NC, log_file
# Arguments:
#   Error message
#######################################
log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${log_file}"
}

#######################################
# Print section header
# Globals:
#   CYAN, NC
# Arguments:
#   Section title
#######################################
log_section() {
    echo -e "\n${CYAN}============================================================"
    echo -e "${CYAN}  ${1}"
    echo -e "${CYAN}============================================================${NC}\n"
}

#######################################
# Print installation banner
# Globals:
#   MAGENTA, NC, SCRIPT_VERSION
# Arguments:
#   None
#######################################
print_banner() {
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     Kubuntu 3-Disk RAIDZ1 ZFS Installation Script        ║"
    echo -e "║                    Version ${BLUE}${SCRIPT_VERSION}${MAGENTA}                           ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
}

#######################################
# Error handler for script failures
# Globals:
#   log_file
# Arguments:
#   Exit code
#   Line number
# Returns:
#   Exits with provided exit code
#######################################
error_handler() {
    local exit_code="$1"
    local line_number="$2"

    log_error "Installation failed with exit code ${exit_code} at line ${line_number}"
    log_error "Check the log file: ${log_file}"

    # Attempt cleanup
    log_info "Attempting to clean up ZFS pools..."
    zpool export bpool 2>/dev/null && log_info "Exported bpool" || true
    zpool export rpool 2>/dev/null && log_info "Exported rpool" || true
    zpool export hpool 2>/dev/null && log_info "Exported hpool" || true

    exit "${exit_code}"
}

#######################################
# Save installation checkpoint
# Globals:
#   CHECKPOINT_FILE
# Arguments:
#   Checkpoint name
#######################################
save_checkpoint() {
    echo "$1" >"${CHECKPOINT_FILE}"
    log_info "Checkpoint saved: $1"
}

#######################################
# Load last checkpoint
# Globals:
#   CHECKPOINT_FILE
# Arguments:
#   None
# Outputs:
#   Checkpoint name or "none"
#######################################
load_checkpoint() {
    if [[ -f ${CHECKPOINT_FILE} ]]; then
        cat "${CHECKPOINT_FILE}"
    else
        echo "none"
    fi
}

#######################################
# Check if phase should be skipped
# Globals:
#   None
# Arguments:
#   Phase name
# Returns:
#   0 if should skip, 1 otherwise
#######################################
should_skip_phase() {
    local phase="$1"
    local checkpoint
    checkpoint="$(load_checkpoint)"

    if [[ ${checkpoint} == "none" ]]; then
        return 1
    fi

    # Extract phase numbers for comparison
    local checkpoint_num="${checkpoint#phase}"
    local current_num="${phase#phase}"

    if [[ ${checkpoint_num} -ge ${current_num} ]]; then
        log_info "Skipping ${phase} (already completed)"
        return 0
    fi

    return 1
}

#######################################
# Prompt for confirmation
# Globals:
#   None
# Arguments:
#   Prompt message
# Returns:
#   0 for yes, 1 for no
#######################################
confirm() {
    local prompt="$1"
    local response

    while true; do
        read -r -p "${prompt} (yes/no): " response
        case "${response}" in
        yes | YES | y | Y) return 0 ;;
        no | NO | n | N) return 1 ;;
        *) echo "Please answer 'yes' or 'no'" ;;
        esac
    done
}

#######################################
# Check for root privileges
# Globals:
#   EUID
# Arguments:
#   None
# Returns:
#   Exits if not root
#######################################
check_root() {
    if ((EUID != 0)); then
        log_error "This script must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
}

#######################################
# Check network connectivity
# Globals:
#   None
# Arguments:
#   None
#######################################
check_network() {
    log_info "Checking network connectivity..."

    if ! ping -c 1 archive.ubuntu.com >/dev/null 2>&1; then
        log_warn "No network connectivity to Ubuntu archives"
        if ! confirm "Continue without network? (NOT recommended)"; then
            exit 1
        fi
    else
        log_info "Network connectivity verified"
    fi
}

#######################################
# Wait for partition devices to be created
# Globals:
#   None
# Arguments:
#   Disk path
#######################################
wait_for_partitions() {
    local disk="$1"

    log_info "Waiting for partition devices to be created for ${disk}..."

    # Trigger udev to process the new partitions
    partprobe "${disk}" 2>/dev/null || true
    udevadm settle --timeout=10

    # Additional wait for devices
    sleep 2

    # Verify at least the first partition exists
    local part1="${disk}-part1"
    local retries=5
    while [[ ! -e ${part1} ]] && [[ ${retries} -gt 0 ]]; do
        log_info "Waiting for ${part1} to appear... (${retries} retries left)"
        sleep 2
        partprobe "${disk}" 2>/dev/null || true
        udevadm settle --timeout=10
        retries=$((retries - 1))
    done

    if [[ ! -e ${part1} ]]; then
        log_error "Partition ${part1} not found after partitioning"
        log_error "Available devices for ${disk}:"
        ls -la "${disk}"* 2>/dev/null || true
        ls -la /dev/disk/by-id/ | grep "$(basename "${disk}")" || true
        return 1
    fi

    log_info "Partitions created successfully for ${disk}"
}

#######################################
# Convert device path to by-id path
# Globals:
#   None
# Arguments:
#   Device path
# Returns:
#   by-id path or original if not found
#######################################
get_by_id_path() {
    local device="$1"
    local by_id_path=""

    # If already a by-id path, return as-is
    if [[ ${device} =~ ^/dev/disk/by-(id|uuid|path|partuuid)/ ]]; then
        echo "${device}"
        return 0
    fi

    # Try to find the by-id equivalent
    local basename_dev
    basename_dev="$(basename "${device}")"

    # Look for various by-id formats
    for prefix in "ata-" "nvme-" "scsi-" "wwn-"; do
        by_id_path="$(find /dev/disk/by-id/ -name "${prefix}*" -lname "*${basename_dev}" 2>/dev/null | grep -v part | head -1)"
        if [[ -n ${by_id_path} ]]; then
            echo "${by_id_path}"
            return 0
        fi
    done

    # If no by-id path found, return original
    log_warn "Could not find by-id path for ${device}"
    echo "${device}"
}

#######################################
# Validate disk for ZFS usage
# Globals:
#   None
# Arguments:
#   Disk path
# Returns:
#   0 if valid, 1 otherwise
#######################################
validate_disk() {
    local disk="$1"

    log_info "Validating ${disk}..."

    # Check if device exists and is a block device
    if [[ ! -b ${disk} ]]; then
        log_error "${disk} is not a block device or doesn't exist"
        return 1
    fi

    # Check if disk has any mounted partitions
    if lsblk -n -o MOUNTPOINT "${disk}" 2>/dev/null | grep -q '^/'; then
        log_error "${disk} has mounted partitions"
        lsblk "${disk}" | grep -E "[a-zA-Z].*/$"
        return 1
    fi

    # Check minimum size (167GB per disk)
    local size
    size="$(lsblk -b -n -d -o SIZE "${disk}" 2>/dev/null | head -1)"
    if [[ -z ${size} ]]; then
        log_error "Cannot determine size of ${disk}"
        return 1
    fi

    local size_gb=$((size / 1024 / 1024 / 1024))
    if ((size_gb < 167)); then
        log_error "${disk} is only ${size_gb}GB (minimum 167GB required)"
        return 1
    fi

    # Check if disk is in use
    if fuser "${disk}" &>/dev/null; then
        log_warn "${disk} is currently in use by another process"
    fi

    # Check disk health if possible
    check_disk_health "${disk}"

    log_info "${disk} validated: ${size_gb}GB available"
    return 0
}

#######################################
# Check disk health status
# Globals:
#   None
# Arguments:
#   Disk path
#######################################
check_disk_health() {
    local disk="$1"
    local real_device

    # Resolve symlink to real device for health checks
    real_device="$(readlink -f "${disk}")"

    if [[ ${real_device} == *nvme* ]]; then
        if command -v nvme &>/dev/null; then
            local health_status
            health_status="$(nvme smart-log "${real_device}" 2>/dev/null |
                grep "critical_warning" | awk '{print $3}' || echo "unknown")"
            if [[ ${health_status} != "0" ]] && [[ ${health_status} != "unknown" ]]; then
                log_warn "NVMe disk ${disk} shows critical warning: ${health_status}"
            fi
        fi
    else
        if command -v smartctl &>/dev/null; then
            local health_status
            health_status="$(smartctl -H "${real_device}" 2>/dev/null |
                grep "SMART overall-health" | awk '{print $6}' || echo "unknown")"
            if [[ ${health_status} != "PASSED" ]] && [[ ${health_status} != "unknown" ]]; then
                log_warn "SMART health check failed for ${disk}: ${health_status}"
            fi
        fi
    fi
}

#######################################
# Detect optimal ashift value for disks
# Globals:
#   disk1, ashift
# Arguments:
#   None
#######################################
detect_ashift() {
    local real_device
    real_device="$(readlink -f "${disk1}")"

    if [[ ${real_device} == *nvme* ]]; then
        # Try to detect actual sector size for NVMe
        if command -v nvme >/dev/null 2>&1; then
            local sector_size
            sector_size="$(nvme id-ns "${real_device}" -n 1 2>/dev/null |
                grep "LBA Format" | grep "in use" | awk '{print $5}' | tr -d '()' || echo "")"

            if [[ ${sector_size} == "8192" ]]; then
                ashift=13
            else
                ashift=12 # Default to 4K for NVMe
            fi
            log_info "NVMe detected: Using ashift=${ashift} for ${sector_size:-4096} byte sectors"
        else
            ashift=12
            log_info "NVMe detected: Using default ashift=${ashift}"
        fi
    else
        ashift=12 # Standard for modern SATA SSDs
        log_info "SATA/SAS detected: Using ashift=${ashift} for 4096 byte sectors"
    fi
}

################################################################################
# Phase 1: Environment Preparation
################################################################################

#######################################
# Prepare installation environment
# Globals:
#   LOG_DIR
# Arguments:
#   None
#######################################
phase1_environment_preparation() {
    log_section "Phase 1/9: Environment Preparation"

    if should_skip_phase "phase1"; then
        return 0
    fi

    # Create log directory
    mkdir -p "${LOG_DIR}"

    # Check for root privileges
    check_root

    # Check network connectivity
    check_network

    # Update package repositories
    log_info "Updating package repositories..."
    apt update

    # Install required packages
    log_info "Installing required packages..."
    if ! apt install --yes gdisk zfsutils-linux rsync parted; then
        log_error "Failed to install required packages"
        exit 1
    fi

    # Install NVMe tools if NVMe disks are detected
    if ls /dev/nvme* >/dev/null 2>&1; then
        log_info "NVMe disks detected, installing nvme-cli..."
        apt install --yes nvme-cli || log_warn "Failed to install nvme-cli"
    fi

    # Install SMART tools
    apt install --yes smartmontools || log_warn "Failed to install smartmontools"

    # Stop ZFS Event Daemon to prevent conflicts
    systemctl stop zed 2>/dev/null || true

    save_checkpoint "phase1"
    log_info "Phase 1 completed successfully"
}

################################################################################
# Phase 2: Disk Selection
################################################################################

#######################################
# Display available disks for selection
# Globals:
#   None
# Arguments:
#   None
#######################################
display_available_disks() {
    log_info "Scanning for available disks..."

    echo -e "\n${BLUE}Available disks:${NC}\n"
    echo "=================================================================================="
    printf "%-20s %-10s %-15s %s\n" "DEVICE" "SIZE" "TYPE" "BY-ID PATH"
    echo "=================================================================================="

    # Display all block devices
    local device size model by_id real_type

    # Process all disk devices
    for device in $(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print $1}'); do
        device="/dev/${device}"
        if [[ ! -b ${device} ]]; then
            continue
        fi

        size="$(lsblk -b -d -n -o SIZE "${device}" 2>/dev/null | head -1)"
        size_gb=$((size / 1024 / 1024 / 1024))
        model="$(lsblk -d -n -o MODEL "${device}" 2>/dev/null | head -1 | tr -s ' ')"

        # Determine device type
        if [[ ${device} == *nvme* ]]; then
            real_type="NVMe"
        elif [[ ${device} == *sd* ]]; then
            real_type="SATA/SAS"
        else
            real_type="Other"
        fi

        # Find by-id path
        by_id="$(get_by_id_path "${device}")"

        printf "%-20s %-10s %-15s %s\n" "${device}" "${size_gb}GB" "${real_type}" "${by_id}"

        if [[ -n ${model} ]]; then
            echo "  Model: ${model}"
        fi
    done

    echo "=================================================================================="
    echo ""
}

#######################################
# Select three disks for installation
# Globals:
#   disk1, disk2, disk3
# Arguments:
#   None
#######################################
phase2_disk_selection() {
    log_section "Phase 2/9: Disk Selection"

    if should_skip_phase "phase2"; then
        # Load saved disk selections
        if [[ -f ${INSTALL_VARS_FILE} ]]; then
            # shellcheck source=/dev/null
            source "${INSTALL_VARS_FILE}"
        fi
        return 0
    fi

    display_available_disks

    echo -e "${YELLOW}IMPORTANT: You must use /dev/disk/by-id/ paths for reliability!${NC}"
    echo "The script will help convert regular paths to by-id paths."
    echo ""
    echo "Please select three disks for RAIDZ1 configuration."
    echo ""

    # Function to read and validate disk selection
    select_disk() {
        local prompt="$1"
        local selected_disk

        while true; do
            read -r -p "${prompt}: " selected_disk

            # Check if disk exists
            if [[ ! -b ${selected_disk} ]]; then
                log_error "Device ${selected_disk} does not exist"
                continue
            fi

            # Convert to by-id path if needed
            if [[ ! ${selected_disk} =~ ^/dev/disk/by- ]]; then
                local by_id_disk
                by_id_disk="$(get_by_id_path "${selected_disk}")"

                if [[ ${by_id_disk} != "${selected_disk}" ]]; then
                    log_info "Found by-id path: ${by_id_disk}"
                    if confirm "Use ${by_id_disk} instead of ${selected_disk}?"; then
                        selected_disk="${by_id_disk}"
                    else
                        log_warn "Using non-persistent path ${selected_disk} (NOT RECOMMENDED)"
                        if ! confirm "Are you sure you want to continue with ${selected_disk}?"; then
                            continue
                        fi
                    fi
                else
                    log_warn "Could not find by-id path for ${selected_disk}"
                    log_warn "Using device path directly (NOT RECOMMENDED)"
                    if ! confirm "Continue with ${selected_disk}?"; then
                        continue
                    fi
                fi
            fi

            echo "${selected_disk}"
            return 0
        done
    }

    # Select three disks
    disk1="$(select_disk "Enter first disk (DISK1)")"
    disk2="$(select_disk "Enter second disk (DISK2)")"
    disk3="$(select_disk "Enter third disk (DISK3)")"

    # Check for duplicate selections
    if [[ ${disk1} == "${disk2}" ]] || [[ ${disk2} == "${disk3}" ]] || [[ ${disk1} == "${disk3}" ]]; then
        log_error "You selected the same disk multiple times!"
        exit 1
    fi

    # Validate all selected disks
    local disk
    for disk in "${disk1}" "${disk2}" "${disk3}"; do
        if ! validate_disk "${disk}"; then
            log_error "Disk validation failed: ${disk}"
            exit 1
        fi
    done

    # Check if all disks are same size
    check_disk_size_consistency

    # Detect optimal ashift
    detect_ashift

    # Display final selection
    echo ""
    log_info "Selected disks:"
    log_info "  DISK1: ${disk1}"
    log_info "  DISK2: ${disk2}"
    log_info "  DISK3: ${disk3}"
    echo ""

    if ! confirm "Proceed with these disks?"; then
        exit 1
    fi

    save_checkpoint "phase2"
    log_info "Phase 2 completed successfully"
}

#######################################
# Check if selected disks are the same size
# Globals:
#   disk1, disk2, disk3
# Arguments:
#   None
#######################################
check_disk_size_consistency() {
    local size1 size2 size3

    size1="$(lsblk -b -n -d -o SIZE "${disk1}" | head -1)"
    size2="$(lsblk -b -n -d -o SIZE "${disk2}" | head -1)"
    size3="$(lsblk -b -n -d -o SIZE "${disk3}" | head -1)"

    if [[ ${size1} -ne ${size2} ]] || [[ ${size2} -ne ${size3} ]]; then
        log_warn "Disks are different sizes. RAIDZ1 will be limited to smallest disk."
        echo "  Disk1: $((size1 / 1024 / 1024 / 1024))GB"
        echo "  Disk2: $((size2 / 1024 / 1024 / 1024))GB"
        echo "  Disk3: $((size3 / 1024 / 1024 / 1024))GB"

        if ! confirm "Continue with different sized disks?"; then
            exit 1
        fi
    else
        log_info "All disks are the same size: $((size1 / 1024 / 1024 / 1024))GB"
    fi
}

################################################################################
# Phase 3: Disk Preparation
################################################################################

#######################################
# Clear existing data from disks
# Globals:
#   disk1, disk2, disk3
# Arguments:
#   None
#######################################
clear_existing_data() {
    local disk

    log_warn "WARNING: This will DESTROY all data on the selected disks!"
    if ! confirm "Continue with disk preparation?"; then
        exit 1
    fi

    # Disable any swap partitions
    swapoff --all

    # Clear existing signatures and partitions
    for disk in "${disk1}" "${disk2}" "${disk3}"; do
        log_info "Clearing ${disk}..."

        # Wipe filesystem signatures
        wipefs -a "${disk}" 2>/dev/null || true

        # Clear partition table
        sgdisk --zap-all "${disk}"

        # Clear any LVM metadata
        dd if=/dev/zero of="${disk}" bs=1M count=10 2>/dev/null || true

        # Inform kernel of changes
        partprobe "${disk}" 2>/dev/null || true
    done

    # Wait for devices to settle
    udevadm settle --timeout=10
    sleep 2
}

#######################################
# Create partition layout on disks
# Globals:
#   disk1, disk2, disk3, SWAP_SIZE, BOOT_POOL_SIZE, ROOT_POOL_SIZE
# Arguments:
#   None
#######################################
create_partition_layout() {
    local disk

    for disk in "${disk1}" "${disk2}" "${disk3}"; do
        log_info "Partitioning ${disk}..."

        # Create a new GPT partition table
        sgdisk -og "${disk}"

        # EFI System Partition (512MB)
        sgdisk -n1:1M:+512M -t1:EF00 -c1:"EFI" "${disk}"

        # Reserved space for swap (8GB on all disks for consistency)
        sgdisk -n2:0:+${SWAP_SIZE} -t2:8200 -c2:"swap" "${disk}"

        # Boot Pool Partition (2GB)
        sgdisk -n3:0:+${BOOT_POOL_SIZE} -t3:BE00 -c3:"bpool" "${disk}"

        # Root Pool Partition (400GB)
        sgdisk -n4:0:+${ROOT_POOL_SIZE} -t4:BF00 -c4:"rpool" "${disk}"

        # Home Pool Partition (remaining space)
        sgdisk -n5:0:0 -t5:BF00 -c5:"hpool" "${disk}"

        # Print partition table for verification
        sgdisk -p "${disk}"

        # Wait for partitions to be created
        wait_for_partitions "${disk}"
    done
}

#######################################
# Format EFI partitions
# Globals:
#   disk1, disk2, disk3
# Arguments:
#   None
#######################################
format_efi_partitions() {
    local disk num=1

    for disk in "${disk1}" "${disk2}" "${disk3}"; do
        local efi_part="${disk}-part1"

        log_info "Formatting EFI partition on ${disk}..."

        # Check if partition exists
        if [[ ! -b ${efi_part} ]]; then
            log_error "EFI partition ${efi_part} does not exist!"
            return 1
        fi

        # Format as FAT32
        mkdosfs -F 32 -s 1 -n "EFI${num}" "${efi_part}"

        num=$((num + 1))
    done
}

#######################################
# Prepare disks for ZFS installation
# Globals:
#   disk1, disk2, disk3
# Arguments:
#   None
#######################################
phase3_disk_preparation() {
    log_section "Phase 3/9: Disk Preparation"

    if should_skip_phase "phase3"; then
        return 0
    fi

    clear_existing_data
    create_partition_layout
    format_efi_partitions

    save_checkpoint "phase3"
    log_info "Phase 3 completed successfully"
}

################################################################################
# Phase 4: ZFS Pool Creation
################################################################################

#######################################
# Create boot pool
# Globals:
#   disk1, disk2, disk3, ashift
# Arguments:
#   None
#######################################
create_boot_pool() {
    log_info "Creating boot pool (bpool)..."

    local part3_1="${disk1}-part3"
    local part3_2="${disk2}-part3"
    local part3_3="${disk3}-part3"

    # Verify partitions exist
    for part in "${part3_1}" "${part3_2}" "${part3_3}"; do
        if [[ ! -b ${part} ]]; then
            log_error "Partition ${part} does not exist!"
            return 1
        fi
    done

    zpool create \
        -o ashift="${ashift}" \
        -o autotrim=on \
        -o cachefile=/etc/zfs/zpool.cache \
        -o compatibility=grub2 \
        -o feature@livelist=enabled \
        -o feature@zpool_checkpoint=enabled \
        -O devices=off \
        -O acltype=posixacl -O xattr=sa \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off -O mountpoint=/boot -R /mnt \
        bpool raidz1 "${part3_1}" "${part3_2}" "${part3_3}"

    # Verify creation
    if ! zpool list bpool >/dev/null 2>&1; then
        log_error "Failed to create bpool"
        exit 1
    fi

    zpool status bpool
    log_info "Boot pool created successfully"
}

#######################################
# Create root pool
# Globals:
#   disk1, disk2, disk3, ashift
# Arguments:
#   None
#######################################
create_root_pool() {
    log_info "Creating root pool (rpool)..."

    local part4_1="${disk1}-part4"
    local part4_2="${disk2}-part4"
    local part4_3="${disk3}-part4"

    # Verify partitions exist
    for part in "${part4_1}" "${part4_2}" "${part4_3}"; do
        if [[ ! -b ${part} ]]; then
            log_error "Partition ${part} does not exist!"
            return 1
        fi
    done

    echo "You will be prompted to enter an encryption passphrase for the root pool."
    echo "IMPORTANT: Remember this passphrase! You cannot recover data without it!"
    echo ""

    zpool create \
        -o ashift="${ashift}" \
        -o autotrim=on \
        -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off -O mountpoint=/ -R /mnt \
        rpool raidz1 "${part4_1}" "${part4_2}" "${part4_3}"

    # Verify creation
    if ! zpool list rpool >/dev/null 2>&1; then
        log_error "Failed to create rpool"
        exit 1
    fi

    zpool status rpool
    log_info "Root pool created successfully"
}

#######################################
# Create home pool
# Globals:
#   disk1, disk2, disk3, ashift
# Arguments:
#   None
#######################################
create_home_pool() {
    log_info "Creating home pool (hpool)..."

    local part5_1="${disk1}-part5"
    local part5_2="${disk2}-part5"
    local part5_3="${disk3}-part5"

    # Verify partitions exist
    for part in "${part5_1}" "${part5_2}" "${part5_3}"; do
        if [[ ! -b ${part} ]]; then
            log_error "Partition ${part} does not exist!"
            return 1
        fi
    done

    echo "You will be prompted to enter an encryption passphrase for the home pool."
    echo "IMPORTANT: Remember this passphrase! You cannot recover data without it!"
    echo ""

    zpool create \
        -o ashift="${ashift}" \
        -o autotrim=on \
        -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off -O mountpoint=/home -R /mnt \
        hpool raidz1 "${part5_1}" "${part5_2}" "${part5_3}"

    # Verify creation
    if ! zpool list hpool >/dev/null 2>&1; then
        log_error "Failed to create hpool"
        exit 1
    fi

    zpool status hpool
    log_info "Home pool created successfully"
}

#######################################
# Create ZFS pools
# Globals:
#   Various pool-related variables
# Arguments:
#   None
#######################################
phase4_zfs_pool_creation() {
    log_section "Phase 4/9: ZFS Pool Creation"

    if should_skip_phase "phase4"; then
        return 0
    fi

    create_boot_pool
    create_root_pool
    create_home_pool

    # Backup encryption information
    backup_encryption_keys

    save_checkpoint "phase4"
    log_info "Phase 4 completed successfully"
}

#######################################
# Backup encryption keys and information
# Globals:
#   None
# Arguments:
#   None
#######################################
backup_encryption_keys() {
    log_warn "CRITICAL: Backup your encryption passphrases!"

    mkdir -p /mnt/root/zfs-keys-backup

    cat >/mnt/root/zfs-keys-backup/CRITICAL-README.txt <<'END'
ZFS Encryption Backup Information
==================================

1. SAVE THE PASSPHRASES YOU ENTERED FOR RPOOL AND HPOOL!
   Without these passphrases, your data cannot be recovered.

2. Copy this entire directory to external media immediately:
   /root/zfs-keys-backup/

3. Store the backup in a safe, separate location.

4. The system will prompt for these passphrases at boot time.
END

    # Save encryption metadata
    zfs get encryption,keyformat,keylocation,keystatus rpool \
        >/mnt/root/zfs-keys-backup/rpool-encryption.txt
    zfs get encryption,keyformat,keylocation,keystatus hpool \
        >/mnt/root/zfs-keys-backup/hpool-encryption.txt

    log_warn "Encryption keys information saved to /mnt/root/zfs-keys-backup/"
    echo "Press ENTER after backing up encryption keys..."
    read -r
}

################################################################################
# Phase 5: Dataset Creation
################################################################################

#######################################
# Create ZFS datasets
# Globals:
#   uuid
# Arguments:
#   None
#######################################
phase5_dataset_creation() {
    log_section "Phase 5/9: Dataset Creation"

    if should_skip_phase "phase5"; then
        # Load uuid if skipping
        if [[ -f ${INSTALL_VARS_FILE} ]]; then
            # shellcheck source=/dev/null
            source "${INSTALL_VARS_FILE}"
        fi
        return 0
    fi

    # Generate unique installation ID
    uuid="$(dd if=/dev/urandom bs=1 count=100 2>/dev/null |
        tr -dc 'a-z0-9' | cut -c-6)"

    log_info "Installation UUID: ${uuid}"

    # Create container datasets
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT
    zfs create -o canmount=off -o mountpoint=none hpool/HOME

    # Create system datasets
    zfs create -o mountpoint=/ \
        -o com.ubuntu.zsys:bootfs=yes \
        -o com.ubuntu.zsys:last-used="$(date +%s)" \
        "rpool/ROOT/kubuntu_${uuid}"

    zfs create -o mountpoint=/boot "bpool/BOOT/kubuntu_${uuid}"
    zfs create -o mountpoint=/home "hpool/HOME/kubuntu_${uuid}"

    # Create system subdatasets
    create_system_subdatasets

    # Create user data datasets
    create_userdata_datasets

    save_checkpoint "phase5"
    log_info "Phase 5 completed successfully"
}

#######################################
# Create system subdatasets
# Globals:
#   uuid
# Arguments:
#   None
#######################################
create_system_subdatasets() {
    log_info "Creating system subdatasets..."

    # System component datasets
    zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \
        "rpool/ROOT/kubuntu_${uuid}/usr"
    zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \
        "rpool/ROOT/kubuntu_${uuid}/var"

    # Critical system directories
    local dataset
    for dataset in var/lib var/log var/spool var/cache var/tmp \
        var/lib/apt var/lib/dpkg var/snap \
        var/lib/AccountsService var/lib/NetworkManager \
        usr/local srv; do
        zfs create "rpool/ROOT/kubuntu_${uuid}/${dataset}"
    done

    chmod 1777 /mnt/var/tmp
}

#######################################
# Create user data datasets
# Globals:
#   uuid
# Arguments:
#   None
#######################################
create_userdata_datasets() {
    log_info "Creating user data datasets..."

    zfs create -o canmount=off -o mountpoint=/ rpool/USERDATA
    zfs create -o com.ubuntu.zsys:bootfs-datasets="rpool/ROOT/kubuntu_${uuid}" \
        -o canmount=on -o mountpoint=/root \
        "rpool/USERDATA/root_${uuid}"

    chmod 700 /mnt/root

    # Create runtime filesystem
    mkdir /mnt/run
    mount -t tmpfs tmpfs /mnt/run
    mkdir /mnt/run/lock
}

################################################################################
# Phase 6: System Installation
################################################################################

#######################################
# Extract Kubuntu base system
# Globals:
#   None
# Arguments:
#   None
#######################################
extract_base_system() {
    log_info "Extracting Kubuntu base system..."

    # Find and mount Kubuntu ISO
    mkdir -p /mnt/cdrom

    local iso_source
    iso_source="$(findmnt -n -o SOURCE / | grep -o '^[^\[]\+')"

    if [[ -z ${iso_source} ]]; then
        iso_source="$(blkid -L "Kubuntu" || blkid -L "Ubuntu" || echo "")"
    fi

    if [[ -z ${iso_source} ]]; then
        log_error "Cannot find Kubuntu ISO source"
        echo "Available devices:"
        lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT | grep -E "iso9660|udf"
        read -r -p "Enter the device containing the Kubuntu ISO: " iso_source
    fi

    # Mount the ISO
    if [[ -b ${iso_source} ]]; then
        mount "${iso_source}" /mnt/cdrom
    elif [[ -f ${iso_source} ]]; then
        mount -o loop "${iso_source}" /mnt/cdrom
    else
        log_error "Cannot mount ISO source: ${iso_source}"
        exit 1
    fi

    # Verify squashfs exists
    local squashfs="/mnt/cdrom/casper/filesystem.squashfs"
    if [[ ! -f ${squashfs} ]]; then
        log_error "Cannot find filesystem.squashfs"
        exit 1
    fi

    # Mount and copy filesystem
    mkdir -p /mnt/source
    mount -t squashfs "${squashfs}" /mnt/source

    log_info "Copying system files (this may take 10-15 minutes)..."
    rsync -av --progress /mnt/source/ /mnt/ \
        --exclude=/proc --exclude=/sys --exclude=/dev \
        --exclude=/run --exclude=/mnt --exclude=/media \
        --exclude=/tmp --exclude=/var/tmp

    # Cleanup
    umount /mnt/source
    rmdir /mnt/source
    umount /mnt/cdrom
}

#######################################
# Configure system environment
# Globals:
#   HOSTNAME, UBUNTU_VERSION, username, uuid, disk1, disk2, disk3, ashift
# Arguments:
#   None
#######################################
configure_system_environment() {
    log_info "Configuring system environment..."

    # Copy ZFS cache
    mkdir -p /mnt/etc/zfs
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/

    # Set hostname
    echo "${HOSTNAME}" >/mnt/etc/hostname
    cat >/mnt/etc/hosts <<END
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
END

    # Configure package sources
    cat >/mnt/etc/apt/sources.list <<END
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_VERSION} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_VERSION}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_VERSION}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${UBUNTU_VERSION}-security main restricted universe multiverse
END

    # Configure network
    local interface
    interface="$(ip route | grep default | awk '{print $5}' | head -1)"

    mkdir -p /mnt/etc/netplan
    cat >/mnt/etc/netplan/01-netcfg.yaml <<END
network:
  version: 2
  ethernets:
    ${interface}:
      dhcp4: true
END

    # Save installation variables
    cat >"${INSTALL_VARS_FILE}" <<END
# Installation variables - DO NOT DELETE
export DISK1="${disk1}"
export DISK2="${disk2}"
export DISK3="${disk3}"
export UUID="${uuid}"
export HOSTNAME="${HOSTNAME}"
export USERNAME="${username}"
export ASHIFT="${ashift}"
END
}

#######################################
# Install and configure system
# Globals:
#   Various installation variables
# Arguments:
#   None
#######################################
phase6_system_installation() {
    log_section "Phase 6/9: System Installation"

    if should_skip_phase "phase6"; then
        return 0
    fi

    extract_base_system
    configure_system_environment

    save_checkpoint "phase6"
    log_info "Phase 6 completed successfully"
}

################################################################################
# Phase 7-9: Chroot Operations
################################################################################

#######################################
# Execute commands in chroot environment
# Globals:
#   INSTALL_VARS_FILE
# Arguments:
#   None
#######################################
phase7_8_9_chroot_operations() {
    log_section "Phases 7-9: Chroot Configuration"

    # Mount virtual filesystems
    mount --make-private --rbind /dev /mnt/dev
    mount --make-private --rbind /proc /mnt/proc
    mount --make-private --rbind /sys /mnt/sys

    # Create and execute chroot script
    create_chroot_script

    # Execute in chroot
    chroot /mnt /bin/bash /root/chroot-install.sh

    # Cleanup
    cleanup_and_export

    save_checkpoint "phase9"
    log_info "All phases completed successfully"
}

#######################################
# Create the script to run inside chroot
# Globals:
#   Various installation variables
# Arguments:
#   None
#######################################
create_chroot_script() {
    cat >/mnt/root/chroot-install.sh <<'CHROOT_SCRIPT'
#!/bin/bash
set -euo pipefail

# Load installation variables
source /root/install-vars.sh

echo "Starting chroot configuration..."

# Phase 7: Configure Base System

# Check network
if ! ping -c 1 archive.ubuntu.com >/dev/null 2>&1; then
  echo "WARNING: No network connectivity in chroot"
fi

# Update package database
apt update

# Configure locales and timezone
dpkg-reconfigure locales
dpkg-reconfigure tzdata
dpkg-reconfigure keyboard-configuration

# Install essential packages
apt install --yes nano vim cryptsetup

# Configure EFI
mkdir -p /boot/efi

# Get UUID of first EFI partition
EFI1_UUID="$(blkid -s UUID -o value ${DISK1}-part1)"
echo "UUID=${EFI1_UUID} /boot/efi vfat defaults 0 0" >> /etc/fstab
mount /boot/efi

# Additional EFI mounts for redundancy
mkdir -p /boot/efi2 /boot/efi3
EFI2_UUID="$(blkid -s UUID -o value ${DISK2}-part1)"
EFI3_UUID="$(blkid -s UUID -o value ${DISK3}-part1)"
echo "UUID=${EFI2_UUID} /boot/efi2 vfat noauto,defaults 0 0" >> /etc/fstab
echo "UUID=${EFI3_UUID} /boot/efi3 vfat noauto,defaults 0 0" >> /etc/fstab

# Install boot system
apt install --yes \
  grub-efi-amd64 grub-efi-amd64-signed \
  linux-image-generic shim-signed \
  zfs-initramfs

# Install KDE desktop
apt install --yes kubuntu-desktop-minimal plasma-workspace-wayland

# Remove unnecessary packages
apt purge --yes os-prober
apt autoremove --yes

# Configure users
echo "Setting root password..."
passwd

# Create user
UUID_USER="$(dd if=/dev/urandom bs=1 count=100 2>/dev/null \
  | tr -dc 'a-z0-9' | cut -c-6)"

# Create user home dataset
zfs create -o com.ubuntu.zsys:bootfs-datasets="rpool/ROOT/kubuntu_${UUID}" \
  -o canmount=on -o mountpoint="/home/${USERNAME}" \
  "hpool/HOME/kubuntu_${UUID}/${USERNAME}_${UUID_USER}"

# Add user
adduser "${USERNAME}"
usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo "${USERNAME}"

# Phase 8: Boot Configuration

# Generate initramfs
update-initramfs -c -k all

# Configure GRUB
cat >> /etc/default/grub <<'END'
# ZFS Configuration
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash init_on_alloc=0"
GRUB_TIMEOUT=5
GRUB_RECORDFAIL_TIMEOUT=5
GRUB_TERMINAL=console
GRUB_ENABLE_CRYPTODISK=true
END

update-grub

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=kubuntu --recheck --no-floppy

# Verify installation
if [[ ! -f /boot/efi/EFI/kubuntu/grubx64.efi ]]; then
  echo "ERROR: GRUB installation failed"
  exit 1
fi

# Backup GRUB to additional EFI partitions
mount /boot/efi2
grub-install --target=x86_64-efi --efi-directory=/boot/efi2 \
  --bootloader-id=kubuntu-backup1 --recheck --no-floppy
umount /boot/efi2

mount /boot/efi3
grub-install --target=x86_64-efi --efi-directory=/boot/efi3 \
  --bootloader-id=kubuntu-backup2 --recheck --no-floppy
umount /boot/efi3

# Configure ZFS boot
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/{bpool,rpool,hpool}
zed -F &
ZED_PID=$!
sleep 5
kill $ZED_PID 2>/dev/null || true
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*

# Phase 9: Final Configuration

# Configure swap (using first disk's swap partition)
SWAP_UUID="$(blkid -s UUID -o value ${DISK1}-part2)"
mkswap -f -L swap1 "${DISK1}-part2"
echo "UUID=${SWAP_UUID} none swap defaults,pri=1 0 0" >> /etc/fstab

# Configure services
systemctl enable sddm
systemctl enable NetworkManager
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs.target
systemctl enable tmp.mount

# Configure network for NetworkManager
rm -f /etc/netplan/01-netcfg.yaml
cat > /etc/netplan/01-network-manager-all.yaml <<'END'
network:
  version: 2
  renderer: NetworkManager
END

# Create ZFS mount helper script
cat > /usr/local/bin/mount-encrypted-pools.sh <<'SCRIPT'
#!/bin/bash
# Helper script to mount encrypted pools at boot

echo "Loading encryption keys for ZFS pools..."

# Load key for rpool if needed
if zfs get -H -o value keystatus rpool | grep -q "unavailable"; then
  echo "Unlocking rpool..."
  zfs load-key rpool
fi

# Load key for hpool if needed
if zfs get -H -o value keystatus hpool | grep -q "unavailable"; then
  echo "Unlocking hpool..."
  zfs load-key hpool
fi

# Mount all datasets
zfs mount -a

echo "ZFS pools mounted successfully"
SCRIPT

chmod +x /usr/local/bin/mount-encrypted-pools.sh

echo "Chroot configuration completed successfully"
CHROOT_SCRIPT

    chmod +x /mnt/root/chroot-install.sh
}

#######################################
# Cleanup and export pools
# Globals:
#   None
# Arguments:
#   None
#######################################
cleanup_and_export() {
    log_info "Cleaning up and exporting pools..."

    # Unmount filesystems
    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' |
        xargs -I {} umount -lf {} 2>/dev/null || true

    # Export pools
    zpool export bpool
    zpool export rpool
    zpool export hpool

    log_info "Pools exported successfully"
}

################################################################################
# Main Function
################################################################################

#######################################
# Main installation function
# Globals:
#   All global variables
# Arguments:
#   Command line arguments
#######################################
main() {
    # Initialize global variables
    log_file="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

    # Disk selections (set during the disk selection phase)
    disk1=""
    disk2=""
    disk3=""

    # Installation uuid (generated during installation)
    uuid=""

    # Detected ashift value for pools
    ashift=12

    # Username and hostname (can be overridden)
    username="${DEFAULT_USERNAME}"
    HOSTNAME="${DEFAULT_HOSTNAME}"

    # Setup error handling
    trap 'error_handler $? $LINENO' ERR

    # Print banner
    print_banner

    # Check for resume
    local checkpoint
    checkpoint="$(load_checkpoint)"
    if [[ ${checkpoint} != "none" ]]; then
        log_info "Previous installation detected at checkpoint: ${checkpoint}"
        if ! confirm "Resume installation from ${checkpoint}?"; then
            rm -f "${CHECKPOINT_FILE}"
            log_info "Starting fresh installation"
        fi
    fi

    # Execute installation phases
    phase1_environment_preparation
    phase2_disk_selection
    phase3_disk_preparation
    phase4_zfs_pool_creation
    phase5_dataset_creation
    phase6_system_installation
    phase7_8_9_chroot_operations

    # Final message
    log_section "Installation Complete!"
    echo ""
    echo -e "${GREEN}System is ready to reboot.${NC}"
    echo ""
    echo "Remember to:"
    echo "1. Remove installation media"
    echo "2. Save encryption key backups from /root/zfs-keys-backup/"
    echo "3. Boot will prompt for encryption passphrases"
    echo ""
    echo "Selected disks:"
    echo "  DISK1: ${disk1}"
    echo "  DISK2: ${disk2}"
    echo "  DISK3: ${disk3}"
    echo ""

    if confirm "Reboot now?"; then
        reboot
    fi
}

# Execute main function
main "$@"
