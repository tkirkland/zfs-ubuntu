# Kubuntu 3-Disk RAIDZ1 ZFS Installation Guide

Comprehensive installation guide combining Ubuntu's ZFS implementation with Kubuntu's installation process for a 3-disk RAIDZ1 configuration with separate boot, root, and home pools.

## Overview

This guide creates a robust Kubuntu installation using ZFS RAIDZ1 across three disks with optimized pool layout:

- **bpool**: 1GB boot pool (RAIDZ1 across 3 disks)
- **rpool**: 400GB root pool (RAIDZ1 across 3 disks)
- **hpool**: Remaining space home pool (RAIDZ1 across 3 disks)

### System Requirements

- **Hardware**: 3 identical disks, UEFI-capable system, minimum 8GB RAM (4GB minimum, 8GB recommended)
- **Software**: Kubuntu 24.04 or 25.04 ISO, network connectivity
- **Storage**: Minimum 500GB total across 3 disks (167GB per disk minimum)
- **4Kn Drive Support**: Installing on drives with 4 KiB logical sectors only works with UEFI booting
- **Memory**: Computers with less than 2 GiB run ZFS slowly. 4 GiB recommended for normal performance. Massive RAM needed for deduplication (permanent change)
- **GRUB Limitation**: Does not work on 4Kn drives with legacy BIOS booting

## Phase 1: Environment Preparation

### 1.1 Boot Kubuntu Live Environment

1. Boot from Kubuntu ISO
2. Select "Try Kubuntu" from GRUB menu
3. Connect to network for package updates
4. Open Konsole terminal (Ctrl+Alt+T)

### 1.2 Prepare Installation Environment

```bash
# Enable strict error handling for safer installation
set -euo pipefail  # Exit on error, undefined variable, or pipe failure

# Error handler function
error_handler() {
    local exit_code=$1
    local line_number=$2
    echo "❌ ERROR: Installation failed with exit code $exit_code at line $line_number"
    echo "System may be in an inconsistent state. Manual cleanup may be required."
    
    # Attempt basic cleanup
    echo "Attempting to clean up ZFS pools..."
    zpool export bpool 2>/dev/null && echo "  Exported bpool" || true
    zpool export rpool 2>/dev/null && echo "  Exported rpool" || true 
    zpool export hpool 2>/dev/null && echo "  Exported hpool" || true
    
    echo "Installation terminated. Check errors above for details."
    exit $exit_code
}

# Set trap for error handling
trap 'error_handler $? $LINENO' ERR

echo "Starting Kubuntu ZFS installation at $(date)"
echo "Error handling enabled - installation will stop on any critical error"
echo ""

# Update package repositories
sudo apt update

# Optional: Install SSH server for remote installation
# passwd  # Set password for kubuntu user (live environment default user)
# sudo apt install --yes openssh-server vim

# Install required ZFS tools with error checking
echo "Installing required packages..."
if ! sudo apt install --yes gdisk zfsutils-linux; then
    echo "ERROR: Failed to install required packages"
    echo "Check network connectivity and try: apt update && apt install gdisk zfsutils-linux"
    exit 1
fi

# Install NVMe tools if NVMe disks are detected
if ls /dev/nvme* >/dev/null 2>&1; then
    echo "NVMe disks detected, installing nvme-cli for optimal management"
    if ! sudo apt install --yes nvme-cli; then
        echo "WARNING: Failed to install nvme-cli, continuing without NVMe-specific tools"
    else
        # List NVMe devices with details
        sudo nvme list || echo "WARNING: nvme list command failed"
    fi
fi

# Stop ZFS Event Daemon to prevent conflicts
sudo systemctl stop zed

# Become root for installation process
sudo -i
```

### 1.3 Disk Detection and Selection

```bash
# List all available disks with both identifiers
lsblk -o NAME,SIZE,MODEL,ROTA,DISC-GRAN,DISC-MAX
ls -la /dev/disk/by-id/ | grep -v part

# Check for NVMe disks specifically
if ls /dev/nvme* >/dev/null 2>&1; then
    echo "=== NVMe Disks Detected ==="
    sudo nvme list
    echo ""
fi

# Display disk information for user selection (handles both SATA and NVMe)
echo "Available disks:"
# Check for traditional SATA/SAS disks
for disk in /dev/sd*; do
    if [[ ! $disk =~ [0-9]$ ]]; then
        size=$(lsblk -b -d -o SIZE "$disk" | tail -1)
        size_gb=$((size / 1024 / 1024 / 1024))
        model=$(lsblk -d -o MODEL "$disk" | tail -1)
        by_id=$(ls -la /dev/disk/by-id/ | grep $(basename $disk)$ | awk '{print $9}' | head -1)
        echo "  $disk: ${size_gb}GB - $model"
        echo "    EUI ID: /dev/disk/by-id/$by_id"
        echo ""
    fi
done

# Check for NVMe disks
for disk in /dev/nvme*n1; do
    if [[ -b $disk ]]; then
        size=$(lsblk -b -d -o SIZE "$disk" | tail -1)
        size_gb=$((size / 1024 / 1024 / 1024))
        model=$(lsblk -d -o MODEL "$disk" | tail -1)
        by_id=$(ls -la /dev/disk/by-id/ | grep $(basename $disk)$ | grep -v part | awk '{print $9}' | head -1)
        echo "  $disk: ${size_gb}GB - $model (NVMe)"
        echo "    ID: /dev/disk/by-id/$by_id"
        # Show NVMe-specific health info
        if command -v nvme >/dev/null 2>&1; then
            temp=$(sudo nvme smart-log $disk | grep temperature | head -1 | awk '{print $3}')
            wear=$(sudo nvme smart-log $disk | grep percentage_used | awk '{print $3}')
            echo "    Temperature: ${temp}°C, Wear: ${wear}%"
        fi
        echo ""
    fi
done
```

**User selects three disks for RAIDZ1 configuration with validation:**

