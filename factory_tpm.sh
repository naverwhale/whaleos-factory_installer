#!/bin/bash
# Copyright 2021 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

tpm_init_factory_tpm() {
  local manufacturer_info="$(tpm_version | grep 'Manufacturer Info' | \
      grep -o '\S\+$')"
  local script_dir="/usr/share/factory_installer/tpm"

  case "${manufacturer_info}" in
    "43524f53")
      # This is "CROS", could be cr50 or ti50.
      source "${script_dir}/cros.sh"
      ;;
    "49465800")
      # This is "IFX" ==> infineon TPM
      source "${script_dir}/infineon.sh"
      ;;
    *)
      echo "Unrecognized TPM, manufacturer_info=${manufacturer_info}."
      echo "Loading stub implementation..."
      source "${script_dir}/stub.sh"
      ;;
  esac
}

tpm_init_factory_tpm
