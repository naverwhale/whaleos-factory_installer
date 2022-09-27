#!/bin/bash

# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e
umask 022

# Dump bash trace to default log file.
: "${LOG_FILE:=/var/log/factory_install.log}"
: "${LOG_TTY:=}"
if [ -n "${LOG_FILE}" ]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  # shellcheck disable=SC2093 disable=SC1083
  exec {LOG_FD}>>"${LOG_FILE}"
  export BASH_XTRACEFD="${LOG_FD}"
fi

. "/usr/share/misc/storage-info-common.sh"
# Include after other common include, side effect on GPT variable.
. "/usr/sbin/write_gpt.sh"
. "$(dirname "$0")/factory_common.sh"
. "$(dirname "$0")/factory_cros_payload.sh"
. "$(dirname "$0")/factory_tpm.sh"

normalize_server_url() {
  local removed_protocol="${1#http://}"
  local removed_path="${removed_protocol%%/*}"
  echo "http://${removed_path}"
}

# Variables from dev_image/etc/lsb-factory that developers may want to override.
#
# - Override this if we want to install with a board different from installer
BOARD="$(findLSBValue CHROMEOS_RELEASE_BOARD)"
# - Override this if we want to install with a different factory server.
OMAHA="$(normalize_server_url "$(findLSBValue CHROMEOS_AUSERVER)")"
# - Override this for the default action if no keys are pressed before timeout.
DEFAULT_ACTION="$(findLSBValue FACTORY_INSTALL_DEFAULT_ACTION)"
# - Override this to enable/disable the countdown before doing default action.
ACTION_COUNTDOWN="$(findLSBValue FACTORY_INSTALL_ACTION_COUNTDOWN)"
# - Override this to 'false' to prevent waiting for prompt after installation.
COMPLETE_PROMPT="$(findLSBValue FACTORY_INSTALL_COMPLETE_PROMPT |
                   tr 'A-Z' 'a-z')"

# Variables prepared by image_tool or netboot initramfs code.
NETBOOT_RAMFS="$(findLSBValue NETBOOT_RAMFS)"
FACTORY_INSTALL_FROM_USB="$(findLSBValue FACTORY_INSTALL_FROM_USB)"
RMA_AUTORUN="$(findLSBValue RMA_AUTORUN)"

# Global variables
DST_DRIVE=""
EC_PRESENT=0
COMPLETE_SCRIPT=""

# The ethernet interface to be used. It will be determined in
# check_ethernet_status and be passed to cros_payload_get_server_json_path as an
# environment variable.
ETH_INTERFACE=""

# Definition of ChromeOS partition layout
DST_FACTORY_KERNEL_PART=2
DST_FACTORY_PART=3
DST_RELEASE_KERNEL_PART=4
DST_STATE_PART=1

# Supported actions (a set of lowercase characters)
# Each action x is implemented in an action_$x handler (e.g.,
# action_i); see the handlers for more information about what
# each option is.
SUPPORTED_ACTIONS=bcdeimrstuvyz
if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
  SUPPORTED_ACTIONS=dirstvz
fi
SUPPORTED_ACTIONS_BOARD=

# Supported actions when RSU is required.
# We only support [e] RMA unlock to do RSU, and [u] Update Cr50 in case a device
# has an older Cr50 version that doesn't support RSU.
SUPPORTED_ACTIONS_RSU_REQUIRED=eu

# Define our own logging function.
log() {
  echo "$*"
}

# Change color by ANSI escape sequence code
colorize() {
  set +x
  local code="$1"
  case "${code}" in
    "red" )
      code="1;31"
      ;;
    "green" )
      code="1;32"
      ;;
    "yellow" )
      code="1;33"
      ;;
    "white" )
      code="0;37"
      ;;
    "boldwhite" )
      code="1;37"
      ;;
  esac
  printf "\033[%sm" "${code}"
  set -x
}

# Checks if 'cros_debug' is enabled.
is_allow_debug() {
  grep -qw "cros_debug" /proc/cmdline
}

# Checks if complete prompt is disabled.
is_complete_prompt_disabled() {
  grep -qw "nocompleteprompt" /proc/cmdline
}

# Checks if the system has been boot by Ctrl-U.
is_dev_firmware() {
  crossystem "mainfw_type?developer" 2>/dev/null
}

is_netboot() {
  grep -qw cros_netboot /proc/cmdline
}

explain_cros_debug() {
  log "To debug with a shell, boot factory shim in developer firmware (Ctrl-U)
   or add 'cros_debug' to your kernel command line:
    - Factory shim: Add cros_debug into --boot_args or make_dev_ssd
    - Netboot: Change kernel command line config file on TFTP."
}

# Error message for any unexpected error.
on_die() {
  set +x
  kill_bg_jobs
  colorize red
  echo
  log "ERROR: Factory installation has been stopped."
  if [ -n "${LOG_TTY}" ]; then
    local tty_num="${LOG_TTY##*[^0-9]}"
    log "See ${LOG_TTY} (Ctrl-Alt-F${tty_num}) for detailed information."
    log "(The F${tty_num} key is ${tty_num} keys to the right of 'esc' key.)"
  else
    log "See ${LOG_FILE} for detailed information."
  fi

  # Open a terminal if the kernel command line allows debugging.
  if is_allow_debug; then
    while true; do sh; done
  else
    explain_cros_debug
  fi

  colorize white
  read -N 1 -p "Press any key to reboot... "
  reboot

  exit 1
}

kill_bg_jobs() {
  local pids=$(jobs -p)
  # Disown all background jobs to avoid terminated messages
  disown -a
  # Kill the jobs
  echo "${pids}" | xargs -r kill -9 2>/dev/null || true
}

exit_success() {
  trap - EXIT
  kill_bg_jobs
  exit 0
}

trap on_die EXIT

die() {
  set +x
  colorize red
  set +x
  log "ERROR: $*"
  kill_bg_jobs
  exit 1
}

is_rsu_required() {
  log "Waiting for UserDataAuth service"
  gdbus wait --system org.chromium.UserDataAuth

  log "Checking if RSU is required."
  local flags
  local FWMP_DEV_DISABLE_CCD_UNLOCK="0x40"

  flags="$(cryptohome --action=get_firmware_management_parameters |
           grep -o "flags=0x[0-9a-f]\+" | cut -d = -f 2)"

  # FWMP_DEV_DISABLE_CCD_UNLOCK (0x40) is set during enterprise enrollment if
  # dev mode is blocked by the policy. We can use this flag to determine whether
  # RSU required.
  #
  # According to platform/cr50/board/cr50/factory_mode.c, Cr50 allows factory
  # mode when the following conditions are met:
  #   - HWWP signal is deasserted (battery disconnected, or pins shorted)
  #   - FWMP allows CCD unlock. FWMP_DEV_DISABLE_CCD_UNLOCK (0x40) is not set
  #   - CCD password is not set
  #
  # Assuming that CCD password is not set, if FWMP_DEV_DISABLE_CCD_UNLOCK is not
  # set, RSU is not required and we can enter factory mode by disconnecting the
  # battery or shorting pins.
  if [ -z "${flags}" ] ||
     [ $(( flags & FWMP_DEV_DISABLE_CCD_UNLOCK )) -eq 0 ]; then
    return 1
  fi
  return 0
}

