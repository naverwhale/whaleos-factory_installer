#!/bin/sh
# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This is loaded and executed by
# src/platform/initramfs/factory_shim/bootstrap.sh for patching rootfs in tmpfs.
# Note that this script may be executed by busybox shell (not bash, not dash).

# USB stateful partition mount point.
STATEFUL_MNT=/stateful

get_stateful_dev() {
  local real_usb_dev="$1"
  local stateful_dev="${real_usb_dev%[0-9]*}1"
  if [ ! -b "${stateful_dev}" ]; then
    stateful_dev=""
  fi
  echo "${stateful_dev}"
}

mount_stateful() {
  local real_usb_dev="$1"
  local stateful_dev="$(get_stateful_dev "${real_usb_dev}")"
  if [ -z "${stateful_dev}" ]; then
    echo "Failed to determine stateful device."
    return 1
  fi

  echo "Mounting stateful..."
  mkdir -p "${STATEFUL_MNT}"
  if ! mount -n "${stateful_dev}" "${STATEFUL_MNT}"; then
    echo "Failed to mount ${stateful_dev}!! Failing."
    return 1
  fi
}

umount_stateful() {
  umount -n "${STATEFUL_MNT}" || true
  rmdir "${STATEFUL_MNT}" || true
}

# Usage: check_exists path new_root_prefix
# Returns if the path exists, and prints if path (without new_root_prefix)
# exists by adding a + or - prefix.
check_exists() {
  local file="$1"
  local new_root="$2"

  if [ -e "${file}" ]; then
    printf " +%s" "${file#${new_root}}"
    return 0
  else
    printf " -%s" "${file#${new_root}}"
    return 1
  fi
}

