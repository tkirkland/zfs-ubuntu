# Proxmox VE ZFS Installation Analysis

This directory contains extracted components from Proxmox VE 9.0-1 installer related to ZFS installation procedures.

## Extracted Components

### Main Installer Scripts
- `proxinstall` - Main GUI installer (Perl/GTK3)
- `proxmox-low-level-installer` - Text-based/API installer
- `proxmox-tui-installer` - Text User Interface installer
- `proxmox-auto-installer` - Automated installer

### Perl Modules
- `Proxmox/Install.pm` - Main installation logic
- `Proxmox/Install/Config.pm` - Configuration management
- `Proxmox/Install/StorageConfig.pm` - Storage configuration
- `Proxmox/Sys/ZFS.pm` - ZFS system utilities
- `Proxmox/Install/ISOEnv.pm` - ISO environment management
- `Proxmox/Install/RunEnv.pm` - Runtime environment

## Key ZFS Functions

### ZFS Pool Creation (`Proxmox/Install.pm`)
- `zfs_create_rpool()` - Creates ZFS root pool
- `get_zfs_raid_setup()` - Configures RAID layouts (RAID0, RAID1, RAID10, RAIDZ-1/2/3)
- `zfs_mirror_size_check()` - Validates mirror disk sizes
- `zfs_setup_module_conf()` - Configures ZFS kernel module parameters

### ZFS RAID Configurations Supported
- **RAID0**: Simple stripe across devices
- **RAID1**: Mirror across 2+ devices  
- **RAID10**: Mirrored pairs (4+ devices, even number required)
- **RAIDZ-1**: Single parity (3+ devices)
- **RAIDZ-2**: Double parity (4+ devices) 
- **RAIDZ-3**: Triple parity (5+ devices)

### ZFS Pool Layout
- Main pool: `rpool` (configurable name)
- Root container: `rpool/ROOT`
- Root filesystem: `rpool/ROOT/<uuid>`
- Data container: `rpool/data` (PVE only)
- VM storage: `rpool/var-lib-vz` (PVE only)

### Key ZFS Options
- **ashift**: Pool sector size (9-13, default 12)
- **compression**: Algorithm (on/off/lzjb/lz4/zle/gzip/zstd)
- **checksum**: Algorithm (on/fletcher4/sha256)
- **copies**: Data copies (1-3)
- **arc_max**: Maximum ARC size in MiB

## Installation Process (ZFS Path)

1. **Disk Preparation**
   - Wipe existing data with `wipe_disk()`
   - Create GPT partitions with `partition_bootable_disk()`
   - EFI System Partition (512MB)
   - ZFS partition (remaining space, type BF01)

2. **ZFS Pool Creation**
   - Load ZFS kernel module
   - Create pool with `zpool create -f -o cachefile=none`
   - Set ashift parameter based on disk type
   - Create ROOT container dataset
   - Create root filesystem dataset

3. **ZFS Properties**
   - Enable atime with relatime
   - Set compression algorithm
   - Configure checksum algorithm
   - Set data copies if > 1
   - Set POSIX ACLs on root filesystem

4. **System Installation**
   - Mount ZFS filesystems
   - Extract base system with unsquashfs
   - Configure bootloader
   - Set up ZFS module configuration

## Comparison with Manual ZFS Installation

The Proxmox installer follows similar principles to manual ZFS-on-root installations but with some differences:

### Similarities
- Uses GPT partitioning
- Creates EFI System Partition
- Uses pool/ROOT/dataset hierarchy
- Configures proper mount points
- Sets up bootloader integration

### Differences
- Single pool design (vs separate boot/root/home pools in our kubuntu_zfs.sh)
- No separate boot pool (relies on EFI partition only)
- Different dataset organization
- Integrated with Proxmox-specific features

## Relevance to kubuntu_zfs.sh

Key insights for our ZFS installation script:
1. Partition creation and RAID setup logic
2. ZFS property configuration patterns
3. Error handling and validation approaches
4. Module parameter configuration
5. Bootloader integration methods

The Proxmox installer provides a robust reference implementation for automated ZFS installation procedures.