# Proxmox VE ZFS Installation Procedures - Technical Summary

## Core ZFS Installation Flow

### 1. Disk Preparation Phase
```perl
# From extract_data() in Proxmox/Install.pm
foreach my $hd (@$devlist) {
    wipe_disk(@$hd[1]);                    # Clear existing data
}

# Create partitions on each disk
my ($size, $osdev, $efidev) = 
    partition_bootable_disk($devname, $hdsize, 'BF01');  # BF01 = ZFS partition type
```

### 2. ZFS Pool Creation
```perl
# From zfs_create_rpool() in Proxmox/Install.pm
sub zfs_create_rpool {
    my ($vdev, $pool_name, $root_volume_name) = @_;
    
    # Check for existing pools and handle conflicts
    zfs_ask_existing_zpool_rename($pool_name);
    
    # Get ZFS configuration options
    my $zfs_opts = Proxmox::Install::Config::get_zfs_opt();
    
    # Create the root pool
    my $cmd = "zpool create -f -o cachefile=none";
    $cmd .= " -o ashift=$zfs_opts->{ashift}" if defined($zfs_opts->{ashift});
    syscmd("$cmd $pool_name $vdev") == 0 || die "unable to create zfs root pool\n";
    
    # Create dataset hierarchy
    syscmd("zfs create $pool_name/ROOT") == 0;
    syscmd("zfs create $pool_name/ROOT/$root_volume_name") == 0;
    
    # Set ZFS properties
    syscmd("zfs set atime=on relatime=on $pool_name") == 0;
    syscmd("zfs set compression=$zfs_opts->{compress} $pool_name");
    syscmd("zfs set checksum=$zfs_opts->{checksum} $pool_name");
    syscmd("zfs set copies=$zfs_opts->{copies} $pool_name");
    syscmd("zfs set acltype=posix $pool_name/ROOT/$root_volume_name");
}
```

### 3. RAID Configuration Logic
```perl
# From get_zfs_raid_setup() in Proxmox/Install.pm
sub get_zfs_raid_setup {
    my $filesys = Proxmox::Install::Config::get_filesys();
    my $cmd = '';
    
    if ($filesys eq 'zfs (RAID0)') {
        foreach my $hd (@$devlist) {
            $cmd .= " @$hd[1]";                    # Simple stripe
        }
    } elsif ($filesys eq 'zfs (RAID1)') {
        $cmd .= ' mirror ';
        foreach my $hd (@$devlist) {
            zfs_mirror_size_check($expected_size, @$hd[2]);  # Validate sizes
            $cmd .= " @$hd[1]";
        }
    } elsif ($filesys eq 'zfs (RAID10)') {
        for (my $i = 0; $i < $diskcount; $i += 2) {
            my $hd1 = @$devlist[$i];
            my $hd2 = @$devlist[$i + 1];
            zfs_mirror_size_check(@$hd1[2], @$hd2[2]);
            $cmd .= ' mirror ' . @$hd1[1] . ' ' . @$hd2[1];
        }
    } elsif ($filesys =~ m/^zfs \(RAIDZ-([123])\)$/) {
        my $level = $1;
        $cmd .= " raidz$level";
        foreach my $hd (@$devlist) {
            zfs_mirror_size_check($expected_size, @$hd[2]);
            $cmd .= " @$hd[1]";
        }
    }
    
    return ($devlist, $cmd);
}
```

### 4. ZFS Module Configuration
```perl
# From zfs_setup_module_conf() in Proxmox/Install.pm
my sub zfs_setup_module_conf {
    my ($targetdir) = @_;
    
    my $arc_max_mib = Proxmox::Install::Config::get_zfs_opt('arc_max');
    my $arc_max = Proxmox::Install::RunEnv::clamp_zfs_arc_max($arc_max_mib) * 1024 * 1024;
    
    file_write_all("$targetdir/etc/modprobe.d/zfs.conf", "options zfs zfs_arc_max=$arc_max\n");
}
```

### 5. Bootloader Integration
```perl
# Boot device setup for each disk
foreach my $di (@$bootdevinfo) {
    next if !$di->{esp};
    # Create FAT32 filesystem on EFI System Partition
    my $vfat_extra_opts = ($di->{logical_bsize} == 4096) ? '-s1' : '';
    syscmd("mkfs.vfat $vfat_extra_opts -F32 $di->{esp}") == 0;
}
```

## Key ZFS Configuration Parameters

### Default ZFS Options
```perl
zfs_opts => {
    ashift => 12,                    # Pool sector size (2^12 = 4KB)
    compress => 'on',               # Enable compression
    checksum => 'on',               # Enable checksums  
    copies => 1,                    # Number of data copies
    arc_max => <calculated>,        # Maximum ARC size in MiB
}
```

### Pool Properties Applied
- `cachefile=none` - No cache file for imported pools
- `atime=on relatime=on` - Access time updates with relatime optimization
- `acltype=posix` - POSIX ACL support on root filesystem

### Performance Optimizations
- `sync=disabled` during installation for speed
- ARC size automatically calculated based on system memory
- Compression enabled by default

## Error Handling and Validation

### Pool Name Conflicts
```perl
sub zfs_ask_existing_zpool_rename {
    my ($pool_name) = @_;
    
    my $exported_pools = Proxmox::Sys::ZFS::get_exported_pools();
    my ($pool_info) = grep { $_->{name} eq $pool_name } $exported_pools->@*;
    
    if ($pool_info) {
        # Prompt user to rename existing pool or cancel installation
        my $pool_id = $pool_info->{id};
        Proxmox::Sys::ZFS::rename_pool($pool_id, $new_name);
    }
}
```

### Disk Size Validation
```perl
sub zfs_mirror_size_check {
    my ($expected, $actual) = @_;
    
    die "mirrored disks must have same size\n"
        if abs($expected - $actual) > $expected / 10;  # 10% tolerance
}
```

### Legacy BIOS 4K Sector Check
```perl
sub legacy_bios_4k_check {
    my ($lbs) = @_;
    my $run_env = Proxmox::Install::RunEnv::get();
    die "Booting from 4kn drive in legacy BIOS mode is not supported.\n"
        if $run_env->{boot_type} ne 'efi' && $lbs == 4096;
}
```

## Installation Sequence Summary

1. **Preparation**
   - Load ZFS kernel module
   - Validate disk configurations
   - Check for existing ZFS pools

2. **Partitioning**
   - Create GPT partition table
   - EFI System Partition (512MB, FAT32)
   - ZFS partition (remaining space, type BF01)

3. **ZFS Setup**
   - Create root pool with RAID configuration
   - Create ROOT container dataset
   - Create root filesystem dataset
   - Apply ZFS properties and optimizations

4. **System Installation**
   - Mount ZFS filesystems
   - Extract base system
   - Configure ZFS module parameters
   - Set up bootloader

5. **Finalization**
   - Unmount filesystems
   - Export pools
   - Configure system for first boot

This provides a comprehensive technical reference for implementing ZFS installation procedures based on Proxmox VE's proven approach.