# Checks if hardware write protection is enabled.
check_hwwp() {
  crossystem 'wpsw_cur?1' 2>/dev/null
}

# Checks if firmware software write protection is enabled.
# Args
#   target: a "flashrom -p" descriptor. Defaults to "host".
check_fw_swwp() {
  local target="${1:-host}"
  if [ "${target}" = "ec" ] && [ "${EC_PRESENT}" -eq 0 ]; then
    echo "There is no EC, skip checking EC SWWP"
    return 0
  fi
  flashrom -p "${target}" --wp-status 2>/dev/null |
    grep -q "write protect is enabled"
}

clear_fwwp() {
  log "Firmware Write Protect disabled, clearing status registers."
  if [ "${EC_PRESENT}" -eq 1 ]; then
    flashrom -p ec --wp-disable
  fi
  flashrom -p host --wp-disable --wp-range 0,0
  log "WP registers should be cleared now"
}

ensure_fwwp_consistency() {
  local ec_wp main_wp

  if [ "${EC_PRESENT}" -eq 0 ]; then
    return
  fi

  ec_wp="$(flashrom -p ec --wp-status 2>/dev/null)" || return
  main_wp="$(flashrom -p host --wp-status 2>/dev/null)"
  ec_wp="$(echo "${ec_wp}" | sed -nr 's/WP.*(disabled|enabled).$/\1/pg')"
  main_wp="$(echo "${main_wp}" | sed -nr 's/WP.*(disabled|enabled).$/\1/pg')"
  if [ "${ec_wp}" != "${main_wp}" ]; then
    die "Inconsistent firmware write protection status: " \
        "main=${main_wp}, ec=${ec_wp}." \
        "Please disable Hardware Write Protection and restart again."
  fi
}

is_pvt_phase() {
  # If there is any error then pvt phase is returned as a safer default
  # option.
  local bid_flags="0x$(tpm_get_board_id_flags)"

  # If board phase is not 0x0 then this is a development board.
  local pre_pvt=$(( bid_flags & 0x7F ))
  if (( pre_pvt > 0 )); then
    return ${pre_pvt}
  fi

  return 0
}

config_tty() {
  stty opost

  # Turn off VESA blanking
  setterm -blank 0 -powersave off -powerdown 0
}

echo_huge_ok() {
  cat <<HERE

               ######                     ######         ######
         ##################               ######        ######
        ####################              ######       ######
      #########      #########            ######      ######
    ########            ########          ######     ######
   #######                #######         ######    ######
   ######                  ######         ######   ######
   ######                  ######         ######  ######
   ######                  ######         ###### ######
   ######                  ######         ############
   ######                  ######         ############
   ######                  ######         ############
   ######                  ######         ###### ######
   ######                  ######         ######  ######
   ######                  ######         ######   ######
   #######                #######         ######    ######
    ########            ########          ######     ######
      #########      #########            ######      ######
        ####################              ######       ######
         ##################               ######        ######
               ######                     ######         ######

HERE
}

set_time() {
  log "Setting time from:"
  # Extract only the server and port.
  local time_server_port="${OMAHA#http://}"

  log " Server ${time_server_port}."
  local result="$(htpdate -s -t "${time_server_port}" 2>&1)"
  if ! echo "${result}" | grep -Eq "(failed|unavailable)"; then
    log "Success, time set to $(date)"
    hwclock -w 2>/dev/null
    return 0
  fi

  log "Failed to set time: $(echo "${result}" | grep -E "(failed|unavailable)")"
  return 1
}

check_ethernet_status() {
  local link i
  local result=1
  link=$(ip -f link addr | sed 'N;s/\n/ /' | grep -w 'ether' |
    cut -d ' ' -f 2 | sed 's/://')
  for i in ${link}; do
    if ip -f inet addr show "${i}" | grep -q inet; then
      if ! iw "${i}" info >/dev/null 2>&1; then
        log "$(ip -f inet addr show "${i}" | grep inet)"
        ETH_INTERFACE=${i}
        result=0
      fi
    fi
  done
  return ${result}
}

clear_block_devmode() {
  # Try our best to clear block_devmode.
  crossystem block_devmode=0 || true
  vpd -i RW_VPD -d block_devmode -d check_enrollment || true
}

reset_chromeos_device() {
  if [[ -e /dev/nvram ]]; then
    log "Clearing NVData."
    dd if=/dev/zero of=/dev/nvram bs=1 count="$(wc -c </dev/nvram)" \
      status=none conv=nocreat || log "Failed to clear NVData (non-critical)."
  fi

  clear_block_devmode

  if is_netboot; then
    log "Device is network booted."
    return
  fi

  if crossystem "mainfw_type?nonchrome"; then
    # Non-ChromeOS firmware devices can stop now.
    log "Device running Non-ChromeOS firmware."
    return
  fi

  log "Request to clear TPM owner at next boot."
  # No matter if whole TPM (see below) is cleared or not, we always
  # want to clear TPM ownership (safe and easy) so factory test program and
  # release image won't start with unknown ownership.
  crossystem clear_tpm_owner_request=1 || true

  log "Checking if TPM should be recovered (for version and owner)"
  # To clear TPM, we need it unlocked (only in recovery boot).
  # Booting with USB in developer mode (Ctrl-U) does not work.

  if crossystem "mainfw_type?recovery"; then
    if ! chromeos-tpm-recovery; then
      colorize yellow
      log " - TPM recovery failed.

      This is usually not a problem for devices on manufacturing line,
      but if you are using factory shim to reset TPM (for antirollback issue),
      there's something wrong.
      "
      sleep 3
    else
      log "TPM recovered."
    fi
  else
    mainfw_type="$(crossystem mainfw_type)"
    colorize yellow
    log " - System was not booted in recovery mode (current: ${mainfw_type}).

    WARNING: TPM won't be cleared. To enforce clearing TPM, make sure you are
    using correct image signed with same key (MP, Pre-MP, or DEV), turn on
    developer switch if you haven't, then hold recovery button and reboot the
    system again.  Ctrl-U won't clear TPM.
    "
    # Alert for a while
    sleep 3
  fi
}

