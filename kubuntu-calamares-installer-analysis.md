# Kubuntu Calamares Installer Analysis

Analysis of Kubuntu's Calamares-based installer system and its installation orchestration logic.

## Calamares Architecture Overview

Kubuntu uses Calamares, a modular installer framework with a clear separation between UI and backend operations.

### Core Configuration Structure
- **Main Config**: `settings.conf` - defines module sequence and execution flow
- **Module Configs**: Individual `.conf` files for each installation component
- **Branding**: Kubuntu-specific UI theme and product information
- **OEM Support**: Specialized OEM configuration for manufacturer setups

### Installation Flow Architecture

From `settings.conf` - Two-phase installation process:

#### Phase 1: Show (Interactive UI)
```yaml
sequence:
- show:
  - welcome      # Welcome screen with language selection
  - locale       # Regional and language configuration  
  - keyboard     # Keyboard layout selection
  - pkgselect    # Package selection (minimal vs full)
  - partition    # Disk partitioning interface
  - users        # User account creation
  - summary      # Installation summary and confirmation
```

#### Phase 2: Exec (Backend Installation)
```yaml
- exec:
  - partition                              # Execute disk partitioning
  - mount                                 # Mount target filesystems
  - unpackfs                              # Extract system from squashfs
  - machineid                             # Generate machine-id
  - fstab                                 # Generate filesystem table
  - locale                                # Apply locale settings
  - keyboard                              # Configure keyboard
  - localecfg                             # Additional locale configuration
  - luksbootkeyfile                       # LUKS encryption setup
  - users                                 # Create user accounts
  - displaymanager                        # Configure SDDM login manager
  - networkcfg                            # Network configuration
  - hwclock                               # Hardware clock setup
  - shellprocess@copy_vmlinuz_shellprocess # Copy kernel from live media
  - shellprocess@bug-LP#1829805           # Bug fix shell process
  - shellprocess@fixconkeys_part1         # Console key fixes (part 1)
  - shellprocess@fixconkeys_part2         # Console key fixes (part 2)
  - initramfscfg                          # Configure initramfs
  - initramfs                             # Generate initramfs
  - grubcfg                               # Configure GRUB settings
  - contextualprocess@before_bootloader   # Pre-bootloader package installation
  - bootloader                            # Install GRUB bootloader
  - shellprocess@add386arch               # Add i386 architecture support
  - automirror                            # Configure package mirrors
  - pkgselectprocess                      # Process package selections
  - shellprocess@logs                     # Collect installation logs
  - umount                                # Unmount filesystems
```

## Module Analysis

### 1. Partition Module (`partition.conf`)

```yaml
efiSystemPartition: "/boot/efi"
enableLuksAutomatedPartitioning: true
luksGeneration: luks2
userSwapChoices: [none, file]
initialSwapChoice: file
defaultFileSystemType: "ext4"
availableFileSystemTypes: ["ext4","btrfs","xfs"]

partitionLayout:
  - name: "kubuntu_boot"
    filesystem: ext4
    noEncrypt: true
    onlyPresentWithEncryption: true
    mountPoint: "/boot"
    size: 4G
  - name: "kubuntu_2504" 
    filesystem: unknown
    mountPoint: "/"
    size: 100%
```

**Key Features**:
- **LUKS2 Support**: Automatic encryption with modern LUKS2 format
- **Flexible Filesystem**: Supports ext4, btrfs, xfs
- **EFI Integration**: Proper EFI system partition handling
- **Swap Options**: File-based swap or no swap

### 2. Mount Module (`mount.conf`)

```yaml
extraMounts:
  - device: proc, fs: proc, mountPoint: /proc
  - device: sys, fs: sysfs, mountPoint: /sys
  - device: /dev, mountPoint: /dev, options: [bind]
  - device: tmpfs, fs: tmpfs, mountPoint: /run
  - device: /run/udev, mountPoint: /run/udev, options: [bind]
  - device: efivarfs, fs: efivarfs, mountPoint: /sys/firmware/efi/efivars, efi: true
  - device: /cdrom, mountPoint: /media/cdrom, options: [bind]

mountOptions:
  - filesystem: btrfs
    options: [defaults, noatime, autodefrag]
    ssdOptions: [discard, compress=lzo]
  - filesystem: ext4
    ssdOptions: [discard]
```