# Usage: patch_new_root new_root
# Patches new_root for booting into factory shim environment.
patch_new_root() {
  local new_root="$1"
  local file job
  printf "Patching new root in %s..." "${new_root}"

  # Copy essential binaries that are in the initramfs, but not in the root FS.
  cp /bin/busybox "${new_root}/bin"
  "${new_root}/bin/busybox" --install "${new_root}/bin"

  # Never execute the firmware updater from shim.
  touch "${new_root}"/root/.leave_firmware_alone

  # Modify some files that does not work (and not required) in tmpfs chroot.
  # This may be removed when we can build factory installer in "embedded" mode.
  file="${new_root}/usr/sbin/mount-encrypted"
  if check_exists "${file}" "${new_root}"; then
    echo '#!/bin/sh' >"${file}"
    echo 'echo "Sorry, $0 is disabled on factory installer image."' >>"${file}"
  fi

  # Copy and override factory-shim specific jobs.
  for file in "${new_root}"/usr/share/factory_installer/init/*.conf; do
    cp "${file}" "${new_root}/etc/init/"
  done

  # Set network to start up another way.
  file="${new_root}/etc/init/boot-complete.conf"
  if check_exists "${file}" "${new_root}"; then
    sed -i 's/login-prompt-visible/started boot-services/' "${file}"
  fi

  # Disable upstart jobs that will block execution for factory shim environment.
  # syslog: it expects rsyslogd exists, but we don't have rsyslogd in factory
  #     shim.
  # journald: it expects systemd-journald exists, which is not available in
  #     factory shim.
  # ext-pci-drivers-allowlist: it depends on syslog.
  local disabled_jobs
  disabled_jobs="cdm-oemcrypto powerd swap syslog tpm-probe ui update-engine
                 journald cryptohome-update-userdataauth
                 ext-pci-drivers-allowlist activate_date tlsdated"

  for job in ${disabled_jobs}; do
    file="${new_root}/etc/init/${job}.conf"
    if check_exists "${file}" "${new_root}"; then
      # Upstart honors the last 'start on' clause it finds.
      echo "start on never" >>"${file}"
    fi
  done

  # Dummy jobs are empty single shot tasks because there may be services waiting
  # them to finish.
  # - boot-splash.conf: will try to invoke another frecon instance.
  # - cr50-update.conf: will try to update cr50 firmware, which we want to do
  #     explicitly (via action_u in factory_install.sh).
  local dummy_jobs="boot-splash cr50-update"

  for job in ${dummy_jobs}; do
    file="${new_root}/etc/init/${job}.conf"
    if check_exists "${file}" "${new_root}"; then
      sed -i '/^start /!d' "${file}"
      echo "exec true" >>"${file}"
    fi
  done

  # We don't want any consoles to be executed.
  # To debug using servo, please comment this line.
  rm -f "${new_root}"/etc/init/console-*.conf

  # The laptop_mode may be triggered from udev.
  rm -f "${new_root}/etc/udev/rules.d/99-laptop-mode.rules"

  printf ""
}

# Usage: patch_new_run new_root
# Patches new /run (tmpfs) under new_root for booting into factory shim
# environment.
patch_new_run() {
  local new_root="$1"
  printf "Patching new /run..."

  # /run by initramfs is sharing same tmpfs with root without having its own
  # mounted tmpfs so we can't use `mount --bind` or `mount --move`; so
  # duplicating /run is needed.

  # Replicate running data (/run).
  tar -cf - /run | tar -xf - -C "${new_root}"

  # frecon[-lite] creates TTY files in /dev/pts and have symlinks in
  # /run/frecon. However, /dev/pts will be re-created by chromeos_startup after
  # switch_root. As a result, we want to keep a copy of /dev/pts in /dev/frecon
  # and change symlinks to use them.
  if check_exists "${new_root}/run/frecon"; then
    local new_pts="/dev/frecon-lite"
    mkdir -p "${new_pts}"
    mount --bind /dev/pts "${new_pts}"
    for vt in "${new_root}"/run/frecon/vt*; do
      # It is assumed all vt* should refer to /dev/pts/*.
      file="$(basename $(readlink -f "${vt}"))"
      rm -f "${vt}"
      ln -s "${new_pts}/${file}" "${vt}"
    done
  fi
  printf ""
}

# Usage: patch_dev
# Patches /dev for booting into factory shim environment. /dev will later be
# mount moved to new_root so we can make changes in the current root.
patch_dev() {
  printf "Patching /dev..."

  # Some daemons are run in minijail with `--profile=minimalistic-mountns`
  # argument, which requires /dev/log to exist.
  if [ ! -e /dev/log ]; then
    touch /dev/log
  fi
}

# Usage: copy_lsb new_root stateful
# Copy lsb-factory from USB to new_root.
copy_lsb() {
  local new_root="$1"
  local real_usb_dev="$2"
  printf "Copying lsb-factory..."

  mount_stateful "${real_usb_dev}"
  local lsb_factory_relpath="dev_image/etc/lsb-factory"
  local dest_path="${new_root}/mnt/stateful_partition/${lsb_factory_relpath}"
  local src_path="${STATEFUL_MNT}/${lsb_factory_relpath}"

  mkdir -p "$(dirname ${dest_path})"

  local ret=0
  if [ -f "${src_path}" ]; then
    # Convert it to upper case and store it to lsb file.
    local kern_guid=$(echo "${KERN_ARG_KERN_GUID}" | tr '[:lower:]' '[:upper:]')
    echo "Found ${src_path}"
    cp -a "${src_path}" "${dest_path}"
    echo "REAL_USB_DEV=${real_usb_dev}" >>"${dest_path}"
    echo "KERN_ARG_KERN_GUID=${kern_guid}" >>"${dest_path}"
  else
    echo "Failed to find ${src_path}!! Failing."
    ret=1
  fi
  umount_stateful
  return "${ret}"
}

main() {
  local new_root="$1"
  local real_usb_dev="$2"
  patch_new_root "${new_root}"
  patch_new_run "${new_root}"
  patch_dev
  copy_lsb "${new_root}" "${real_usb_dev}"
}
set -e
main "$@"