get_dst_drive() {
  load_base_vars
  DST_DRIVE="$(get_fixed_dst_drive)"
  if [ -z "${DST_DRIVE}" ]; then
    die "Cannot find fixed drive."
  fi
}

lightup_screen() {
  # Always backlight on factory install shim.
  ectool forcelidopen 1 || true
  # Light up screen in case you can't see our splash image.
  backlight_tool --set_brightness_percent=100 || true
}

load_modules() {
  # Required kernel modules might not be loaded. Load them now.
  modprobe i2c-dev || true
}

prepare_disk() {
  log "Factory Install: Setting partition table"

  local pmbr_code="/root/.pmbr_code"
  [ -r ${pmbr_code} ] || die "Missing ${pmbr_code}; please rebuild image."

  write_base_table "${DST_DRIVE}" "${pmbr_code}" 2>&1
  reload_partitions "${DST_DRIVE}"

  log "Done preparing disk"
}

ufs_init() {
  local ufs_init_file="/usr/sbin/factory_ufs_init.sh"
  if [ -x "${ufs_init_file}" ]; then
    ${ufs_init_file}
  fi
}

find_var() {
  # Check kernel commandline for a specific key value pair.
  # Usage: omaha=$(find_var omahaserver)
  # Assume values are space separated, keys are unique within the commandline,
  # and that keys and values do not contain spaces.
  local key="$1"

  # shellcheck disable=SC2013
  for item in $(cat /proc/cmdline); do
    if echo "${item}" | grep -q "${key}"; then
      echo "${item}" | cut -d'=' -f2
      return 0
    fi
  done
  return 1
}

override_from_firmware() {
  # Check for Omaha URL or Board type from kernel commandline.
  local omaha=""
  if omaha="$(find_var omahaserver)"; then
    OMAHA="$(normalize_server_url "${omaha}")"
    log " Kernel cmdline OMAHA override to ${OMAHA}"
  fi

  local board=""
  if board="$(find_var cros_board)"; then
    log " Kernel cmdline BOARD override to ${board}"
    BOARD="${board}"
  fi
}

override_from_board() {
  # Call into any board specific configuration settings we may need.
  # The file should be installed in factory-board/files/installer/usr/sbin/.
  local lastboard="${BOARD}"
  local board_customize_file="/usr/sbin/factory_install_board.sh"
  if [ -f "${board_customize_file}" ]; then
    . "${board_customize_file}"
  fi

  # Let's notice if BOARD has changed and print a message.
  if [ "${lastboard}" != "${BOARD}" ]; then
    colorize red
    log " Private overlay customization BOARD override to ${BOARD}"
    sleep 1
  fi
}

override_from_tftp() {
  # Check for Omaha URL from tftp server.
  local tftp=""
  local omahaserver_config="omahaserver.conf"
  local tftp_output=""
  # Use board specific config if ${BOARD} is not null.
  [ -z "${BOARD}" ] || omahaserver_config="omahaserver_${BOARD}.conf"
  tftp_output="/tmp/${omahaserver_config}"

  if tftp="$(find_var tftpserverip)"; then
    log "override_from_tftp: kernel cmdline tftpserverip ${tftp}"
    # Get omahaserver_config from tftp server.
    # Use busybox tftp command with options: "-g: Get file",
    # "-r FILE: Remote FILE" and "-l FILE: local FILE".
    rm -rf "${tftp_output}"
    tftp -g -r "${omahaserver_config}" -l "${tftp_output}" "${tftp}" || true
    if [ -f "${tftp_output}" ]; then
      OMAHA="$(normalize_server_url "$(cat "${tftp_output}")")"
      log "override_from_tftp: OMAHA override to ${OMAHA}"
    fi
  fi
}

overrides() {
  override_from_firmware
  override_from_board
}

disable_release_partition() {
  # Release image is not allowed to boot unless the factory test is passed
  # otherwise the wipe and final verification can be skipped.
  if ! cgpt add -i "${DST_RELEASE_KERNEL_PART}" -P 0 -T 0 -S 0 "${DST_DRIVE}"
  then
    # Destroy kernels otherwise the system is still bootable.
    dst="$(make_partition_dev "${DST_DRIVE}" "${DST_RELEASE_KERNEL_PART}")"
    dd if=/dev/zero of="${dst}" bs=1M count=1
    dst="$(make_partition_dev "${DST_DRIVE}" "${DST_FACTORY_KERNEL_PART}")"
    dd if=/dev/zero of="${dst}" bs=1M count=1
    die "Failed to lock release image. Destroy all kernels."
  fi
  # cgpt changed partition table, so we have to make sure it's notified.
  reload_partitions "${DST_DRIVE}"
}

run_postinst() {
  local install_dev="$1"
  local mount_point="$(mktemp -d)"
  local result=0

  mount -t ext2 -o ro "${install_dev}" "${mount_point}"
  IS_FACTORY_INSTALL=1 "${mount_point}"/postinst \
    "${install_dev}" 2>&1 || result="$?"

  umount "${install_dev}" || true
  rmdir "${mount_point}" || true
  return ${result}
}

stateful_postinst() {
  local stateful_dev="$1"
  local mount_point="$(mktemp -d)"

  mount "${stateful_dev}" "${mount_point}"
  mkdir -p "$(dirname "${output_file}")"

  # Update lsb-factory on stateful partition.
  local lsb_factory="${mount_point}/dev_image/etc/lsb-factory"
  if [ -z "${FACTORY_INSTALL_FROM_USB}" ]; then
    log "Save active factory server URL to stateful partition lsb-factory."
    echo "FACTORY_OMAHA_URL=${OMAHA}" >>"${lsb_factory}"
  else
    log "Clone lsb-factory to stateful partition."
    cat "${LSB_FACTORY_FILE}" >>"${lsb_factory}"
  fi

  umount "${mount_point}" || true
  rmdir "${mount_point}" || true
}

omaha_greetings() {
  if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
    return
  fi

  local message="$1"
  local uuid="$2"
  curl "${OMAHA}/greetings/${message}/${uuid}" >/dev/null 2>&1 || true
}

factory_on_complete() {
  if [ ! -s "${COMPLETE_SCRIPT}" ]; then
    return 0
  fi

  log "Executing completion script... (${COMPLETE_SCRIPT})"
  if ! sh "${COMPLETE_SCRIPT}" "${DST_DRIVE}" 2>&1; then
    die "Failed running completion script ${COMPLETE_SCRIPT}."
  fi
  log "Completion script executed successfully."
}

factory_reset() {
  crossystem disable_dev_request=1

  log "Performing factory reset"
  if ! /usr/sbin/factory_reset.sh "${DST_DRIVE}"; then
    die "Factory reset failed."
  fi

  log "Done."
  # TODO(hungte) shutdown or reboot once we decide the default behavior.
  exit_success
}

