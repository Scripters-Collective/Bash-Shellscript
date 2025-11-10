# LUKS Keyfile Auto-Unlock for RHEL

This repository contains a simple shell script, `autoluks.sh`, designed to automate the process of setting up passwordless unlocking for LUKS-encrypted volumes on RHEL-based systems (e.g., RHEL 9.x, CentOS, Fedora).

## Overview

The script performs the following actions to enable a seamless boot experience without requiring you to enter a LUKS passphrase for each encrypted disk:

1.  **Generates a Secure Keyfile**: Creates a single, random 4096-byte keyfile and stores it securely in `/root/luks-keyfile`.
2.  **Adds Key to LUKS Devices**: Associates this keyfile with every LUKS-encrypted block device on the system.
3.  **Configures `crypttab`**: Automatically updates `/etc/crypttab` to instruct the system to use the keyfile to unlock each device during the boot process.
4.  **Rebuilds `initramfs`**: Rebuilds the initial RAM filesystem using `dracut` to ensure the changes are applied on the next boot.

This method is ideal for systems where physical security is assured (e.g., servers in a secure data center, personal workstations) and convenience is desired.

## Prerequisites

- A running RHEL-based Linux system (e.g., RHEL 9.x).
- One or more LUKS-encrypted block devices.
- Root or `sudo` privileges.

## Usage

1.  **Copy the Script**: Transfer the `autoluks.sh` script to the target machine.

2.  **Make it Executable**:
    ```bash
    chmod +x autoluks.sh
    ```

3.  **Run the Script**: Execute the script with `sudo`.
    ```bash
    sudo ./autoluks.sh
    ```

The script will then guide you through the process:
- It will generate the keyfile (if one doesn't already exist).
- It will ask for your current LUKS passphrase **once**. This is required to authorize adding the new keyfile to your encrypted devices.
- It will automatically detect and configure all LUKS volumes.
- Finally, it will ask for your confirmation before rebuilding the `initramfs`.

After the script completes successfully and the `initramfs` is rebuilt, you can reboot the system.

## Security Considerations

- The keyfile is stored at `/root/luks-keyfile` with `0400` permissions, meaning it is only readable by the root user.
- While this method protects the data at rest, anyone with root access to the running system can read this keyfile. This is an inherent trade-off for the convenience of auto-unlocking.
- Your original passphrase is **not** removed or changed. It remains a valid way to unlock the drives and can be used as a backup method for recovery.

## Troubleshooting

If the system still prompts for a password after running the script and rebooting:

1.  **Verify `/etc/crypttab`**: Log in and check the contents of `/etc/crypttab`. Each line for a LUKS device should point to the `/root/luks-keyfile`.
    ```
    # Example entry in /etc/crypttab
    luks-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx /root/luks-keyfile luks
    ```

2.  **Verify `initramfs`**: Ensure the `initramfs` was rebuilt correctly and contains the necessary files. You can check the contents of your latest `initramfs` image with `lsinitrd`.
    ```bash
    # Check for the keyfile and crypttab in the initramfs
    lsinitrd | grep luks-keyfile
    lsinitrd | grep crypttab
    ```
    If they are missing, run `sudo dracut -f --regenerate-all` to manually rebuild the `initramfs` and reboot.