**Key Features**:
- **Complete chroot Environment**: Binds all necessary virtual filesystems
- **EFI Variables**: Mounts efivarfs for EFI management
- **SSD Optimization**: Automatic TRIM/discard for SSDs
- **Media Access**: Maintains access to installation media

### 3. Unpack Module (`unpackfs.conf`)

```yaml
unpack:
  - source: "/cdrom/casper/filesystem.squashfs"
    sourcefs: "squashfs"  
    destination: ""
```

**Key Features**:
- **Squashfs Extraction**: Extracts compressed filesystem from live media
- **Casper Integration**: Uses Ubuntu's casper live system format
- **Efficient Transfer**: Direct squashfs mounting and extraction

### 4. Users Module (`users.conf`)

```yaml
doAutologin: false
setRootPassword: false
sudoersGroup: sudo
defaultGroups: [adm, cdrom, dip, lpadmin, plugdev, sambashare, sudo]

passwordRequirements:
  minLength: 8
  libpwquality: [minlen=8, maxrepeat=3, maxsequence=3, usersubstr=4, badwords=linux]
  
user:
  shell: /bin/bash
  forbidden_names: [root, nginx, www-data, daemon, bin, sys, ...]
```

**Key Features**:
- **Security Focused**: Strong password requirements with libpwquality
- **Ubuntu Standards**: Uses sudo group and standard system groups  
- **Bash Shell**: Explicitly sets bash as default shell
- **Protection**: Prevents creation of system/service account names

### 5. Package Selection (`pkgselect.conf`)

```yaml
packages:
  additional_packages:
    - id: "element-desktop", name: "Element", snap: true
    - id: "krita", name: "Krita", snap: true
    
  minimal_remove_packages:
    [kmahjongg, kmines, kpat, ksudoku, skanlite, okular, "libreoffice*", 
     kdeconnect, vim, snapd, partitionmanager, plasma-welcome]
     
  installer_remove_packages:
    ["^live-*", calamares-settings-kubuntu, calamares, 
     fcitx5, kubuntu-installer-prompt]
     
  regular_install_packages:
    [language-pack-$LOCALE, language-pack-kde-$LOCALE, 
     hunspell-$LOCALE, libreoffice-l10n-$LOCALE]
     
  refresh_snaps: ["firefox", "thunderbird", "firmware-updater"]
```

**Key Features**:
- **Modular Package Selection**: Optional additional packages via snap
- **Minimal Install**: Removes games and unnecessary applications  
- **Cleanup**: Removes live system and installer packages
- **Localization**: Installs language packs based on user selection
- **Snap Integration**: Refreshes core snap packages

### 6. Bootloader Module (`bootloader.conf`)

```yaml
efiBootLoader: "grub"
grubInstall: "grub-install"
grubMkconfig: "grub-mkconfig"  
grubCfg: "/boot/grub/grub.cfg"
efiBootloaderId: "ubuntu"

# systemd-boot fallback configuration
kernel: "/vmlinuz-linux"
img: "/initramfs-linux.img"
timeout: "10"
```

**Key Features**:
- **GRUB Focus**: Primary bootloader is GRUB with Ubuntu branding
- **EFI Integration**: Proper EFI bootloader ID management
- **Systemd-boot Fallback**: Configuration for alternative bootloader
- **Ubuntu Compatibility**: Uses Ubuntu bootloader conventions

### 7. Shell Process Modules

#### Copy Kernel (`copy_vmlinuz_shellprocess.conf`)
```bash
script:
  - command: "cp /cdrom/casper/vmlinuz ${ROOT}/boot/vmlinuz-$(uname -r)"
```

#### Architecture Support (`shellprocess_add386arch.conf`)
```bash
script:
  - command: "/usr/bin/dpkg --add-architecture i386"
```

#### Bootloader Package Installation (`before_bootloader_context.conf`)
```yaml
firmwareType:
  "*":
    - command: apt-cdrom add -m -d=/media/cdrom/
    - command: apt install -y grub-efi-amd64-signed
    - command: apt install -y shim-signed
```

### 8. GRUB Configuration (`grubcfg.conf`)

```yaml
overwrite: false
defaults:
  GRUB_ENABLE_CRYPTODISK: true
```

**Key Features**:
- **Encryption Support**: Enables GRUB cryptodisk for LUKS
- **Non-destructive**: Preserves existing GRUB settings
- **Minimal Configuration**: Focuses on essential settings