# Call reset code on the fixed driver.
#
# Assume the global variable DST_DRIVE contains the drive to operate on.
#
# Args:
#   action: describe how to erase the drive.
#     Allowed actions:
#     - wipe: action Z
#     - secure: action C
#     - verify: action Y
factory_disk_action() {
  local action="$1"
  log "Performing factory disk ${action}"
  if ! /usr/sbin/factory_reset.sh "${DST_DRIVE}" "${action}"; then
    die "Factory disk ${action} failed."
  fi
  log "Done."
  exit_success
}

enlarge_partition() {
  local dev="$1"
  local block_size="$(dumpe2fs -h "${dev}" | sed -n 's/Block size: *//p')"
  local minimal="$(resize2fs -P "${dev}" | sed -n 's/Estimated .*: //p')"

  # Try to allocate 1G if possible.
  if [ "${minimal}" -gt 0 ] && [ "${block_size}" -gt 0 ]; then
    e2fsck -f -y "${dev}"
    resize2fs "${dev}" "$((minimal + (1024 * 1048576 / block_size)))" || true
  fi
}

reload_partitions() {
  # Some devices, for example NVMe, may need extra time to update block device
  # files via udev. We should do sync, partprobe, and then wait until partition
  # device files appear again.
  local drive="$1"
  log "Reloading partition table changes..."
  sync

  # Reference: src/platform2/installer/chromeos-install#reload_partitions
  udevadm settle || true  # Netboot environment may not have udev.
  for delay in 0 1 2 4 8; do
    sleep "${delay}"
    blockdev --rereadpt "${drive}" && return ||
      log "Failed to reload partitions on ${drive}"
  done
  die "Continually failed to reload partitions on ${drive}"
}

cros_payload_get_server_json_path() {
  local server_url="$1"
  local eth_interface="$2"

  # Try to get resource map from Umpire.
  local sn="$(vpd -i RO_VPD -g serial_number)" || sn=""
  local mlb_sn="$(vpd -i RO_VPD -g mlb_serial_number)" || mlb_sn=""
  local mac_addr="$(ip link show ${eth_interface} | grep link/ether |
    tr -s ' '| cut -d ' ' -f 3)"
  local resourcemap=""
  local mac="mac.${eth_interface}=${mac_addr};"
  local values="sn=${sn}; mlb_sn=${mlb_sn}; board=${BOARD}; ${mac}"
  local empty_values="firmware=; ec=; stage=;"
  local header="X-Umpire-DUT: ${values} ${empty_values}"
  local target="${server_url}/resourcemap"
  # This is following Factory Server/Umpire protocol.
  echo "Header: ${header}" >&2

  resourcemap="$(curl -f --header "${header}" "${target}")"
  if [ -z "${resourcemap}" ]; then
    echo "Missing /resourcemap - please upgrade Factory Server." >&2
    return 1
  fi
  echo "resourcemap: ${resourcemap}" >&2
  # Check if multicast config exists
  local json_name="$(echo "${resourcemap}" | grep "^multicast: " |
    cut -d ' ' -f 2)"
  if [ -z "${json_name}" ]; then
    # Multicast config not found. Fallback to normal payload config.
    json_name="$(echo "${resourcemap}" | grep "^payloads: " | cut -d ' ' -f 2)"
  fi
  if [ -n "${json_name}" ]; then
    echo "res/${json_name}"
  else
    echo "'payloads' not in resourcemap, please upgrade Factory Server." >&2
    return 1
  fi
}

factory_install_cros_payload() {
  local src_media="$1"
  local json_path="$2"
  local rma_install="$3"
  local src_mount=""
  local tmp_dir="$(mktemp -d)"
  local json_url="${src_media}/${json_path}"

  if [ -b "${src_media}" ]; then
    src_mount="$(mktemp -d)"
    colorize yellow
    mount -o ro "${src_media}" "${src_mount}"
    json_url="${src_mount}/${json_path}"
  fi

  # Generate the uuid for current install session
  local uuid="$(uuidgen 2>/dev/null)" || uuid="Not_Applicable"

  # Say hello to server if available.
  omaha_greetings "hello" "${uuid}"

  if [ "${rma_install}" = "test" ]; then
    cros_payload install "${json_url}" "${DST_DRIVE}" test_image_only
  elif [ "${rma_install}" = "release" ]; then
    cros_payload install "${json_url}" "${DST_DRIVE}" release_image_only
  else
    cros_payload install "${json_url}" "${DST_DRIVE}" test_image release_image

    cros_payload install "${json_url}" "${DST_DRIVE}" release_image.part12

    # Test image stateful partition may pretty full and we may want more space,
    # before installing toolkit (which may be huge).
    enlarge_partition "$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")"

    cros_payload install "${json_url}" "${DST_DRIVE}" toolkit

    # Install optional components.
    cros_payload install_optional "${json_url}" "${DST_DRIVE}" \
      release_image.crx_cache hwid toolkit_config project_config
    cros_payload install_optional "${json_url}" "${tmp_dir}" firmware complete
  fi

  if [ -n "${src_mount}" ]; then
    umount "${src_mount}"
  fi
  colorize green

  # Notify server that all downloads are completed.
  omaha_greetings "download_complete" "${uuid}"

  if [ -z "${rma_install}" ]; then
    # Disable release partition and activate factory partition
    disable_release_partition
  fi
  run_postinst "$(make_partition_dev "${DST_DRIVE}" "${DST_FACTORY_PART}")" ||
    die "Failed running postinst script."
  stateful_postinst "$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")"

  if [ -s "${tmp_dir}/firmware" ]; then
    log "Found firmware updater."
    # TODO(hungte) Check if we need to run --mode=recovery if WP is enabled.
    sh "${tmp_dir}/firmware" --force --mode=factory_install ||
      die "Firmware updating failed."
  fi
  if [ -s "${tmp_dir}/complete" ]; then
    log "Found completion script."
    COMPLETE_SCRIPT="${tmp_dir}/complete"
  fi

  # After post processing, notify server a installation session has been
  # successfully completed.
  omaha_greetings "goodbye" "${uuid}"
}

factory_install_usb() {
  local rma_install="$1"
  local src_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${src_dev}" ] || src_dev="$(rootdev -s 2>/dev/null)"
  [ -n "${src_dev}" ] ||
    die "Unknown media source. Please define REAL_USB_DEV."

  # Switch to stateful partition.
  # shellcheck disable=SC2001
  local stateful_dev="$(echo "${src_dev}" | sed 's/[0-9]\+$/1/')"

  local mount_point="$(mktemp -d)"
  mount -o ro "${stateful_dev}" "${mount_point}"
  local json_path="$(cros_payload_metadata "${mount_point}")"
  umount "${stateful_dev}"
  rmdir "${mount_point}"

  if [ -n "${json_path}" ]; then
    factory_install_cros_payload "${stateful_dev}" "${json_path}" "${rma_install}"
  else
    die "Cannot find cros_payload metadata."
  fi
}

