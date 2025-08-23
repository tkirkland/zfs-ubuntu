#!/bin/bash

# ZFS Installer

############################################
# Global array for device information
# Each device uses 3 consecutive indices:
#   [n*3+0] = traditional device name (e.g., /dev/nvme0n1, /dev/sda)
#   [n*3+1] = EUI/WWN ID from /dev/disk/by-id/
#   [n*3+2] = actual size in GB
############################################
get_unique_nvme_devices() {
  declare -a devices_array=()
  local device=""
  local device_path=""
  local device_id=""
  local device_size=""
  local device_type=""
  local is_removable=""

  # Clear array
  devices_array=()

  # Process all disk devices from lsblk
  while IFS= read -r device; do
    device_path="/dev/${device}"

    # Skip if not a block device
    if [[ ! -b "${device_path}" ]]; then
      continue
    fi

    # Check if device is removable (skip USB/external drives)
    is_removable="$(cat "/sys/block/${device}/removable" 2>/dev/null || echo "1")"
    if [[ "${is_removable}" == "1" ]]; then
      continue
    fi

    # Additional check for USB devices via the device path
    # USB devices typically appear in /sys/block/{device}/device/subsystem pointing to usb
    if [[ -L "/sys/block/${device}/device/subsystem" ]]; then
      local subsystem
      subsystem="$(basename "$(readlink "/sys/block/${device}/device/subsystem")" 2>/dev/null)"
      if [[ "${subsystem}" == "usb" ]]; then
        continue
      fi
    fi

    # Check if a device is connected via USB by examining the device path
    local device_uevent="/sys/block/${device}/device/uevent"
    if [[ -f "${device_uevent}" ]]; then
      if grep -q "DRIVER=usb-storage\|DRIVER=uas\|DEVTYPE=usb" "${device_uevent}" 2>/dev/null; then
        continue
      fi
    fi

    # Check parent device for USB connection
    local parent_path="/sys/block/${device}"
    if readlink -f "${parent_path}" | grep -q "/usb[0-9]/" 2>/dev/null; then
      continue
    fi

    # Get device type - only process NVMe and SATA/SAS drives
    if [[ "${device}" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
      device_type="nvme"
    elif [[ "${device}" =~ ^sd[a-z]+$ ]]; then
      device_type="sata"
    else
      # Skip other device types (loop, sr, etc.)
      continue
    fi

    # Get device size in bytes
    device_size="$(lsblk -b -d -n -o SIZE "${device_path}" 2>/dev/null | head -1)"
    if [[ -z "${device_size}" ]] || [[ "${device_size}" == "0" ]]; then
      continue
    fi

    # Find the by-id path (prefer EUI for NVMe, WWN for SATA)
    device_id=""
    if [[ "${device_type}" == "nvme" ]]; then
      # Look for NVMe EUI identifier
      device_id="$(find /dev/disk/by-id/ -type l -name "nvme-eui.*" -o -name "nvme-nvme.*" 2>/dev/null | \
                   while read -r link; do
                     if [[ "$(readlink -f "${link}")" == "${device_path}" ]]; then
                       echo "${link}"
                       break
                     fi
                   done)"
    else
      # Look for WWN or ATA identifier for SATA/SAS
      device_id="$(find /dev/disk/by-id/ -type l \( -name "wwn-*" -o -name "ata-*" \) 2>/dev/null | \
                   grep -v "\-part[0-9]" | \
                   while read -r link; do
                     if [[ "$(readlink -f "${link}")" == "${device_path}" ]]; then
                       echo "${link}"
                       break
                     fi
                   done)"
    fi

    # If no by-id path found, skip this device (unreliable)
    if [[ -z "${device_id}" ]]; then
      # Try one more time with a broader search
      device_id="$(find /dev/disk/by-id/ -type l 2>/dev/null | \
                   grep -v "\-part[0-9]" | \
                   while read -r link; do
                     if [[ "$(readlink -f "${link}")" == "${device_path}" ]]; then
                       echo "${link}"
                       break
                     fi
                   done | head -1)"

      if [[ -z "${device_id}" ]]; then
        echo "Warning: No persistent ID found for ${device_path}, skipping..." >&2
        continue
      fi
    fi

    # Add to array (3 indices per device)
    devices_array+=("${device_path}")  # Index n*3+0
    devices_array+=("${device_id}")    # Index n*3+1
    devices_array+=("${device_size}")  # Index n*3+2

  done < <(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print $1}')

  # Check if we found any devices
  local num_devices=$(( ${#devices_array[@]} / 3 ))
  if [[ ${num_devices} -eq 0 ]]; then
    echo "Error: No suitable storage devices found" >&2
    return 1
  fi

  # Print summary
  echo "Found ${num_devices} storage device(s):"
  echo "----------------------------------------"
  local i
  for (( i=0; i<${#devices_array[@]}; i+=3 )); do
    local device_num=$(( i / 3 + 1 ))
    printf "[%d] %-15s  %10s   %sGB\n" \
           "${device_num}" \
           "${devices_array[i]}" \
           "${devices_array[i+1]}" \
           "$(( devices_array[i+2] / 1024 / 1024 / 1024 ))"
  done
  echo "----------------------------------------"

  return 0
}

# Globals:
# Arguments:
#  None
main() {
  get_unique_nvme_devices
}

main "$@"
