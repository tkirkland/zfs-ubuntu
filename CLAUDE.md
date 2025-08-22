# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains tools and scripts for automated ZFS-based Ubuntu/Kubuntu installation with RAID configurations. The main focus is on creating robust, encrypted ZFS installations across multiple disks for enterprise-level data protection.

## Core Components

### Main Installation Script: `kubuntu_zfs.sh`
- **Location**: `kubuntu_zfs.sh` (root level)
- **Purpose**: 9-phase automated installation script for Kubuntu with 3-disk RAIDZ1 ZFS setup
- **Key Features**: 
  - Error handling with automatic cleanup
  - Checkpoint/resume functionality
  - Support for both NVMe and SATA drives
  - Separate encrypted pools: bpool (boot), rpool (root), hpool (home)
  - Multi-EFI partition redundancy

### Python Package Structure
- **Package**: `src/zfs_ubuntu/` - Minimal Python package structure
- **Build System**: Uses Hatchling build backend
- **Version**: Managed in `src/zfs_ubuntu/__about__.py`

### Documentation Files
- **Installation Guide**: `kubuntu-3disk-raidz1-zfs-install.md` - Comprehensive manual installation guide
- **Ubuntu Reference**: `ubuntu_22_04_root_on_zfs.md` - OpenZFS documentation reference
- **Analysis Documents**: Various `*-analysis.md` files for installer research

## Development Commands

### Testing and Validation
```bash
# Validate shell script syntax
bash -n kubuntu_zfs.sh

# Run shellcheck for style compliance (follows Google Shell Style Guide)
shellcheck kubuntu_zfs.sh

# Test in virtual environment
# Use minimum 3 virtual disks, 8GB RAM, UEFI mode
```

### Python Package Management
```bash
# Install in development mode
pip install -e .

# Type checking
hatch run types:check

# Run coverage
hatch run cov
```

### Shell Script Testing
```bash
# Dry run validation (check disk detection without modification)
sudo bash kubuntu_zfs.sh --dry-run  # Note: This flag is not implemented yet

# Manual phase testing - script supports checkpoint/resume
# If installation fails, can resume from last completed phase
```

## Architecture & Design Patterns

### Error Handling Strategy
- **Strict Mode**: All scripts use `set -euo pipefail`
- **Cleanup Function**: Automatic ZFS pool cleanup on script failure
- **Checkpoint System**: Save/restore installation state across reboots
- **Validation Gates**: Comprehensive disk and system validation before destructive operations

### ZFS Pool Layout
```
bpool (boot):   2GB  RAIDZ1 - GRUB-compatible features only
rpool (root):   400GB RAIDZ1 - Encrypted, full ZFS features  
hpool (home):   Remaining RAIDZ1 - Encrypted, user data separation
```

### Partition Scheme (per disk)
```
part1: 512MB EFI System Partition (FAT32)
part2: 8GB   Swap (first disk only)
part3: 2GB   Boot pool partition
part4: 400GB Root pool partition  
part5: Rest  Home pool partition
```

### Dataset Organization
- Container datasets: `ROOT`, `BOOT`, `HOME` (unmountable)
- System datasets: `kubuntu_<UUID>` with zsys metadata
- Subdatasets: Separate datasets for `/var/log`, `/var/cache`, etc.
- User datasets: Individual encrypted datasets per user

## Critical Installation Variables

When working with the installation scripts, these variables are essential:

```bash
# Disk selections (must use /dev/disk/by-id/ paths)
DISK1=/dev/disk/by-id/[device-id]
DISK2=/dev/disk/by-id/[device-id]  
DISK3=/dev/disk/by-id/[device-id]

# Auto-detected values
UUID=$(dd if=/dev/urandom bs=1 count=100 2>/dev/null | tr -dc 'a-z0-9' | cut -c-6)
ASHIFT=12  # Automatically detected based on drive type
```

## Common Development Tasks