factory_install_network() {
  # Register to Overlord if haven't.
  if [ -z "${OVERLORD_READY}" ]; then
    register_to_overlord "${OMAHA}" "${TTY_FILE}" "${LOG_FILE}"
  fi

  # Get path of cros_payload json file from server (Umpire or Mini-Omaha).
  local json_path="$(cros_payload_get_server_json_path \
    "${OMAHA}" "${ETH_INTERFACE}" 2>/dev/null)"
  [ -n "${json_path}" ] || die "Failed to get payload json path from server."
  factory_install_cros_payload "${OMAHA}" "${json_path}"
}

gbb_force_dev_mode() {
  # Set factory-friendly gbb flags 0x39, which contains
  # VB2_GBB_FLAG_DEV_SCREEN_SHORT_DELAY            0x00000001
  # VB2_GBB_FLAG_FORCE_DEV_SWITCH_ON               0x00000008
  # VB2_GBB_FLAG_FORCE_DEV_BOOT_USB                0x00000010
  # VB2_GBB_FLAG_DISABLE_FW_ROLLBACK_CHECK         0x00000020
  flashrom -p host --wp-disable --wp-range 0,0 > /dev/null 2>&1
  local tmp_file cur_flags new_flags
  tmp_file="$(mktemp)"
  flashrom -p host -i GBB -r "${tmp_file}"
  cur_flags="$(futility gbb -g --flags "${tmp_file}")" # flags: %#x
  new_flags=$(( "${cur_flags#flags: }" | 0x39))
  futility gbb -s --flags "${new_flags}" "${tmp_file}"
  flashrom -p host -i GBB -w "${tmp_file}"
  rm "${tmp_file}"
}

# Refer: platform2/installer/chromeos-install#legacy_offset_size_export
legacy_offset_size_export() {
  # Exports all the variables that install_gpt did previously.
  # This should disappear eventually, but it's here to make existing
  # code work for now.
  START_STATEFUL="$(partoffset "$1" "${DST_STATE_PART}")"
  START_ROOTFS_A="$(partoffset "$1" "${DST_FACTORY_PART}")"
  NUM_STATEFUL_SECTORS="$(partsize "$1" "${DST_STATE_PART}")"
}

# Refer: platform2/installer/chromeos-install#wipe_stateful
# Wipes the stateful partition.
# NOTE(changwan.hong): We don't need to consider loop device.
wipe_stateful() {
  echo "Clearing the stateful partition..."
  STATEFUL_FORMAT="$(get_format "${DST_STATE_PART}")"
  DST_BLKSIZE="$(blocksize "${DST_DRIVE}")"

  local stateful_fs_format
  stateful_fs_format="$(get_fs_format "${DST_STATE_PART}")"
  # state options are stored in $@.
  set --

  case "${STATEFUL_FORMAT}" in
  ubi)
    local phy_ubi="/dev/ubi${DST_STATE_PART}"
    local log_ubi="${phy_ubi}_0"
    local sysfs_name="/sys/class/mtd/mtd${DST_STATE_PART}/name"

    init_ubi_volume "${DST_STATE_PART}" "$(cat "${sysfs_name}")"
    ;;
  *)
    if [ -b "${DST_DRIVE}" ]; then
      DEV=$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")
    else
      die "Install destination should be block device."
    fi
    ;;
  esac

  # Check if the kernel we are going to install support ext4 crypto.
  if ext4_dir_encryption_supported; then
    set -- "$@" -O encrypt
  fi

  # Check if the kernel we are going to install support ext4 fs-verity.
  if ext4_fsverity_supported; then
    set -- "$@" -O verity
  fi

  local num_4k_sectors
  if [ "${DST_BLKSIZE}" -gt 4096 ]; then
    num_4k_sectors=$(( NUM_STATEFUL_SECTORS * (DST_BLKSIZE / 4096) ))
  else
    num_4k_sectors=$(( NUM_STATEFUL_SECTORS / (4096 / DST_BLKSIZE) ))
  fi

  # We always make any ext* stateful partitions ext4.
  case "${stateful_fs_format}" in
  ext[234])
    mkfs.ext4 -F -b 4096 -L "H-STATE" "$@" "${DEV}" \
      ${num_4k_sectors}
    ;;
  ubifs)
    mkfs.ubifs -y -x none -R 0 "/dev/ubi${DST_STATE_PART}_0"
    ;;
  esac

  case ${STATEFUL_FORMAT} in
  ubi) ;;
  *)
    sync
    ;;
  esac
}

# Refer: platform2/installer/chromeos-install#_get_field
# Get the specified env var for the specified partition.
#  $1 the field name such as "PARTITION_SIZE", "FS_FORMAT"
#  $2 the partition such as "1", or "ROOT_A"
_get_field() {
  local field part
  field="$1"
  part="$2"
  eval echo \""\${${field}_${part}}"\"
}

# Refer: platform2/installer/chromeos-install#get_format
get_format() {
  _get_field FORMAT "$@"
}

# Refer: platform2/installer/chromeos-install#_get_fs_format
get_fs_format() {
  _get_field FS_FORMAT "$@"
}

# Refer: platform2/installer/chromeos-install#calculate_max_beb_per_1024
# Calculate the maximum number of bad blocks per 1024 blocks for UBI.
#  $1 partition number
calculate_max_beb_per_1024() {
  local part_no mtd_size eb_size nr_blocks
  part_no="$1"
  # The max beb per 1024 is on the total device size, not the partition size.
  mtd_size=$(cat /sys/class/mtd/mtd0/size)
  eb_size=$(cat /sys/class/mtd/mtd0/erasesize)
  nr_blocks=$((mtd_size / eb_size))
  reserved_ebs=$(get_reserved_ebs "${part_no}")
  echo $((reserved_ebs * 1024 / nr_blocks))
}

# Refer: platform2/installer/chromeos-install#init_ubi_volume
# Format and make UBI volume if it's not already there.
#  $1 partition number such as "1", "2"
#  $2 volume name
init_ubi_volume() {
  local part_no volume_name phy_ubi log_ubi
  part_no="$1"
  volume_name="$2"
  phy_ubi="/dev/ubi${part_no}"
  log_ubi="${phy_ubi}_0"
  if [ ! -e "${phy_ubi}" ]; then
    ubiformat -y -e 0 "/dev/mtd${part_no}"
    ubiattach -d "${part_no}" -m "${part_no}" \
              --max-beb-per1024 "$(calculate_max_beb_per_1024 "${part_no}")"
  fi
  if [ ! -e "${log_ubi}" ]; then
    local volume_size
    volume_size=$(get_partition_size "${part_no}")
    ubimkvol -s "${volume_size}" -N "${volume_name}" "${phy_ubi}"
  fi
}

