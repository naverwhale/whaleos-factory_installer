#!/bin/bash

# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script contains debug functions called by factory_install.sh

. "/usr/share/misc/storage-info-common.sh"
. "/usr/sbin/write_gpt.sh"

DEBUG_FUNCTIONS=(call_dev_debug_vboot call_mosys_eventlog sys_fw_log call_dmesg
                 call_get_storage_info checksums call_lspci cat_write_gpt
                 dd_storage debug_get_fixed_dst_drive)

# Checks if the given debug action is valid and supported.
is_valid_debug_action() {
  [ "$1" -eq "$1" 2>/dev/null ] &&
  [ "$1" -ge 0 -a "$1" -lt "${#DEBUG_FUNCTIONS[@]}" ]
}

debug_menu() {
  echo "## Available information in Debug console:"
  echo "##   a) Print all debug information"
  echo "##   0) dev_debug_vboot"
  echo "##   1) firmware event log"
  echo "##   2) /sys/firmware/log"
  echo "##   3) kernel log"
  echo "##   4) Storage Information"
  echo "##   5) checksums"
  echo "##   6) lspci"
  echo "##   7) /usr/sbin/write_gpt.sh"
  echo "##   8) dd storage device"
  echo "##   9) get_fixed_dst_drive logs"
  echo "##   s) Save all debug information to USB"
  echo "##   q) Quit debug console"
}

debug_functions_all() {
  for debug_function in "${DEBUG_FUNCTIONS[@]}"; do
    "${debug_function}"
  done
}

call_dev_debug_vboot() {
  echo
  echo "## dev_debug_vboot:"
  dev_debug_vboot || true

  echo
  echo "## debug_vboot_noisy.log:"
  cat /var/log/debug_vboot_noisy.log || true
}

call_mosys_eventlog() {
  echo
  echo "## firmware event log:"
  mosys eventlog list || true
}

sys_fw_log() {
  echo
  echo "## /sys/firmware/log:"
  cat /sys/firmware/log || true
}

call_dmesg() {
  echo
  echo "## kernel log:"
  dmesg || true
}

call_get_storage_info() {
  echo
  echo "## Storage information:"
  get_storage_info || true
}

checksums() {
  echo
  echo "## checksums:"
  local parts=$(sed -n 's/.* \([^ ]*[^0-9][24]$\)/\1/p' /proc/partitions)
  for part in ${parts}; do
    md5sum "/dev/${part}" || true
  done
}

call_lspci() {
  echo
  echo "## lspci:"
  lspci -t || true
}

cat_write_gpt() {
  echo
  echo "## /usr/sbin/write_gpt.sh:"
  cat /usr/sbin/write_gpt.sh || true
}

dd_storage() {
  storage_devices=$(lsblk | grep disk | awk '{print $1}')
  echo
  echo "## dd storage device:"
  for device in ${storage_devices}; do
    for part in p2 p4 2 4; do
      local name="${device}${part}"
      if [ -e "/dev/${name}" ]; then
        echo
        echo "### dd ${name}:"
        dd if="/dev/${name}" bs=512 count=1 status=none | od -xc -Ax || true
      fi
    done
  done
}

debug_get_fixed_dst_drive() {
  load_base_vars
  # Modify get_fixed_dst_drive function from
  # platform2/chromeos-common-script/share/chromeos-common.sh
  # and add more logs to help debug "Cannot find fixed drive." issue.
  local dev rootdev
  echo "DEFAULT_ROOTDEV: ${DEFAULT_ROOTDEV}"
  if [ -n "${DEFAULT_ROOTDEV}" ]; then
    # No " here, the variable may contain wildcards.
    for rootdev in ${DEFAULT_ROOTDEV}; do
      echo "rootdev: ${rootdev}"
      dev="/dev/$(basename "${rootdev}")"
      echo "original dev: ${dev}"
      if [ -b "${dev}" ]; then
        echo "original dev exists"
        case "${dev}" in
          *nvme*)
            dev="/dev/$(get_largest_nvme_namespace "${dev}")"
            ;;
        esac
        break
      else
        echo "original dev does not exist"
        dev=""
      fi
    done
  else
    echo "DEFAULT_ROOTDEV does not exist"
    dev=""
  fi
  echo "final dev: ${dev}"
  echo "If your devices path is not in the DEFAULT_ROOTDEV,"
  echo "then update baseboard-BOARD/scripts/disk_layout.json"
  echo "nvme:"
  echo "$(find /sys/devices -name nvme*)"
  echo "mmc:"
  echo "$(find /sys/devices -name mmc*)"
}

debug_save_logs() {
  echo "-- USB info --"
  lsblk -p -S

  echo
  echo "-- select USB device to save log file --"
  usbs=$(lsblk -p -S | grep usb | awk '{print $1}')
  for usb in ${usbs}; do
    lsblk -p "${usb}" -l | grep part
  done

  read -p "Enter usb device partition(eg. /dev/sdb1) > " usb_part

  local mount_point="/media"
  mount "${usb_part}" "${mount_point}" || true
  if ! lsblk | grep -q "${mount_point}"; then
    echo "Fail to mount ${usb_part} to ${mount_point}"
    return
  fi
  debug_functions_all > "${mount_point}/debug.log" 2>&1
  umount "${mount_point}" || true

  echo "-- debug.log saved to ${usb_part}. --"
}

main() {
  while true; do
    clear
    debug_menu
    read -p 'debug_action> ' action
    action="$(echo "${action}" | tr 'A-Z' 'a-z')"

    case "${action}" in
      "a")
        debug_functions_all 2>&1 | secure_less.sh
        ;;
      "s")
        debug_save_logs
        ;;
      "q")
        break
        ;;
      *)
        if is_valid_debug_action "${action}"; then
          "${DEBUG_FUNCTIONS[action]}" 2>&1 | secure_less.sh
        else
          echo "Invalid debug action."
        fi
        ;;
    esac

    read -N 1 -p "Press any key to continue to debug console> "
  done
}
main "$@"