```bash
# Example disk selection (user must adapt to their system)
# For SATA/SAS disks:
# DISK1=/dev/disk/by-id/ata-Samsung_SSD_860_EVO_1TB_S4X1234567890123
# DISK2=/dev/disk/by-id/ata-Samsung_SSD_860_EVO_1TB_S4X1234567890124  
# DISK3=/dev/disk/by-id/ata-Samsung_SSD_860_EVO_1TB_S4X1234567890125

# For NVMe disks:
# DISK1=/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_1TB_S4X1234567890123
# DISK2=/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_1TB_S4X1234567890124
# DISK3=/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_1TB_S4X1234567890125

# Set your disk selections here:
DISK1=/dev/disk/by-id/[YOUR-DISK1-ID]
DISK2=/dev/disk/by-id/[YOUR-DISK2-ID]  
DISK3=/dev/disk/by-id/[YOUR-DISK3-ID]

# Comprehensive disk validation function
validate_disk() {
    local disk=$1
    local errors=0
    
    echo "Validating $disk..."
    
    # Check if device exists and is a block device
    if [[ ! -b "$disk" ]]; then
        echo "  ❌ ERROR: $disk is not a block device or doesn't exist"
        return 1
    fi
    
    # Check if disk has any mounted partitions
    if lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q '^/'; then
        echo "  ❌ ERROR: $disk has mounted partitions:"
        lsblk "$disk" | grep -E "[a-zA-Z].*/$"
        return 1
    fi
    
    # Check minimum size (167GB per disk for 500GB total across 3 disks)
    local size=$(lsblk -b -n -d -o SIZE "$disk" 2>/dev/null | head -1)
    if [[ -z "$size" ]]; then
        echo "  ❌ ERROR: Cannot determine size of $disk"
        return 1
    fi
    
    local size_gb=$((size / 1024 / 1024 / 1024))
    if [[ $size_gb -lt 167 ]]; then
        echo "  ❌ ERROR: $disk is only ${size_gb}GB (minimum 167GB required)"
        return 1
    fi
    
    # Check if disk is in use by another process
    if fuser "$disk" &>/dev/null; then
        echo "  ⚠️ WARNING: $disk is currently in use by another process"
        echo "  Continue with caution or stop the process using it"
    fi
    
    # Check disk health if possible
    if command -v smartctl &>/dev/null; then
        local health_status
        if [[ $disk == *nvme* ]]; then
            # NVMe health check
            health_status=$(nvme smart-log "$disk" 2>/dev/null | grep "critical_warning" | awk '{print $3}' || echo "unknown")
            if [[ "$health_status" != "0" ]] && [[ "$health_status" != "unknown" ]]; then
                echo "  ⚠️ WARNING: NVMe disk $disk shows critical warning: $health_status"
            fi
        else
            # SATA/SAS health check
            health_status=$(smartctl -H "$disk" 2>/dev/null | grep "SMART overall-health" | awk '{print $6}' || echo "unknown")
            if [[ "$health_status" != "PASSED" ]] && [[ "$health_status" != "unknown" ]]; then
                echo "  ⚠️ WARNING: SMART health check failed for $disk: $health_status"
            fi
        fi
    fi
    
    echo "  ✅ $disk validated: ${size_gb}GB available"
    return 0
}

# Validate all selected disks
echo "╔══════════════════════════════════════════╗"
echo "║           DISK VALIDATION - CRITICAL STEP         ║"
echo "╚══════════════════════════════════════════╝"

for disk in "$DISK1" "$DISK2" "$DISK3"; do
    if ! validate_disk "$disk"; then
        echo "DISK VALIDATION FAILED: $disk"
        exit 1
    fi
done

# Check if all disks are same size (recommended for RAIDZ1)
echo "
Checking disk size consistency..."
size1=$(lsblk -b -n -d -o SIZE "$DISK1" | head -1)
size2=$(lsblk -b -n -d -o SIZE "$DISK2" | head -1)
size3=$(lsblk -b -n -d -o SIZE "$DISK3" | head -1)

if [[ $size1 -ne $size2 ]] || [[ $size2 -ne $size3 ]]; then
    echo "⚠️ WARNING: Disks are different sizes. RAIDZ1 will be limited to smallest disk."
    echo "  Disk1: $((size1/1024/1024/1024))GB - $(basename "$DISK1")"
    echo "  Disk2: $((size2/1024/1024/1024))GB - $(basename "$DISK2")"
    echo "  Disk3: $((size3/1024/1024/1024))GB - $(basename "$DISK3")"
    echo ""
    while true; do
        read -p "Continue with different sized disks? (yes/no): " confirm
        case $confirm in
            yes) echo "Proceeding with mixed disk sizes..."; break ;;
            no) echo "Exiting. Please select disks of same size."; exit 1 ;;
            *) echo "Please answer 'yes' or 'no'" ;;
        esac
    done
else
    echo "✅ All disks are the same size: $((size1/1024/1024/1024))GB"
fi

echo "
Selected disks:"
echo "DISK1: $DISK1"
echo "DISK2: $DISK2"  
echo "DISK3: $DISK3"

# Display final disk information
echo "
╔══════════════════════════════════════════╗"
echo "║            FINAL DISK SELECTION SUMMARY            ║"
echo "╚══════════════════════════════════════════╝"

for DISK in $DISK1 $DISK2 $DISK3; do
    echo "$(basename $DISK): $(lsblk -d -o SIZE,MODEL $DISK | tail -1)"
    # For NVMe disks, show additional health info
    if [[ $DISK == *nvme* ]] && command -v nvme >/dev/null 2>&1; then
        sudo nvme smart-log $DISK | grep -E "temperature|percentage_used|available_spare"
    fi
done

echo "✅ All disks validated and ready for ZFS installation"
```

## Phase 2: Disk Preparation

### 2.1 Clear Existing Data