rma_install_image() {
  local rma_install="$1"
  reset_chromeos_device

  log "Checking for Firmware Write Protect"
  # Check for physical firmware write protect. We'll only
  # clear this stuff if the case is open.
  if ! check_hwwp; then
    # Clear software firmware write protect.
    clear_fwwp
  fi
  ensure_fwwp_consistency

  colorize green
  # TODO(changwan.hong): Should revisit here.
  #ufs_init
  get_dst_drive
  prepare_disk

  legacy_offset_size_export "${DST_DRIVE}"
  wipe_stateful

  factory_install_usb "${rma_install}"

  resize2fs -pf "$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")"

  sync
  # Some installation procedure may clear or reset NVdata, so we want to ensure
  # TPM will be cleared again.
  crossystem clear_tpm_owner_request=1 || true

  colorize green
  echo_huge_ok
  log "RMA shim finished installing ${rma_install} image"
  sync

  factory_on_complete
  printf "Press Enter to restart... "
  head -c 1 >/dev/null

  # Default action after installation: reboot.
  trap - EXIT

  # Cr50 factory mode can only be enabled when hardware write protection is
  # disabled. Assume we only do netboot in factory, so that in netboot
  # environment we don't need to enable factory mode because the device should
  # already be in factory mode.
  # TODO(chenghan) Figure out the use case of netboot besides factory process.
  # TODO(changwan.hong): Should revisit here.
  # if [ -z "${NETBOOT_RAMFS}" ] && ! is_cr50_factory_mode_enabled \
  #                              && ! check_hwwp; then
  #   # Enabling cr50 factory mode would trigger a reboot automatically and be
  #   # halt inside this function until reboots.
  #   enable_cr50_factory_mode
  # fi

  # Try to do EC reboot. If it fails, do normal reboot.
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # There is no 'shutdown' and 'init' in initramfs.
    ectool reboot_ec cold at-shutdown && busybox poweroff -f ||
      busybox reboot -f
  else
    ectool reboot_ec cold at-shutdown && shutdown -h now || shutdown -r now
  fi

  # sleep indefinitely to avoid re-spawning rather than shutting down
  sleep 1d
}

test_ec_flash_presence() {
  # If "flashrom -p ec --flash-size" command succeeds (returns 0),
  # then EC flash chip is present in system. Otherwise, assume EC flash is not
  # present or supported.
  if flashrom -p ec --flash-size >/dev/null 2>&1; then
    EC_PRESENT=1
  else
    EC_PRESENT=0
  fi
}

# Echoes "on" or "off" based on the value of a crossystem Boolean flag.
crossystem_on_or_off() {
  local value
  if value="$(crossystem "$1" 2>/dev/null)"; then
    case "${value}" in
    "0")
      echo off
      ;;
    "1")
      echo on
      ;;
    *)
      echo "${value}"
      ;;
    esac
  else
    echo "(unknown)"
  fi
}

# Echoes "yes" or "no" based on a Boolean argument (0 or 1).
bool_to_yes_or_no() {
  [ "$1" = 1 ] && echo yes || echo no
}

command_to_yes_or_no() {
  "$@" >/dev/null 2>&1 && echo yes || echo no
}

# Prints a header (a title, plus all the info in print_device_info)
print_header() {
    colorize boldwhite
    echo CrOS Factory Shim
    colorize white
    echo -----------------
    print_device_info
}

# Prints various information about the device.
print_device_info() {
    echo "Factory shim version: $(findLSBValue CHROMEOS_RELEASE_DESCRIPTION)"
    local bios_version="$(crossystem ro_fwid 2>/dev/null)"
    echo "BIOS version: ${bios_version:-(unknown)}"
    for type in RO RW; do
      echo -n "EC ${type} version: "
      ectool version | grep "^${type} version" | sed -e 's/[^:]*: *//'
    done
    echo
    echo System time: "$(date)"
    local hwid="$(crossystem hwid 2>/dev/null)"
    echo "HWID: ${hwid:-(not set)}"
    echo -n "Dev mode: $(crossystem_on_or_off devsw_boot); "
    echo -n "Recovery mode: $(crossystem_on_or_off recoverysw_boot); "
    echo -n "HW write protect: $(crossystem_on_or_off wpsw_cur); "
    echo "SW write protect: $(command_to_yes_or_no check_fw_swwp host)"
    echo -n "EC present: $(bool_to_yes_or_no "${EC_PRESENT}"); "
    if [ "${EC_PRESENT}" -eq 1 ]; then
      echo -n "EC SW write protect: $(command_to_yes_or_no check_fw_swwp ec); "
    fi
    echo -n "$(tpm_get_info)"
    echo
    local description=""
    if [ -s "${DESCRIPTION_FILE}" ]; then
      description="$(cat "${DESCRIPTION_FILE}" 2>/dev/null)"
      echo "${description}"
      echo
    fi
}

# Displays a line in the menu.  Used in the menu function.
#
# Args:
#   $1: Single-character option name ("I" for install)
#   $2: Brief description
#   $3: Further explanation
menu_line() {
  echo -n "  "
  colorize boldwhite
  echo -n "$1  "
  colorize white
  printf "%-22s%s\n" "$2" "$3"
}

# Checks if the given action is valid and supported.
is_valid_action() {
  echo "$1" | grep -q "^[${SUPPORTED_ACTIONS}${SUPPORTED_ACTIONS_BOARD}]$"
}

# Checks if the given action is valid and supported if RSU is required.
is_valid_action_when_rsu_required() {
  echo "$1" | grep -q "^[${SUPPORTED_ACTIONS_RSU_REQUIRED}]$"
}

# Virtual function to show menu of board-specific actions.
menu_board() {
  return 0
}

