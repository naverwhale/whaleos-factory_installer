# Chrome OS Factory Shim

## Introduction
This folder contains the major scripts for the "Chrome OS factory shim".
The shim is used for installing a Chrome OS image (kernel, rootfs and firmware)
to a device. It's also known as "(factory) install shim", "RMA shim", or "Reset
shim".

The factory shim is designed to allow operators removing USB stick once it's
booted, so the boot process is slightly different. The shim relies on
`initramfs` technology to bootstrap and load all contents into memory, then
start an upstart service to display the menu.

## Building a factory shim
Inside chroot, do:

    build_packages --board $BOARD
    build_image --board $BOARD factory_install

The output disk image is in
`~/trunk/src/build/images/$BOARD/latest/factory_install_shim.bin`.

If you have local changes in `src/platform/factory_installer`, please remember
to do

    cros_workon --board $BOARD start factory_installer
    emerge-$BOARD factory_installer

If you have local changes in `src/platform/initramfs`, please remember to do

    cros_workon --board $BOARD start chromeos-initramfs

There's no need to emerge `chromeos-initramfs` because it's always re-built in
`build_image` stage.

## Using factory shim
Factory shims are signed in a special way for security reasons. It needs to
boot with "developer switch turned on" and "boot in recovery mode".

### Boot from install shim (clamshells / convertibles)
  1. Enter recovery mode
  2. Press `CTRL + D` to turn on developer switch
  3. Press `ENTER` to confirm
  4. Enter recovery mode again (no need to wait for wiping)
  5. Insert and boot from USB stick with `rma_image.bin`

### Boot from install shim (tablets / detachables)
  1. Enter recovery mode
  2. Press `VOL_UP + VOL_DOWN` to show recovery menu
  3. Press `VOL_UP` or `VOL_DOWN` to move the cursor to "Confirm Disabling OS
     Verification", and press `POWER` to select it
  4. Enter recovery mode again (no need to wait for wiping)
  5. Insert and boot from USB stick with `rma_image.bin`

See [here](https://google.com/chromeos/recovery) for instructions to enter
recovery mode.

If you boot factory shim in developer mode (`Ctrl-U`), some functions won't
work, such as recovering TPM.

## Factory shim menu
If you boot into a factory shim successfully, you will see a shim menu, followed
by a prompt to select an action.

    Please select an action and press Enter.

      I Install              Performs a network or USB install
      R Reset                Performs a factory reset; finalized devices only
      S Shell                Opens bash; available only with developer firmware
      V View configuration   Shows crossystem, VPD, etc.
      D Debug info and logs  Shows useful debugging information and kernel/firmware logs
      Z Zero (wipe) storage  Makes device completely unusable
      C SeCure erase         Performs full storage erase, write a verification pattern
      Y VerifY erase         Verifies the storage has been erased with option C
      T Reset TPM            Call chromeos-tpm-recovery
      U Update TPM Firmware  Update TPM firmware
      E Perform RSU          Perform RSU (RMA Server Unlock)
      M Enable factory mode  Enable TPM factory mode

    action>

The install shim also checks `/etc/lsb-factory` for flags that decides the
default action of the shim menu (listed from high priority to low priority).
  1. `NETBOOT_RAMFS=1`: This flag is automatically set when using netboot
     firmware. The install shim will set the default action to **(I) Install**.
  2. `RMA_AUTORUN=true`: This flag is set by `image_tool` when creating an RMA
     shim. Please see
     [RMA shim README](https://chromium.googlesource.com/chromiumos/platform/factory/+/HEAD/setup/RMA_SHIM.md)
     for the behavior of this parameter.
  3. `DEFAULT_ACTION=<action>`: This flag directly sets the default action
     to **<action>**. For instance, `DEFAULT_ACTION=i` sets the default action
     to **(I) Install**.

### Board-specific actions

With technique
[installer resource](https://chromium.googlesource.com/chromiumos/platform/factory/+/HEAD/resources/README.md#installer-resource)
in factory-board, you can add some board-specific actions by defining variables
and functions in `factory_install_board.sh` in private overlay. For example:

```sh
#!/bin/bash

SUPPORTED_ACTIONS_BOARD=x

menu_board() {
    menu_line X "Magic Command" "Run magic command"
}

action_x() {
    echo "Magic on board ${BOARD}."
}
```

## Debugging a factory shim
Factory shims do not provide shells by default for security reason. If you can
still see virtual terminal consoles, try VT0, VT1, VT2, VT3 - there are lots of
debug messages there.

### Getting a shell
If you do need a shell to debug, add `cros_debug` to kernel command line. You
can do this in `build_image`:

    build_image --board $BOARD --boot_args cros_debug factory_install

For an existing image, you can use `make_dev_ssd.sh` to change kernel command
line easily:

    # inside chroot
    cd ~/trunk/src/platform/vboot_reference/scripts/image_signing
    ./make_dev_ssd.sh -i $PATH_TO_IMAGE_OR_USB_DEVICE \
       --partitions 2 --recovery --edit_config

This will bring an editor to allow editing command line.

Note `make_dev_ssd.sh` is also available on all Chrome OS image (even factory
shim) - try `/usr/share/vboot/bin/make_dev_ssd.sh`.

If you boot a factory shim with `cros_debug`, then you should have one shell in
VT2 or VT3. Moreover, if you can enter the menu, 'S' will give you the full
shell.

### Fail to start frecon
The `frecon` (or `frecon-lite`) provides text-based console. If you can't see
anything on screen, redirect the console to another device, for example Servo
consoles so you can check why `frecon` failed. To do this, add
`console=ttyS0,115200n8` to kernel command line (use the `make_dev_ssd.sh` or
add `--boot_args` as explained in previous section). Some devices may need
different TTY name for example `ttyS1`. Please check the care-and-feed doc of
your device.

### Debugging frecon issues
If the menu or frecon will die and adding `cros_debug` does not help, you
probably want to attach serial console (for example SuzyQ) and get everything
except factory shim UI (menu) there. To do that:

1. Check if you need to build a new image.

Open the `/usr/sbin/factory_tty.sh` and find the `TTY_CONSOLE=` line. If it
already has valid serial console (for example `ttyS0`), move to step 3.

2. Add `TTY_CONSOLE` and build image.

Edit the `make.conf` in board overlay, to find or add one setting (assume serial
console is `ttyS0`):

    TTY_CONSOLE="ttyS0"

Then,then re-build the `factory_installer` package and factory shim:

    emerge-$BOARD factory_installer
    build_image --board $BOARD factory_install

3. Enable console service.

Mount the rootfs and rename `/etc/init/console-ttyS0.conf` to something that
does not start as `console`:

    # First enable RW for rootfs. Assume the USB is in /dev/sdX.
    cd ~/trunk/src/platform/vboot_reference/scripts/image_signing
    sudo ./make_dev_ssd.sh -i /dev/sdX --recovery \
       --remove_rootfs_verification --partitions 2
    # Mount (assume your shim is in /dev/sdX)
    sudo mount /dev/sdX /media
    cd /media/etc/init
    sudo mv console-ttyS0.confg debug-ttyS0.conf
    cd - # To leave /media folder so we can unmount.
    sudo umount /media

4. Boot with the shim. You should have serial console now.