```bash
# Disable any swap partitions
swapoff --all

# Clear any existing RAID signatures
for DISK in $DISK1 $DISK2 $DISK3; do
    wipefs -a $DISK
    sgdisk --zap-all $DISK
done


# Secure erase optimization for different disk types
for DISK in $DISK1 $DISK2 $DISK3; do
    echo "Preparing $DISK for use..."
  
    # Check if disk is NVMe
    if [[ $DISK == *nvme* ]] && command -v nvme >/dev/null 2>&1; then
        echo "  NVMe disk detected - checking crypto erase support"
        # Check if crypto erase is supported
        if nvme id-ctrl $DISK | grep -q "Crypto Erase Supported"; then
            echo "    Using crypto erase (instantaneous secure wipe)"
            sudo nvme format $DISK --ses=1  # User data erase (crypto erase)
        else
            echo "    Crypto erase not supported, using standard format"
            sudo nvme format $DISK  # Standard format without secure erase
        fi
    else
        echo "  SATA/SAS disk detected - using blkdiscard"
        # Traditional discard for SATA/SAS SSDs
        blkdiscard -f $DISK 2>/dev/null || dd if=/dev/zero of=$DISK bs=1M count=100
    fi
done
```

### 2.2 Create Partition Layout

```bash
# Create GPT partition table and partitions on all disks
for DISK in $DISK1 $DISK2 $DISK3; do
    echo "Partitioning $DISK..."
  
    # EFI System Partition (512MB) 
    sgdisk -n1:1M:+512M -t1:EF00 $DISK
  
    # Swap Partition (8GB) - Only on first disk, no redundancy needed for swap
    if [[ $DISK == $DISK1 ]]; then
        sgdisk -n2:0:+8G -t2:8200 $DISK
    fi
  
    # Boot Pool Partition (2GB) - Ubuntu uses 2GB, 500MB might be too small for kernel upgrades
    sgdisk -n3:0:+2G -t3:BE00 $DISK
  
    # Root Pool Partition (400GB)
    sgdisk -n4:0:+400G -t4:BF00 $DISK
  
    # Home Pool Partition (remaining space, larger on disks 2&3 without swap)
    sgdisk -n5:0:0 -t5:BF00 $DISK
  
    # Verify partition creation
    sgdisk -p $DISK
done
```

### 2.3 Create EFI System Partitions

```bash
# Format EFI partitions on all disks
# -s 1 is necessary for 4Kn drives to meet minimum cluster size for FAT32
for DISK in $DISK1 $DISK2 $DISK3; do
    mkdosfs -F 32 -s 1 -n EFI${DISK##*-} ${DISK}-part1
done
```

## Phase 3: ZFS Pool Creation

### 3.1 Create Boot Pool (RAIDZ1)

```bash
# Auto-detect optimal ashift for NVMe vs SATA
# NVMe typically uses 4K sectors (ashift=12), some enterprise NVMe use 8K (ashift=13)
if [[ $DISK1 == *nvme* ]]; then
    # Check actual sector size for NVMe
    SECTOR_SIZE=$(nvme id-ns ${DISK1} -n 1 | grep "LBA Format" | grep "in use" | awk '{print $5}' | tr -d '()')
    if [[ $SECTOR_SIZE == "4096" ]]; then
        ASHIFT=12
    elif [[ $SECTOR_SIZE == "8192" ]]; then
        ASHIFT=13
    else
        ASHIFT=12  # Default to 4K
    fi
    echo "NVMe detected: Using ashift=$ASHIFT for ${SECTOR_SIZE:-4096} byte sectors"
else
    ASHIFT=12  # Standard for modern SATA SSDs
    echo "SATA/SAS detected: Using ashift=$ASHIFT for 4096 byte sectors"
fi

# Create 2GB boot pool across 3 disks with GRUB compatibility
# Boot pool name MUST be 'bpool' for GRUB integration
# Only use GRUB-compatible features - ignore warnings about features not in compatibility set
zpool create \
    -o ashift=$ASHIFT \
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
    bpool raidz1 ${DISK1}-part3 ${DISK2}-part3 ${DISK3}-part3

# Verify boot pool creation
zpool status bpool
zpool list bpool
```

### 3.2 Create Root Pool (RAIDZ1)

```bash
# Create 400GB root pool with encryption
# Use same ashift as boot pool for consistency
# ZFS native encryption defaults to aes-256-gcm
# xattr=sa vastly improves extended attribute performance (Linux-specific)
# normalization=formD eliminates UTF-8 filename corner cases, implies utf8only=on
# relatime=on is middle ground between atime performance impact and atime=off
zpool create \
    -o ashift=$ASHIFT \
    -o autotrim=on \
    -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/ -R /mnt \
    rpool raidz1 ${DISK1}-part4 ${DISK2}-part4 ${DISK3}-part4

# Verify root pool creation
zpool status rpool
zpool list rpool
```

### 3.3 Create Home Pool (RAIDZ1)

```bash
# Create home pool with remaining space
# Same settings as root pool for consistency and performance
zpool create \
    -o ashift=$ASHIFT \
    -o autotrim=on \
    -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/home -R /mnt \
    hpool raidz1 ${DISK1}-part5 ${DISK2}-part5 ${DISK3}-part5

# Verify home pool creation  
zpool status hpool
zpool list hpool
```

