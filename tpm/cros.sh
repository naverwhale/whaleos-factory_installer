#!/bin/bash
# Copyright 2021 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Because tpm/*.sh is installed in a different directory, we should use
# absolute path.
. "/usr/sbin/factory_common.sh"

GSCTOOL="gsctool"
PROD_CR50_PATH="opt/google/cr50/firmware/cr50.bin.prod"


_copy_prod_cr50_firmware() {
  # Create a copy of prod cr50 firmware in rootfs to a temporary file.
  # The caller is responsible for deleting the temp file.
  local rootfs_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${rootfs_dev}" ] ||
    die "Unknown media source. Please define REAL_USB_DEV."
  local mount_point="$(mktemp -d)"
  local firmware_path="${mount_point}/${PROD_CR50_PATH}"
  local temp_firmware="$(mktemp)"

  mount -o ro "${rootfs_dev}" "${mount_point}"
  cp "${firmware_path}" "${temp_firmware}"
  umount "${rootfs_dev}"
  rmdir "${mount_point}"

  echo "${temp_firmware}"
}

_get_cr50_output_value() {
  local output="$1"
  local key="$2"
  echo "${output}" | grep "^${key}" | sed "s/${key}=//g"
}

_get_cr50_rw_version() {
  _get_cr50_output_value "$(${GSCTOOL} -a -f -M)" 'RW_FW_VER'
}

_get_cr50_image_rw_version() {
  _get_cr50_output_value "$(${GSCTOOL} -b -M "$1")" 'IMAGE_RW_FW_VER'
}

_check_need_update_cr50() {
  local temp_firmware="$(_copy_prod_cr50_firmware)"
  local image_version="$(_get_cr50_image_rw_version "${temp_firmware}")"
  local image_version_major=$(echo "${image_version}" | cut -d '.' -f 2)
  local image_version_minor=$(echo "${image_version}" | cut -d '.' -f 3)
  rm "${temp_firmware}"

  local device_version="$(_get_cr50_rw_version)"
  local device_version_major=$(echo "${device_version}" | cut -d '.' -f 2)
  local device_version_minor=$(echo "${device_version}" | cut -d '.' -f 3)

  # Update only if cr50 version on the device is smaller than the cr50 version
  # in install shim. Some older devices may have cr50 version 0.0.*, 0.1.* or
  # 0.2.*, and we also update these devices to 0.3.*.
  # See go/cr50-release-notes for more information.
  if [ "${device_version_major}" -ne "${image_version_major}" ]; then
    [ "${device_version_major}" -lt "${image_version_major}" ]
  else
    [ "${device_version_minor}" -lt "${image_version_minor}" ]
  fi
}

_is_cr50_factory_mode_enabled() {
  # If the cr50 RW version is 0.0.*, the device is booted to install shim
  # straight from factory. The cr50 firmware does not support '-I' option and
  # factory mode, so we treat it as factory mode enabled to avoid turning on
  # factory mode.
  local rw_version="$(_get_cr50_rw_version)"
  if [[ "${rw_version}" = '0.0.'* ]]; then
    echo "Cr50 version is ${rw_version}. Assume factory mode enabled."
    return 0
  fi
  # The pattern of output is as below in case of factory mode enabled:
  # State: Locked
  # Password: None
  # Flags: 000000
  # Capabilities, current and default:
  #   ...
  # Capabilities are modified.
  #
  # If factory mode is disabed then the last line would be
  # Capabilities are default.
  ${GSCTOOL} -a -I 2>/dev/null | \
    grep '^Capabilities are modified.$' >/dev/null
  return $?
}

tpm_perform_rsu() {
  /usr/share/cros/cr50-reset.sh
}

tpm_check_rsu_support() {
  if ! command -v /usr/share/cros/cr50-reset.sh >/dev/null; then
    # cr50-reset.sh is not available, we cannot perform RSU.
    echo "unsupported"
    return 0
  fi

  if _check_need_update_cr50; then
    echo "need_update"
    return 0
  else
    echo "supported"
    return 0;
  fi
}

tpm_update_firmware() {
  local temp_firmware="$(_copy_prod_cr50_firmware)"

  local result=0
  "${GSCTOOL}" -a -u "${temp_firmware}" || result="$?"

  rm "${temp_firmware}"

  # Allow 0(no-op), 1(all_updated), 2(rw_updated), other return values are
  # considered fail.
  # See trunk/src/platform/ec/extra/usb_updater/gsctool.h for more detail.
  case "${result}" in
    "0" )
      log "Cr50 not updated. Returning to shim menu."
      # sleep for a while to show the messages
      sleep 3
      return 0
      ;;
    "1" | "2" )
      log "Cr50 updated. System will reboot shortly."
      # sleep for a while to show the messages
      sleep 3
      reboot
      sleep 1d
      return 0
      ;;
    *)
      die "gsctool execution failed as ${result}."
      ;;
  esac
}

tpm_enable_factory_mode() {
  if _is_cr50_factory_mode_enabled; then
    log "Factory mode was already enabled."
    return 0
  fi

  if check_hwwp; then
    die "The hardware write protection should be disabled first."
  fi

  log "Starting to enable factory mode and will reboot automatically."
  local ret=0
  ${GSCTOOL} -a -F enable 2>&1 || ret=$?

  if [ ${ret} != 0 ]; then
    local ver="$(_get_cr50_rw_version)"
    log "Failed to enable factory mode; cr50 version: ${ver}"
    log "Try RSU..."
    action_e || die "Failed to perform RSU..."
    # action_e should reboot if it succeeds.
    return 0
  fi

  # Once enabling factory mode, system should reboot automatically.
  log "Successfully to enable factory mode and should reboot soon."
  # sleep indefinitely to avoid re-spawning rather than reboot.
  sleep 1d
}

tpm_get_info() {
  echo -n "Cr50 version: $(_get_cr50_rw_version); "
  echo -n "Board ID flags: 0x$(tpm_get_board_id_flags)"
}

tpm_get_board_id_flags() {
  _get_cr50_output_value "$(${GSCTOOL} -a -i -M)" 'BID_FLAGS'
}