# Displays a menu, saving the action (one of ${SUPPORTED_ACTIONS} or
# ${SUPPORTED_ACTIONS_BOARD}, always lowercase) in the "ACTION" variable. If no
# valid action is chosen, ACTION will be empty.
menu() {
  # Clear up terminal
  stty sane echo
  # Enable cursor (if tput is available)
  tput cnorm 2>/dev/null || true

  echo
  echo
  echo Please select an action and press Enter.
  echo

  # RMA shim
  if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
    menu_line I "Install default" \
                "Performs default install (through cros factory test)"
    menu_line R "Install Release Image" \
                "Performs release(base) image install"
    menu_line T "Install Test Image" \
                "Performs test image install"
    menu_line S "Shell" "Opens bash; available only with developer firmware"
    menu_line V "View configuration" "Shows crossystem, VPD, etc."
    menu_line D "Debug info and logs" \
                "Shows useful debugging information and kernel/firmware logs"
    menu_line Z "Zero (wipe) storage" "Makes device completely unusable"
  # Factory install shim.
  # TODO(changwan.hong): Remove menu line which doesn't work.
  else
    menu_line I "Install" "Performs a network or USB install"
    menu_line R "Reset" "Performs a factory reset; finalized devices only"
    menu_line B "Battery cutoff" "Performs a battery cutoff"
    menu_line S "Shell" "Opens bash; available only with developer firmware"
    menu_line V "View configuration" "Shows crossystem, VPD, etc."
    menu_line D "Debug info and logs" \
                "Shows useful debugging information and kernel/firmware logs"
    menu_line Z "Zero (wipe) storage" "Makes device completely unusable"
    menu_line C "SeCure erase" \
                "Performs full storage erase, write a verification pattern"
    menu_line Y "VerifY erase" \
                "Verifies the storage has been erased with option C"
    menu_line T "Reset TPM" "Call chromeos-tpm-recovery"
    menu_line U "Update TPM firmware" "Update TPM firmware"
    menu_line E "Perform RSU" "Perform RSU (RMA Server Unlock)"
    menu_line M "Enable factory mode" "Enable TPM factory mode"
  fi

  menu_board

  echo
  read -p 'action> ' ACTION
  echo
  # busybox tr may not have '[:upper:]'.
  # shellcheck disable=SC2019 disable=SC2018
  ACTION="$(echo "${ACTION}" | tr 'A-Z' 'a-z')"

  if is_valid_action "${ACTION}"; then
    return
  fi
  echo "Invalid action; please select an action from the menu."
  ACTION=
}

#
# Action handlers
#

# I = Install.
action_i() {
  reset_chromeos_device

  log "Checking for Firmware Write Protect"
  # Check for physical firmware write protect. We'll only
  # clear this stuff if the case is open.
  if ! check_hwwp; then
    # Clear software firmware write protect.
    clear_fwwp
  fi
  ensure_fwwp_consistency

  if [ -z "${FACTORY_INSTALL_FROM_USB}" ]; then

    colorize yellow
    log "Waiting for ethernet connectivity to install"

    while true; do
      if [ -n "${NETBOOT_RAMFS}" ]; then
        # For initramfs network boot, there is no upstart job. We have to
        # bring up network interface and get IP address from DHCP on our own.
        # The network interface may not be ready, so let's ignore any
        # error here.
        bringup_network || true
      fi
      if check_ethernet_status; then
        break
      else
        sleep 1
      fi
    done

    # Check for factory server override from tftp server.
    override_from_tftp

    # TODO(hungte) how to set time in RMA?
    set_time || die "Please check if the server is configured correctly."
  fi

  colorize green
  # TODO(changwan.hong): Should revisit here.
  #ufs_init
  get_dst_drive
  prepare_disk

  if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
    factory_install_usb
  else
    factory_install_network
  fi

  sync
  # Some installation procedure may clear or reset NVdata, so we want to ensure
  # TPM will be cleared again.
  crossystem clear_tpm_owner_request=1 || true

  # The gbb flag which forces the dev switch on (0x8) is set when
  # (1) installing the firmware-updater and (2) doing RSU using cr50-reset.sh.
  # However, if the factory bundle does not contain firmware-updater and at the
  # same time the hwwp is disabled via removing battery + action_m, then the
  # gbb flag will not be set. Therefore, after installation, the DUT will try
  # to boot into test image under normal mode. This results in 0x43 (see
  # b/199803466 for more info.) Though user can enable developer mode and boot
  # into test image, we decide to make it more user-friendly by setting the
  # gbb flag here.
  # NOTE(changwan.hong): gbb_force_dev_mode is introduced at M96 but we don't
  # need it.
  #log "Setting user-friendly gbb flags 0x39..."
  #gbb_force_dev_mode

  colorize green
  echo_huge_ok
  log "Factory Installer Complete."
  sync

  factory_on_complete
  # Both kernel command line and lsb-factory can disable complete prompt.
  if is_complete_prompt_disabled || [ "${COMPLETE_PROMPT}" = "false" ] \
                                 || [ "${TTY}" = /dev/null ]; then
    sleep 3
  else
    printf "Press Enter to restart... "
    head -c 1 >/dev/null
  fi

  # Default action after installation: reboot.
  trap - EXIT

  # TPM factory mode can only be enabled when hardware write protection is
  # disabled. Assume we only do netboot in factory, so that in netboot
  # environment we don't need to enable factory mode because the device should
  # already be in factory mode.
  # TODO(chenghan) Figure out the use case of netboot besides factory process.
  if [ -z "${NETBOOT_RAMFS}" ] && ! check_hwwp; then
    # Enable factory mode if it's supported.
    # Enabling factory mode would trigger a reboot automatically and be halt
    # inside this function until reboots.
    tpm_enable_factory_mode
  fi

  # Try to do EC reboot. If it fails, do normal reboot.
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # There is no 'shutdown' and 'init' in initramfs.
    ectool reboot_ec cold at-shutdown && busybox poweroff -f ||
      busybox reboot -f
  else
    ectool reboot_ec cold at-shutdown && shutdown -h now || shutdown -r now
  fi

  # sleep indefinitely to avoid re-spawning rather than shutting down
  sleep 1d
}

# R = Factory reset.
action_r() {
  # RMA shim installs release image
  if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
    rma_install_image "release"
    return
  fi

  if [ -n "${NETBOOT_RAMFS}" ]; then
    # factory_reset.sh script is not available in netboot mode.
    colorize red
    log "Not available in netboot."
    return
  fi

  # First check to make sure that the factory software has been wiped.
  MOUNT_POINT=/tmp/stateful
  mkdir -p /tmp/stateful
  get_dst_drive
  mount -o ro "$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")" \
    "${MOUNT_POINT}"

  local factory_exists=false
  [ -e ${MOUNT_POINT}/dev_image/factory ] && factory_exists=true
  umount "${MOUNT_POINT}"

  if ${factory_exists}; then
    colorize red
    log "Factory software is still installed (device has not been finalized)."
    log "Unable to perform factory reset."
    return
  fi

  check_fw_swwp host && check_fw_swwp ec || ! is_pvt_phase || \
    die "SW write protect is not enabled in the device with PVT phase."

  reset_chromeos_device
  factory_reset
}

# B = Battery cutoff.
action_b() {
  crossystem disable_dev_request=1
  /usr/share/cutoff/cutoff.sh
}