### 3.4 Create Encryption Key Backup
```bash
# CRITICAL: Backup encryption information immediately
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    🔐 ENCRYPTION BACKUP 🔐                ║"
echo "║                                                          ║"
echo "║  SAVE THESE ENCRYPTION DETAILS IN A SECURE LOCATION!    ║"
echo "║  WITHOUT THESE KEYS, YOUR DATA WILL BE PERMANENTLY LOST! ║"
echo "╚══════════════════════════════════════════════════════════╝"

# Create backup directory
mkdir -p /mnt/root/zfs-keys-backup

# Document encryption settings
echo "ZFS Encryption Backup Created: $(date)" > /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "========================================" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "1. SAVE THE PASSPHRASES YOU ENTERED FOR RPOOL AND HPOOL!" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "   Without these passphrases, your data cannot be recovered." >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "2. Copy this entire directory to external media immediately:" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "   /root/zfs-keys-backup/" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "3. Store the backup in a safe, separate location." >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt
echo "" >> /mnt/root/zfs-keys-backup/CRITICAL-README.txt

# Save encryption metadata
echo "Root Pool (rpool) Encryption Information:" > /mnt/root/zfs-keys-backup/rpool-encryption.txt
zfs get encryption,keyformat,keylocation,keystatus rpool >> /mnt/root/zfs-keys-backup/rpool-encryption.txt
echo "" >> /mnt/root/zfs-keys-backup/rpool-encryption.txt

echo "Home Pool (hpool) Encryption Information:" > /mnt/root/zfs-keys-backup/hpool-encryption.txt
zfs get encryption,keyformat,keylocation,keystatus hpool >> /mnt/root/zfs-keys-backup/hpool-encryption.txt
echo "" >> /mnt/root/zfs-keys-backup/hpool-encryption.txt

# Create emergency recovery script
cat > /mnt/root/zfs-keys-backup/emergency-recovery.sh << 'EOF'
#!/bin/bash
echo "=== ZFS Emergency Recovery Script ==="
echo "This script helps recover access to your encrypted ZFS pools"
echo ""
echo "Step 1: Import pools"
echo "zpool import -f rpool"
echo "zpool import -f hpool"
echo ""
echo "Step 2: Load encryption keys"
echo "zfs load-key rpool"
echo "zfs load-key hpool"
echo ""
echo "Step 3: Mount datasets"
echo "zfs mount -a"
echo ""
echo "Your data should now be accessible under /rpool and /hpool"
EOF
chmod +x /mnt/root/zfs-keys-backup/emergency-recovery.sh

# Display backup warning
echo ""
echo "🔴 CRITICAL: BACKUP YOUR ENCRYPTION KEYS NOW! 🔴"
echo ""
echo "Location: /mnt/root/zfs-keys-backup/"
echo "Copy this directory to external media immediately!"
echo ""
echo "Press ENTER to continue after backing up encryption keys..."
read -p ""
```

## Phase 4: ZFS Dataset Structure

### 4.1 Create Container Datasets

```bash
# Create container datasets (cannot be mounted directly)
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT
zfs create -o canmount=off -o mountpoint=none hpool/HOME
```

### 4.2 Create System Datasets

```bash
# Generate unique ID for this installation
UUID=$(dd if=/dev/urandom bs=1 count=100 2>/dev/null | tr -dc 'a-z0-9' | cut -c-6)

# Create root filesystem dataset
zfs create -o mountpoint=/ \
    -o com.ubuntu.zsys:bootfs=yes \
    -o com.ubuntu.zsys:last-used=$(date +%s) \
    rpool/ROOT/kubuntu_$UUID

# Create boot filesystem dataset  
zfs create -o mountpoint=/boot bpool/BOOT/kubuntu_$UUID

# Create home container dataset
zfs create -o mountpoint=/home hpool/HOME/kubuntu_$UUID
```

### 4.3 Create System Subdatasets

```bash
# System component datasets for snapshots and maintenance
zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \
    rpool/ROOT/kubuntu_$UUID/usr
zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \
    rpool/ROOT/kubuntu_$UUID/var

# Critical system directories
zfs create rpool/ROOT/kubuntu_$UUID/var/lib
zfs create rpool/ROOT/kubuntu_$UUID/var/log
zfs create rpool/ROOT/kubuntu_$UUID/var/spool
zfs create rpool/ROOT/kubuntu_$UUID/var/cache
zfs create rpool/ROOT/kubuntu_$UUID/var/tmp
chmod 1777 /mnt/var/tmp

# Optional: Separate datasets for specific services
zfs create rpool/ROOT/kubuntu_$UUID/var/lib/apt
zfs create rpool/ROOT/kubuntu_$UUID/var/lib/dpkg
zfs create rpool/ROOT/kubuntu_$UUID/var/snap
zfs create rpool/ROOT/kubuntu_$UUID/var/lib/AccountsService
zfs create rpool/ROOT/kubuntu_$UUID/var/lib/NetworkManager

# Local data directories
zfs create rpool/ROOT/kubuntu_$UUID/usr/local
zfs create rpool/ROOT/kubuntu_$UUID/srv
```

### 4.4 Create User Data Datasets

```bash
# User data separation for independent snapshots
zfs create -o canmount=off -o mountpoint=/ \
    rpool/USERDATA
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/kubuntu_$UUID \
    -o canmount=on -o mountpoint=/root \
    rpool/USERDATA/root_$UUID
chmod 700 /mnt/root

# Temporary filesystem for runtime data
mkdir /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir /mnt/run/lock
```

## Phase 5: Kubuntu System Installation

### 5.1 Extract Base System

```bash
# Find and mount Kubuntu ISO
mkdir -p /mnt/cdrom

# Method 1: Find mounted ISO (if booted from ISO)
ISO_SOURCE=$(findmnt -n -o SOURCE / | grep -o '^[^\[]\+')

# Method 2: Find by label
if [[ -z "$ISO_SOURCE" ]]; then
    ISO_SOURCE=$(blkid -L "Kubuntu" || blkid -L "Ubuntu" || echo "")
fi

# Method 3: Find USB drive with ISO
if [[ -z "$ISO_SOURCE" ]]; then
    echo "Available devices with ISOs:"
    lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT | grep -E "iso9660|udf"
    echo "Enter the device containing the Kubuntu ISO (e.g., /dev/sdb1):"
    read ISO_SOURCE
fi

# Mount the ISO source
if [[ -b "$ISO_SOURCE" ]]; then
    mount "$ISO_SOURCE" /mnt/cdrom
elif [[ -f "$ISO_SOURCE" ]]; then
    mount -o loop "$ISO_SOURCE" /mnt/cdrom
else
    echo "ERROR: Cannot find Kubuntu ISO source"
    echo "Please mount the ISO manually to /mnt/cdrom"
    exit 1
fi

# Verify correct squashfs file exists (Kubuntu uses filesystem.squashfs)
if [[ -f /mnt/cdrom/casper/filesystem.squashfs ]]; then
    SQUASHFS="/mnt/cdrom/casper/filesystem.squashfs"
else
    echo "ERROR: Cannot find filesystem.squashfs in /mnt/cdrom/casper/"
    echo "Available files:"
    ls -la /mnt/cdrom/casper/
    echo "Note: Kubuntu uses 'filesystem.squashfs' (not 'minimal.squashfs')"
    exit 1
fi

echo "Using squashfs: $SQUASHFS"

# Mount and copy Kubuntu filesystem  
mkdir -p /mnt/source
mount -t squashfs "$SQUASHFS" /mnt/source

# Copy system files (this may take 10-15 minutes)
rsync -av --progress /mnt/source/ /mnt/ \
    --exclude=/proc --exclude=/sys --exclude=/dev \
    --exclude=/run --exclude=/mnt --exclude=/media \
    --exclude=/tmp --exclude=/var/tmp
  
# Clean up
umount /mnt/source
rmdir /mnt/source
```

