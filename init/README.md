# ChromeOS Factory Shim Init System

The `init` folder contains configurations to change ChromeOS factory shim
upstart jobs.

The boot flow of factory shim is:
  - bootstrap stage:
    - platform/initramfs/factory_shim/init ->
    - platform/initramfs/factory_shim/bootstrap.sh ->
    - platform/factory_installer/factory_bootstrap.sh ->
    - switch_root
  - upstart stage:
    - /sbin/init (upstart) ->
    - upstart jobs

/tmp and /run will be created **before** upstart starts. Some processes such as
frecon-lite that are started in bootstrap stage (therefore before upstart)
would create files under /tmp or /run, and we want to preserve these folders in
upstart stage. upstart mounts /tmp and /run as tmpfs, which masks the original
contents in these folders, so we have to overwrite upstart jobs to unmount them.

