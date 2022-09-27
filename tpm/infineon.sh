#!/bin/bash
# Copyright 2021 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# RSU stands for "RMA server unlock".  It allows operators to unlock a device
# without open / disassemble the device.
tpm_perform_rsu() {
  log "RMA Server Unlock is not supported on this platform."
}

# Possible outputs are:
#   "unsupported"
#   "supported"
#   "need_update"
tpm_check_rsu_support() {
  echo "unsupported"
}

# Update TPM firmware.
# If possible, the firmware binary should be loaded from release image.
tpm_update_firmware() {
  /usr/share/cros/init/tpm-firmware-update-factory.sh
}

# Enable "factory mode". Make the device ready to run factory software.
# If there is no "factory mode" for this TPM, this function can do nothing.
# This function should die if factory mode is supported (expected) but failed
# to enable it.
tpm_enable_factory_mode() {
  # Do nothing.
  return 0
}

tpm_get_info() {
  echo -n "Infineon TPM; Board ID flags: $(tpm_get_board_id_flags)"
}

# Outputs TPM board ID.
#   "7f80" is PVT.
#   "7f7f" is pre-PVT
tpm_get_board_id_flags() {
  # Board ID format from cr50: xxxxxxxx:xxxxxxxx:xxxxxxxx
  # Retrieve the last 5 characters (4 + 1 newline) using tail command
  /usr/share/cros/cr50-read-board-id.sh | cut -d ':' -f 3 | tail -c 5
}