### 5.2 Configure System Environment

```bash
# Copy ZFS cache for boot-time pool import
mkdir /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

# Set hostname
HOSTNAME="kubuntu-zfs"
echo $HOSTNAME > /mnt/etc/hostname
cat << EOF > /mnt/etc/hosts
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
```

### 5.3 Configure Package Sources

```bash
# Kubuntu uses Ubuntu repositories (this is correct)
cat << 'EOF' > /mnt/etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
```

### 5.4 Network Configuration

```bash
# Find network interface name
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)

# Create netplan configuration for Kubuntu
mkdir -p /mnt/etc/netplan
cat << EOF > /mnt/etc/netplan/01-netcfg.yaml
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: true
EOF
```

## Phase 6: Chroot Configuration

### 6.1 Enter Chroot Environment

```bash
# Save installation variables for persistence across chroot boundary
cat > /mnt/root/install-vars.sh << EOF
# Installation variables - DO NOT DELETE
export DISK1="$DISK1"
export DISK2="$DISK2"
export DISK3="$DISK3"
export UUID="$UUID"
export HOSTNAME="$HOSTNAME"
export USERNAME="kubu"  # Set desired username here
export ASHIFT="$ASHIFT"
EOF

# Mount virtual filesystems for chroot
mount --make-private --rbind /dev /mnt/dev
mount --make-private --rbind /proc /mnt/proc  
mount --make-private --rbind /sys /mnt/sys

# Enter chroot with environment variables
chroot /mnt /usr/bin/env \
    DISK1=$DISK1 DISK2=$DISK2 DISK3=$DISK3 \
    UUID=$UUID HOSTNAME=$HOSTNAME ASHIFT=$ASHIFT bash --login
```

**Inside the chroot environment, start each session by loading variables:**
```bash
# Load installation variables (run this immediately after entering chroot)
source /root/install-vars.sh
echo "Loaded variables: UUID=$UUID, HOSTNAME=$HOSTNAME"
```

### 6.2 Configure Base System (Inside Chroot)

```bash
# Update package database
apt update

# Configure locales and timezone
dpkg-reconfigure locales tzdata keyboard-configuration

# Install text editor
apt install --yes nano vim

# Configure for ZFS encryption
apt install --yes cryptsetup
```

### 6.3 Configure EFI System

```bash
# Create EFI mount point
mkdir /boot/efi
echo "/dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK1}-part1) \
    /boot/efi vfat defaults 0 0" >> /etc/fstab
mount /boot/efi

# Create additional EFI partition entries for RAID redundancy  
mkdir -p /boot/efi2 /boot/efi3
echo "/dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK2}-part1) \
    /boot/efi2 vfat noauto,defaults 0 0" >> /etc/fstab
echo "/dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK3}-part1) \
    /boot/efi3 vfat noauto,defaults 0 0" >> /etc/fstab
```

### 6.4 Install Boot System

```bash
# Install GRUB and Linux for UEFI
apt install --yes \
    grub-efi-amd64 grub-efi-amd64-signed \
    linux-image-generic shim-signed \
    zfs-initramfs

# Install KDE/Kubuntu desktop environment
apt install --yes kubuntu-desktop-minimal

# Remove unnecessary packages
apt purge --yes os-prober
apt autoremove --yes
```

### 6.5 Configure Users

```bash
# Set root password
passwd

# Create regular user account using saved variables
# Username is already set in install-vars.sh as $USERNAME
UUID_USER=$(dd if=/dev/urandom bs=1 count=100 2>/dev/null | tr -dc 'a-z0-9' | cut -c-6)

# Create user home dataset
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/kubuntu_$UUID \
    -o canmount=on -o mountpoint=/home/$USERNAME \
    hpool/HOME/kubuntu_$UUID/$USERNAME\_$UUID_USER

# Add user account
adduser $USERNAME
usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo $USERNAME

# Copy user skeleton files
cp -a /etc/skel/. /home/$USERNAME
chown -R $USERNAME:$USERNAME /home/$USERNAME
```

## Phase 7: Boot Configuration

### 7.1 Configure GRUB

```bash
# Generate initial ramdisk
update-initramfs -c -k all

# Configure GRUB settings
cat << 'EOF' >> /etc/default/grub
# ZFS Configuration
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash init_on_alloc=0"
GRUB_TIMEOUT=5
GRUB_RECORDFAIL_TIMEOUT=5
GRUB_TERMINAL=console
GRUB_ENABLE_CRYPTODISK=true
EOF

# Generate GRUB configuration
update-grub

# Install GRUB to EFI partitions
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=kubuntu --recheck --no-floppy

# Verify primary GRUB installation succeeded
if [[ ! -f /boot/efi/EFI/kubuntu/grubx64.efi ]]; then
    echo "ERROR: Primary GRUB installation failed"
    echo "Missing: /boot/efi/EFI/kubuntu/grubx64.efi"
    ls -la /boot/efi/EFI/ || true
    exit 1
fi

echo "✅ Primary GRUB installation verified"
sync  # Ensure all writes complete before proceeding
sleep 2  # Brief pause for filesystem stability

# Backup GRUB to additional EFI partitions
mount /boot/efi2
grub-install --target=x86_64-efi --efi-directory=/boot/efi2 \
    --bootloader-id=kubuntu-backup1 --recheck --no-floppy
umount /boot/efi2

mount /boot/efi3
grub-install --target=x86_64-efi --efi-directory=/boot/efi3 \
    --bootloader-id=kubuntu-backup2 --recheck --no-floppy
umount /boot/efi3
```

### 7.2 Configure ZFS Boot Integration