### Adding New Features to Installation Script

1. **Follow the 9-phase structure**:
   - Phase 1: Environment preparation
   - Phase 2: Disk selection  
   - Phase 3: Disk preparation
   - Phase 4: ZFS pool creation
   - Phase 5: Dataset creation
   - Phase 6: System installation
   - Phase 7-9: Chroot operations

2. **Add checkpoint support**: Use `save_checkpoint()` and `should_skip_phase()`

3. **Include validation**: Always validate inputs and system state

4. **Support both NVMe and SATA**: Use disk type detection logic

### Debugging Failed Installations

1. **Check checkpoint state**: `cat /tmp/kubuntu-zfs-install/checkpoint`
2. **Review logs**: Installation logs in `/tmp/kubuntu-zfs-install/`
3. **Manual pool import**: `zpool import -f rpool bpool hpool`
4. **Check encryption status**: `zfs get keystatus rpool hpool`

### Working with ZFS Encryption

```bash
# Load encryption keys
zfs load-key rpool
zfs load-key hpool

# Check encryption status
zfs get encryption,keystatus,keylocation rpool hpool

# Mount encrypted datasets
zfs mount -a
```

## Style Guide Compliance

The shell scripts follow the **Google Shell Style Guide** (see `STYLE_GUIDE.md`):

- Functions documented with header comments including Globals, Arguments, Returns
- 2-space indentation, no tabs
- 80-character line limit
- Proper variable quoting: `"${variable}"`
- Error handling with meaningful messages
- Consistent naming: lowercase with underscores

## Security Considerations

- **Encryption keys**: Always backup encryption passphrases and metadata
- **Disk validation**: Comprehensive checks before destructive operations  
- **Path safety**: Use `/dev/disk/by-id/` paths for persistence
- **Privilege escalation**: Script requires root but validates permissions
- **Network security**: Package verification through apt update/install

## Testing Environment Setup

### Virtual Machine Requirements
- **Memory**: Minimum 8GB (4GB absolute minimum)
- **Storage**: 3 virtual disks minimum 167GB each
- **Firmware**: UEFI mode required for 4Kn drive support
- **Network**: Internet connectivity for package downloads

### Physical Hardware Requirements  
- **RAM**: 4GB minimum, 8GB recommended for ZFS ARC
- **Storage**: 3 identical disks (500GB minimum total)
- **CPU**: Modern x86_64 with UEFI support
- **Network**: Required for package installation

## Common Issues and Solutions

### Boot Issues
- **Missing GRUB**: Check EFI partition integrity, reinstall to backup partitions
- **Encryption prompts**: System prompts for rpool and hpool passphrases separately
- **Pool import failures**: Use `zpool import -f` and check disk connectivity

### Performance Issues
- **High memory usage**: Tune ZFS ARC size in `/etc/modprobe.d/zfs.conf`
- **Slow I/O**: Verify ashift settings match drive sector size
- **High CPU**: Disable log compression if using ZFS compression

### Recovery Procedures
- **Lost encryption keys**: Use backup from `/root/zfs-keys-backup/`
- **Corrupted pool**: Boot from live CD, import pools, run `zpool scrub`
- **Failed upgrade**: Boot to snapshot, rollback with `zfs rollback`

## File Organization

```
.
├── kubuntu_zfs.sh                    # Main automated installer
├── kubuntu-3disk-raidz1-zfs-install.md  # Manual installation guide
├── ubuntu_22_04_root_on_zfs.md       # Reference documentation
├── STYLE_GUIDE.md                    # Shell coding standards
├── pyproject.toml                    # Python package configuration
├── src/zfs_ubuntu/                   # Python package source
├── tests/                            # Test files
├── calamares/                        # GUI installer customizations
└── *.md                              # Analysis and documentation files
```

This project combines automated scripting with comprehensive documentation to enable reliable, repeatable ZFS installations with enterprise-level features.