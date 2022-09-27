#!/bin/sh

# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# cros_payload related functions.

. "$(dirname "$0")/factory_common.sh"

# Get the cros_payload metadata by searching for model and board names.
cros_payload_metadata() {
  local src_media="$1"
  local payloads_dir="$(cros_payload get_cros_payloads_dir)"
  local model="$(cros_config / name)"
  local model_json_path="${payloads_dir}/${model}.json"
  local board="$(findLSBValue CHROMEOS_RELEASE_BOARD)"
  local board_json_path="${payloads_dir}/${board}.json"
  if [ -e "${src_media}/${model_json_path}" ]; then
    echo "${model_json_path}"
  elif [ -e "${src_media}/${board_json_path}" ]; then
    echo "${board_json_path}"
  fi
}

# Patch dev_image/etc/lsb-factory using lsb_factory payload.
cros_payload_patch_lsb_factory() {
  local real_usb_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${real_usb_dev}" ] || return 0
  local stateful_dev="${real_usb_dev%[0-9]*}1"
  local temp_lsb_factory="$(mktemp)"
  local mount_point="$(mktemp -d)"
  mount -o ro "${stateful_dev}" "${mount_point}"

  echo 'Patching lsb-factory...'

  local json_path="$(cros_payload_metadata "${mount_point}")"
  local json_url="${mount_point}/${json_path}"
  if [ -n "${json_url}" ]; then
    # If the RMA shim doesn't have lsb_factory payload, this command will fail,
    # leaving temp_lsb_factory empty.
    cros_payload install "${json_url}" "${temp_lsb_factory}" lsb_factory ||
      true
    # Append to lsb-factory file.
    cat "${temp_lsb_factory}" >>"${LSB_FACTORY_FILE}"
  fi

  umount "${stateful_dev}"
  rmdir "${mount_point}"
  rm "${temp_lsb_factory}"
}

# Patch cutoff config in reset shim using toolkit_config payload.
cros_payload_patch_cutoff_config() {
  local real_usb_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${real_usb_dev}" ] || return 0
  local stateful_dev="${real_usb_dev%[0-9]*}1"
  local temp_config_path="$(mktemp)"
  local mount_point="$(mktemp -d)"
  mount -o ro "${stateful_dev}" "${mount_point}"

  echo 'Patching cutoff config...'

  local json_path="$(cros_payload_metadata "${mount_point}")"
  local json_url="${mount_point}/${json_path}"
  if [ -n "${json_url}" ]; then
    # Get toolkit config in cros_payload.
    cros_payload install "${json_url}" "${temp_config_path}" toolkit_config ||
      true
    # Get cutoff config from toolkit config.
    local cutoff_config=""
    if [ -s "${temp_config_path}" ]; then
      cutoff_config="$(
        jq -s '.[].cutoff | select(. != null)' "${temp_config_path}")"
    fi
    # Overwrite board-specific cutoff config (see factory/sh/cutoff/options.sh).
    if [ -n "${cutoff_config}" ]; then
      local config_path="/usr/share/cutoff/cutoff.json"
      echo "${cutoff_config}" >"${config_path}"
    fi
  fi

  umount "${stateful_dev}"
  rmdir "${mount_point}"
  rm "${temp_config_path}"
}

# Install dev_image/etc/description from description payload.
cros_payload_install_description() {
  local real_usb_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${real_usb_dev}" ] || return 0
  local stateful_dev=${real_usb_dev%[0-9]*}1
  local temp_path="$(mktemp)"
  local mount_point="$(mktemp -d)"
  mount -o ro "${stateful_dev}" "${mount_point}"

  echo 'Installing description...'

  local json_path="$(cros_payload_metadata "${mount_point}")"
  local json_url="${mount_point}/${json_path}"
  if [ -n "${json_url}" ]; then
    cros_payload install_optional "${json_url}" "${temp_path}" description
  fi
  umount "${stateful_dev}"
  rmdir "${mount_point}"

  cat "${temp_path}" >"${DESCRIPTION_FILE}"
  rm "${temp_path}"
}