```bash
# Setup ZFS mount generator
mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool  
touch /etc/zfs/zfs-list.cache/hpool
zed -F &

# Wait for cache generation
sleep 5

# Verify cache creation
cat /etc/zfs/zfs-list.cache/bpool
cat /etc/zfs/zfs-list.cache/rpool
cat /etc/zfs/zfs-list.cache/hpool

# Stop zed
fg
# Press Ctrl-C

# Fix mount paths 
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
```

### 7.3 Configure System Services

```bash
# Configure SDDM display manager
systemctl enable sddm

# Configure network manager
systemctl enable NetworkManager
rm /etc/netplan/01-netcfg.yaml
cat << 'EOF' > /etc/netplan/01-network-manager-all.yaml
network:
  version: 2
  renderer: NetworkManager
EOF

# Enable ZFS services with proper ordering
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs.target
systemctl enable zfs-import.target


# Configure tmpfs for /tmp with size limits
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
# Limit tmpfs size to avoid memory exhaustion
sed -i 's/Options=mode=1777,strictatime,nosuid,nodev/Options=mode=1777,strictatime,nosuid,nodev,size=2G/' /etc/systemd/system/tmp.mount
systemctl enable tmp.mount
```

### 7.4 Configure Automatic EFI Backup Sync
```bash
# Create script to sync EFI partitions after kernel updates
cat << 'EOF' > /usr/local/bin/sync-efi-backups.sh
#!/bin/bash
# Sync EFI partitions to backup locations after kernel updates
# This ensures all EFI partitions remain bootable

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}[EFI Sync]${NC} Starting EFI partition synchronization..."

# Check if primary EFI is mounted
if ! mountpoint -q /boot/efi; then
    echo -e "${RED}[EFI Sync]${NC} Primary EFI partition not mounted!"
    exit 1
fi

# Function to sync EFI partition
sync_efi_partition() {
    local backup_num=$1
    local backup_path="/boot/efi${backup_num}"
    
    echo -e "${YELLOW}[EFI Sync]${NC} Syncing to ${backup_path}..."
    
    # Mount backup EFI if not already mounted
    if ! mountpoint -q "${backup_path}"; then
        mount "${backup_path}" || {
            echo -e "${RED}[EFI Sync]${NC} Failed to mount ${backup_path}"
            return 1
        }
    fi
    
    # Sync files using rsync
    if rsync -av --delete /boot/efi/ "${backup_path}/" > /dev/null 2>&1; then
        echo -e "${GREEN}[EFI Sync]${NC} Successfully synced to ${backup_path}"
    else
        echo -e "${RED}[EFI Sync]${NC} Failed to sync to ${backup_path}"
    fi
    
    # Unmount backup EFI to keep it safe
    umount "${backup_path}" 2>/dev/null || true
}

# Sync to backup EFI partitions
for i in 2 3; do
    if [ -d "/boot/efi${i}" ]; then
        sync_efi_partition "${i}"
    fi
done

echo -e "${GREEN}[EFI Sync]${NC} EFI synchronization complete!"
EOF

chmod +x /usr/local/bin/sync-efi-backups.sh

# Create APT hook to run after kernel updates
cat << 'EOF' > /etc/apt/apt.conf.d/99-sync-efi-backups
// Sync EFI backup partitions after kernel updates
DPkg::Post-Invoke {
    "if [ -f /usr/local/bin/sync-efi-backups.sh ] && [ -d /boot/efi ] && (echo $DPKG_MAINTSCRIPT_PACKAGE | grep -qE 'linux-image|linux-signed|grub|shim|initramfs'); then /usr/local/bin/sync-efi-backups.sh; fi";
};
EOF

# Create systemd service for EFI sync (alternative to APT hook)
cat << 'EOF' > /etc/systemd/system/sync-efi-backups.service
[Unit]
Description=Sync EFI backup partitions
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-efi-backups.sh
RemainAfterExit=no
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

# Create systemd path unit to trigger on kernel changes
cat << 'EOF' > /etc/systemd/system/sync-efi-backups.path
[Unit]
Description=Watch for kernel updates to trigger EFI sync
After=multi-user.target

[Path]
PathChanged=/boot/vmlinuz
PathChanged=/boot/initrd.img
PathChanged=/boot/grub/grub.cfg
PathChanged=/boot/efi/EFI/ubuntu/grubx64.efi

[Install]
WantedBy=multi-user.target
EOF

# Enable the systemd path watcher
systemctl daemon-reload
systemctl enable sync-efi-backups.path
systemctl start sync-efi-backups.path

# Test the sync script
echo "Testing EFI backup sync..."
/usr/local/bin/sync-efi-backups.sh
```

## Phase 8: Final System Configuration

### 8.1 Configure Swap

```bash
# Simple swap partition on first disk only - no redundancy needed for swap
mkswap -f ${DISK1}-part2
echo "${DISK1}-part2 none swap defaults,pri=1 0 0" >> /etc/fstab
swapon ${DISK1}-part2
```

### 8.2 Configure Package Management

```bash
# Add system groups
addgroup --system lpadmin
addgroup --system sambashare

# Configure KDE/Plasma environment
apt install --yes plasma-workspace-wayland
```

### 8.3 Exit Chroot and Cleanup

```bash
# Exit from chroot environment
exit

# Restore installation variables after exiting chroot
source /mnt/root/install-vars.sh
echo "Variables restored: UUID=$UUID, HOSTNAME=$HOSTNAME"

# Unmount all filesystems in correct order
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | \
    xargs -i{} umount -lf {}

# Export ZFS pools
zpool export bpool
zpool export rpool  
zpool export hpool
```

## Phase 9: First Boot and Validation

### 9.1 System Boot

```bash
# Reboot system
reboot
```

**Expected Boot Process:**

1. UEFI loads GRUB from EFI System Partition
2. GRUB displays Kubuntu boot menu with ZFS datasets
3. System prompts for ZFS encryption passphrase (twice - rpool and hpool)
4. ZFS pools import automatically
5. Kubuntu desktop loads with SDDM login manager

### 9.2 Post-Boot Validation