# S = Shell.
action_s() {
  if ! is_allow_debug && ! is_dev_firmware; then
    colorize red
    echo "Cannot open a shell (need devfw [Ctrl-U] or cros_debug build)."
    explain_cros_debug
    return
  fi

  log "Trying to bring up network..."
  if bringup_network 2>/dev/null; then
    colorize green
    log "Network enabled."
    colorize white
  else
    colorize yellow
    log "Unable to bring up network (or it's already up).  Proceeding anyway."
    colorize white
  fi

  echo Entering shell.
  bash || true
}

# V = View configuration.
action_v() {
  (
    print_device_info

    for partition in RO_VPD RW_VPD; do
      echo
      echo "${partition} contents:"
      vpd -i "${partition}" -l || true
    done

    echo
    echo "crossystem:"
    crossystem || true

    echo
    echo "lsb-factory:"
    cat /mnt/stateful_partition/dev_image/etc/lsb-factory || true
  ) 2>&1 | secure_less.sh
}

# D = Debug info and logs.
action_d() {
  /usr/sbin/factory_debug.sh
}

# Confirm and erase the fixed drive.
#
# Identify the fixed drive, ask confirmation and call
# factory_disk_action function.
#
# Args:
#   action: describe how to erase the drive.
erase_drive() {
  local action="$1"
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # factory_reset.sh script is not available in netboot mode.
    colorize red
    log "Not available in netboot."
    return
  fi

  colorize red
  get_dst_drive
  echo "!!"
  echo "!! You are about to wipe the entire internal disk."
  echo "!! After this, the device will not boot anymore, and you"
  echo "!! need a recovery USB disk to bring it back to life."
  echo "!!"
  echo "!! Type 'yes' to do this, or anything else to cancel."
  echo "!!"
  colorize white
  local yes_or_no
  read -p "Wipe the internal disk? (yes/no)> " yes_or_no
  if [ "${yes_or_no}" = yes ]; then
    factory_disk_action "${action}"
  else
    echo "You did not type 'yes'. Cancelled."
  fi
}

# Z = Zero
action_z() {
  erase_drive wipe
}

# C = SeCure
action_c() {
  erase_drive secure
}

# Y = VerifY
action_y() {
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # factory_reset.sh script is not available in netboot mode.
    colorize red
    log "Not available in netboot."
    return
  fi
  get_dst_drive
  factory_disk_action verify
}

# T = Reset TPM
action_t() {
  # RMA shim installs test image
  if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
    rma_install_image "test"
    return
  fi

  chromeos-tpm-recovery
}

# U = Update TPM firmware
action_u() {
  tpm_update_firmware
}

# E = Perform RSU
action_e() {
  tpm_perform_rsu
}

# M = Enable TPM factory mode
action_m() {
  tpm_enable_factory_mode
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "You must run this as root."
    exit 1
  fi
  config_tty || true  # Never abort if TTY has problems.

  log "Starting Factory Installer."
  # TODO: do we still need this call now that the kernel was tweaked to
  # provide a good light level by default?
  lightup_screen

  load_modules

  colorize white
  clear

  test_ec_flash_presence

  # Check for any configuration overrides.
  overrides

  # Read default options
  if [ "${NETBOOT_RAMFS}" = 1 ]; then
    log "Netbooting. Set default action to (I) Install."
    DEFAULT_ACTION=i
  elif [ "${RMA_AUTORUN}" = "true" ]; then
    case "$(tpm_check_rsu_support)" in
      unsupported)
        if check_hwwp; then
          log "Hardware write protection on. " \
              "RSU is not supported, please disable hardware write protect."
          DEFAULT_ACTION=""
        else
          log "Hardware write protection off. " \
              "Set default action to (I) Install."
          DEFAULT_ACTION=i
        fi
        ;;
      supported)
        if is_rsu_required; then
          log "RSU is required. " \
              "Set default action to (E) Perform RSU."
          DEFAULT_ACTION=e
        elif check_hwwp; then
          log "Hardware write protection on. " \
              "Set default action to (E) Perform RSU."
          DEFAULT_ACTION=e
        else
          log "Hardware write protection off. " \
              "Set default action to (I) Install."
          DEFAULT_ACTION=i
        fi
        ;;
      need_update)
          log "TPM version is old. Set default action to (U) Update TPM."
          DEFAULT_ACTION=u
        ;;
    esac
  fi

  # Sanity check default action
  if [ -n "${DEFAULT_ACTION}" ]; then
    log "Default action: [${DEFAULT_ACTION}]."
    if [ "$(tpm_check_rsu_support)" = "supported" ] && is_rsu_required &&
         ! is_valid_action_when_rsu_required "${DEFAULT_ACTION}"; then
      log "Action [${DEFAULT_ACTION}] is invalid when RSU is required."
      log "Only support ${SUPPORTED_ACTIONS_RSU_REQUIRED}."
      log "Will fallback to normal menu..."
      DEFAULT_ACTION=""
      sleep 3
    elif ! is_valid_action "${DEFAULT_ACTION}"; then
      log "Action [${DEFAULT_ACTION}] is invalid."
      log "Only support ${SUPPORTED_ACTIONS}${SUPPORTED_ACTIONS_BOARD}."
      log "Will fallback to normal menu..."
      DEFAULT_ACTION=""
      sleep 3
    fi
  fi

  while true; do
    clear
    print_header

    local do_default_action=false
    if [ -n "${DEFAULT_ACTION}" ]; then
      do_default_action=true
      log "Will automatically perform action [${DEFAULT_ACTION}]."
      if [ "${ACTION_COUNTDOWN}" = "true" ]; then
        # Give the user the chance to press any key to display the menu.
        log "Press any key to show menu instead..."
        local timeout_secs=3
        for i in $(seq ${timeout_secs} -1 1); do
          # Read with timeout doesn't reliably work multiple times without
          # a sub shell.
          if ( read -N 1 -p "Press any key within ${i} sec> " -t 1 ); then
            echo
            do_default_action=false
            break
          fi
          echo
        done
      fi
    fi

    if ${do_default_action}; then
      # Default action is set and no key pressed: perform the default action.
      "action_${DEFAULT_ACTION}"
    else
      if [ "$(tpm_check_rsu_support)" = "supported" ] && is_rsu_required; then
        # RSU is required.
        colorize yellow
        echo
        echo "This device has FWMP and blocks developer mode."
        echo "It is possibly a managed device."
        echo "Please ask the admin to deprovision the device or perform"
        echo "RSU (RMA Server Unlock)."
        echo
        colorize white
        # Perform RSU.
        echo "Defaulting to RSU"
        sleep 2
        action_e
      else
        # Display the menu for the user to select an option.
        menu
        if [ -n "${ACTION}" ]; then
          # Perform the selected action.
          "action_${ACTION}"
        fi
      fi
    fi

    colorize white
    read -N 1 -p "Press any key to continue> "
  done
}
main "$@"