## Kubuntu-Specific Installer Features

### Branding Integration (`branding.desc`)
```yaml
strings:
  productName: Kubuntu
  version: 25.04
  shortVersion: plucky
  bootloaderEntryName: Kubuntu
  productUrl: https://kubuntu.org/

style:
  SidebarBackground: "#6C7B93"
  SidebarText: "#FFFFFF" 
  SidebarTextCurrent: "#0068C8"
```

### OEM Configuration Support
- **OEM Setup Mode**: Specialized configuration for manufacturer pre-installation
- **Post-Install Cleanup**: Removes OEM-specific files after user setup
- **Restricted Interface**: Simplified OEM setup workflow

### Display Manager Integration  
- **SDDM Configuration**: KDE's Simple Desktop Display Manager
- **Automatic Configuration**: Sets up graphical login with Kubuntu theming
- **User Session Management**: Integrates with KDE Plasma desktop

## Installation Process Flow

### Phase 1: Pre-Installation
1. **Live Environment**: Boot from Kubuntu ISO with Calamares installer
2. **Hardware Detection**: Detect system capabilities and hardware
3. **User Interface**: Present Kubuntu-branded installation wizard
4. **Configuration Collection**: Gather user preferences (language, keyboard, partitioning, users)

### Phase 2: Disk Preparation  
1. **Partition Creation**: Create EFI, boot, and root partitions
2. **Filesystem Creation**: Format partitions with selected filesystem
3. **Encryption Setup**: Configure LUKS2 encryption if requested
4. **Mount Preparation**: Mount target filesystems in proper hierarchy

### Phase 3: System Installation
1. **Base System**: Extract Kubuntu filesystem from squashfs
2. **Chroot Setup**: Bind mount virtual filesystems for chroot environment
3. **System Configuration**: Configure basic system settings (hostname, locale, users)
4. **Package Management**: Install/remove packages based on user selection

### Phase 4: Boot Configuration
1. **Kernel Setup**: Copy kernel from live media to target system
2. **Initramfs Generation**: Create initial ramdisk with proper modules
3. **GRUB Installation**: Install and configure GRUB bootloader
4. **EFI Configuration**: Set up EFI boot entries with secure boot support

### Phase 5: Finalization
1. **Service Configuration**: Set up system services (SDDM, networking)
2. **User Account Setup**: Create user accounts with proper groups and permissions
3. **Cleanup**: Remove installer packages and live system components
4. **Log Collection**: Gather installation logs for troubleshooting

## Calamares Extension Points

### Custom Module Integration
- **Shell Process Hooks**: Execute custom scripts at specific points
- **Contextual Processes**: Conditional execution based on system state
- **Package Hooks**: Custom package management operations
- **Mount Hooks**: Additional filesystem mounting logic

### Configuration Flexibility
- **YAML Configuration**: Human-readable configuration files
- **Module Instances**: Multiple configurations of the same module
- **Conditional Logic**: Firmware-type and state-based execution
- **Timeout Management**: Configurable timeouts for long operations

### Error Handling and Recovery
- **Graceful Failures**: Continue installation when non-critical operations fail
- **Log Integration**: Comprehensive logging for troubleshooting
- **Rollback Support**: Ability to undo completed operations on failure
- **User Feedback**: Clear error reporting and recovery options

## Integration with Ubuntu Ecosystem

### Package Management
- **APT Integration**: Native Ubuntu package management
- **Snap Support**: Core snap packages with refresh capability
- **PPA Support**: Additional package repositories
- **Language Pack Integration**: Automatic localization package installation

### Security Features
- **LUKS2 Encryption**: Modern disk encryption with secure defaults
- **Secure Boot**: SHIM and signed bootloader integration  
- **User Security**: Strong password policies and secure group membership
- **System Hardening**: Removal of development and debugging tools

### Hardware Support
- **EFI/UEFI**: Full EFI boot support with fallbacks
- **Secure Boot**: Integration with Microsoft-signed bootloaders
- **Architecture Support**: Multi-architecture package support (i386 compatibility)
- **Driver Integration**: Automatic hardware driver installation

This analysis shows Calamares provides a robust, modular installer framework that can be adapted for ZFS installation by modifying the partition, mount, and bootloader modules while preserving Kubuntu's desktop environment integration.