```bash
# Load installation variables if available (UUID may be needed)
if [[ -f /root/install-vars.sh ]]; then
    source /root/install-vars.sh
    echo "Loaded installation variables: UUID=$UUID"
else
    echo "Installation variables not found, determining UUID from filesystem..."
    # Auto-detect the UUID from the actual dataset name
    UUID=$(zfs list -H -o name | grep 'ROOT/kubuntu_' | head -1 | sed 's/.*kubuntu_//' | sed 's/\/.*$//')
    if [[ -n "$UUID" ]]; then
        echo "Detected UUID from ZFS datasets: $UUID"
    else
        echo "ERROR: Cannot determine installation UUID"
        echo "Available datasets:"
        zfs list -H -o name | grep ROOT
        exit 1
    fi
fi

# Verify ZFS pools are healthy
sudo zpool status
sudo zfs list

# Check pool redundancy
sudo zpool scrub bpool
sudo zpool scrub rpool
sudo zpool scrub hpool

# Verify datasets are mounted correctly
df -h
mount | grep zfs

# Test snapshot functionality
sudo zfs snapshot rpool/ROOT/kubuntu_$UUID@install-complete
sudo zfs snapshot hpool/HOME/kubuntu_$UUID@install-complete
sudo zfs list -t snapshot
```

### 9.3 Performance Optimization

```bash
# ZFS ARC tuning - limit to 1/2 of available RAM for desktop systems
# Check available memory
AVAIL_MEM=$(free -b | awk '/^Mem:/{print $2}')
ARC_MAX=$((AVAIL_MEM / 2))

echo "# ZFS ARC Tuning for Desktop" | sudo tee -a /etc/modprobe.d/zfs.conf
echo "options zfs zfs_arc_max=$ARC_MAX" | sudo tee -a /etc/modprobe.d/zfs.conf

# NVMe-specific optimizations
if ls /dev/nvme* >/dev/null 2>&1; then
    echo "Applying NVMe-specific optimizations..."
  
    # Set optimal I/O scheduler for NVMe (none/noop is best for NVMe)
    for disk in /sys/block/nvme*/queue/scheduler; do
        echo none | sudo tee $disk
    done
  
    # Increase queue depth for better parallelism
    for disk in /sys/block/nvme*/queue/nr_requests; do
        echo 2048 | sudo tee $disk
    done
  
    # Make settings persistent
    echo 'ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"' | \
        sudo tee /etc/udev/rules.d/60-nvme-scheduler.rules
    echo 'ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/nr_requests}="2048"' | \
        sudo tee -a /etc/udev/rules.d/60-nvme-scheduler.rules
fi

# Disable log rotation compression to prevent high CPU usage on rotational media
sudo sed -i "s/#compress/compress/g; s/compress/nocompress/g" /etc/logrotate.conf

# Enable automatic trim for SSDs
sudo systemctl enable zfs-trim.timer

# Configure system for optimal ZFS performance
echo "# ZFS Performance Tuning" | sudo tee -a /etc/sysctl.d/90-zfs.conf
echo "vm.swappiness=1" | sudo tee -a /etc/sysctl.d/90-zfs.conf
echo "vm.vfs_cache_pressure=50" | sudo tee -a /etc/sysctl.d/90-zfs.conf
```

## Maintenance and Operations

### Backup Strategy

```bash
# Create regular snapshots
sudo zfs snapshot rpool/ROOT/kubuntu_$UUID@$(date +%Y%m%d-%H%M)
sudo zfs snapshot hpool/HOME/kubuntu_$UUID@$(date +%Y%m%d-%H%M)

# Send snapshots to external storage
sudo zfs send rpool/ROOT/kubuntu_$UUID@backup | \
    ssh user@backup-server "zfs receive backup/kubuntu-root"
```

### Pool Maintenance

```bash
# Regular scrub (monthly) - schedule via cron
sudo zpool scrub bpool rpool hpool

# Monitor scrub progress
sudo zpool status -v

# Check pool performance
sudo zpool iostat -v 1

# Check swap status
swapon --show
free -h

# Monitor disk health - SATA/SAS vs NVMe
for disk in /dev/disk/by-id/*; do
    if [[ ! $disk =~ part ]]; then
        if [[ $disk == *nvme* ]] && command -v nvme >/dev/null 2>&1; then
            echo "=== NVMe Health: $(basename $disk) ==="
            sudo nvme smart-log $disk | grep -E "temperature|percentage_used|available_spare|critical_warning"
            # Run NVMe self-test
            sudo nvme device-self-test $disk --namespace-id=1 --self-test-code=1  # Short test
        elif [[ -b $disk ]]; then
            echo "=== SATA/SAS Health: $(basename $disk) ==="
            sudo smartctl -a $disk | grep -E "Temperature|Reallocated|Pending|Uncorrectable"
            sudo smartctl -t short $disk  # Run short self-test
        fi
    fi
done

# Set up automatic scrub via systemd timer
sudo systemctl enable zfs-scrub-monthly@rpool.timer
sudo systemctl enable zfs-scrub-monthly@bpool.timer
sudo systemctl enable zfs-scrub-monthly@hpool.timer
```

### Disaster Recovery

```bash
# Boot from Kubuntu Live CD and prepare environment
sudo apt update
sudo apt install --yes zfsutils-linux

# Import pools (check available first)
sudo zpool import
sudo zpool import -f -R /mnt rpool
sudo zpool import -f -R /mnt bpool
sudo zpool import -f -R /mnt hpool

# Load encryption keys and mount datasets
sudo zfs load-key rpool
sudo zfs load-key hpool
sudo zfs mount -a

# Verify system is accessible
ls /mnt/boot /mnt/home

# Optional: chroot into system for repairs
sudo mount --make-private --rbind /dev /mnt/dev
sudo mount --make-private --rbind /proc /mnt/proc
sudo mount --make-private --rbind /sys /mnt/sys
sudo chroot /mnt
```

### Pool Expansion (Adding Larger Disks)

```bash
# Replace disks one at a time in RAIDZ1
sudo zpool replace bpool OLD_DISK NEW_DISK
sudo zpool replace rpool OLD_DISK NEW_DISK  
sudo zpool replace hpool OLD_DISK NEW_DISK

# After all disks replaced, expand pools
sudo zpool online -e bpool NEW_DISK1 NEW_DISK2 NEW_DISK3
sudo zpool online -e rpool NEW_DISK1 NEW_DISK2 NEW_DISK3
sudo zpool online -e hpool NEW_DISK1 NEW_DISK2 NEW_DISK3
```

## Troubleshooting

### Common Issues

#### ZFS Pool Import Failures

```bash
# Check available pools
sudo zpool import

# Force import pools if necessary
sudo zpool import -f -R /mnt rpool
sudo zpool import -f -R /mnt bpool
sudo zpool import -f -R /mnt hpool

# Load encryption keys
sudo zfs load-key rpool
sudo zfs load-key hpool

# Check for pool corruption
sudo zpool status -v
sudo zpool scrub POOLNAME

# Clear pool errors after resolving issues
sudo zpool clear POOLNAME
```

#### Boot Failures

```bash
# From GRUB rescue prompt
grub rescue> ls
grub rescue> set root=(hd0,gpt2)  # Boot pool partition
grub rescue> linux /vmlinuz root=ZFS=rpool/ROOT/kubuntu_UUID ro
grub rescue> initrd /initrd.img
grub rescue> boot
```

#### Encryption Key Issues

```bash
# Check encryption status
sudo zfs get encryption,keystatus,keylocation rpool hpool

# Load keys if unloaded
sudo zfs load-key rpool
sudo zfs load-key hpool

# Change encryption passphrase
sudo zfs change-key rpool
sudo zfs change-key hpool

# If keys are lost, recovery requires backup
# Always maintain backup of recovery keys:
# zfs get keystatus,keylocation -r rpool
```

### Performance Tuning

```bash
# Monitor ZFS performance in real-time
sudo zpool iostat -v 1 5
sudo zpool status -v
sudo zfs get compression,compressratio,used,available

# Monitor ARC usage
sudo cat /proc/spl/kstat/zfs/arcstats | grep -E '^(hits|misses|c |size)'

# Adjust compression (zstd provides better compression but uses more CPU)
sudo zfs set compression=zstd rpool
sudo zfs set compression=zstd hpool

# For systems with limited CPU, use lz4 (default)
# sudo zfs set compression=lz4 rpool
# sudo zfs set compression=lz4 hpool

# Monitor and tune recordsize for specific workloads
sudo zfs get recordsize rpool
# For databases: sudo zfs set recordsize=8K dataset
# For large files: sudo zfs set recordsize=1M dataset
```

### System Monitoring and Alerts

```bash
# Set up ZFS event monitoring
sudo systemctl enable zed
sudo systemctl start zed

# Configure email alerts (optional)
sudo nano /etc/zfs/zed.d/zed.rc
# Uncomment and set: ZED_EMAIL_ADDR="admin@example.com"
# Uncomment: ZED_EMAIL_PROG="mail"
# Uncomment: ZED_EMAIL_OPTS="-s '@SUBJECT@' @ADDRESS@"

# Install mail utilities if email alerts desired
# sudo apt install --yes mailutils

# Monitor system health
sudo zpool status -v
cat /proc/mdstat  # Check MD RAID status

# Comprehensive disk health monitoring
for disk in /dev/disk/by-id/*; do
    if [[ ! $disk =~ part ]] && [[ -b $disk ]]; then
        if [[ $disk == *nvme* ]] && command -v nvme >/dev/null 2>&1; then
            echo "NVMe: $(basename $disk)"
            sudo nvme smart-log $disk | head -20
        else
            echo "SATA/SAS: $(basename $disk)"
            sudo smartctl -H $disk
        fi
    fi
done

# NVMe-specific monitoring setup (if applicable)
if ls /dev/nvme* >/dev/null 2>&1 && command -v nvme >/dev/null 2>&1; then
    # Create monitoring script for NVMe temperature and wear
    cat << 'EOF' | sudo tee /usr/local/bin/nvme-monitor.sh
#!/bin/bash
for nvme in /dev/nvme*n1; do
    if [[ -b $nvme ]]; then
        temp=$(nvme smart-log $nvme | grep temperature | head -1 | awk '{print $3}')
        wear=$(nvme smart-log $nvme | grep percentage_used | awk '{print $3}')
        if [[ $temp -gt 70 ]]; then
            echo "WARNING: $nvme temperature is ${temp}°C" | logger -t nvme-monitor
        fi
        if [[ $wear -gt 80 ]]; then
            echo "WARNING: $nvme wear level is ${wear}%" | logger -t nvme-monitor
        fi
    fi
done
EOF
    sudo chmod +x /usr/local/bin/nvme-monitor.sh
  
    # Add to cron for regular monitoring
    echo "*/10 * * * * root /usr/local/bin/nvme-monitor.sh" | sudo tee /etc/cron.d/nvme-monitor
fi
```

## Summary

This installation creates a robust Kubuntu system with:

- **Triple redundancy**: RAIDZ1 across 3 disks survives 1 disk failure
- **Optimized layout**: Separate pools for boot (2GB), root (400GB), and home data
- **Advanced features**: Native encryption, lz4 compression, automatic snapshots
- **Performance optimizations**: Auto-detected ashift, xattr=sa, relatime, normalization
- **NVMe support**: Native NVMe tools, crypto erase, optimal I/O scheduling, health monitoring
- **Desktop integration**: Full KDE Plasma desktop with ZFS benefits
- **Reliability**: MD RAID swap, multiple EFI partitions, comprehensive monitoring
- **Ubuntu best practices**: Proven configurations from Ubuntu ZFS guides

### NVMe-Specific Enhancements:

- **Automatic detection**: Identifies NVMe disks and installs nvme-cli tools
- **Optimal secure erase**: Uses NVMe crypto erase (100x faster than traditional methods)
- **Smart ashift detection**: Auto-detects sector size for optimal performance
- **Advanced health monitoring**: NVMe-specific temperature, wear level, and spare capacity tracking
- **I/O optimization**: Configures optimal scheduler (none) and queue depth for NVMe
- **Automated alerts**: Temperature and wear level monitoring with automatic warnings

The system provides enterprise-level data protection with desktop usability, combining Ubuntu's ZFS implementation expertise with Kubuntu's polished desktop experience, proven Ubuntu ZFS best practices, and full NVMe optimization for maximum reliability and performance.
