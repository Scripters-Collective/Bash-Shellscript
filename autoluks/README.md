-----

# `autoluks.sh`: Automatic LUKS & TPM Enrollment Script

This script automates the process of enrolling LUKS-encrypted volumes with a system's TPM (Trusted Platform Module) for automatic unlocking. It is designed to configure both the root filesystem (for pre-boot unlock) and any non-root filesystems (for post-boot unlock).

## ⚠️ Important Warning

This script modifies critical system configuration files, including kernel boot arguments (`grubby`), filesystem mounting tables (`/etc/crypttab`), and the initial RAM filesystem (`dracut`).

  * **BACKUP YOUR DATA** before running this script.
  * This script is designed for **Fedora-based systems** (Fedora, RHEL, CentOS Stream) that use `grubby` and `dracut`. It will **not** work on Debian/Ubuntu-based systems.
  * A failed `dracut` build at the end can render your system unbootable. Pay close attention to the script's output.
  * Use this script at your own risk.

## 🎯 Features

  * **Finds All LUKS Devices:** Automatically scans `lsblk` for all `crypto_LUKS` partitions.
  * **Configures Root FS:** Adds the necessary `rd.luks.tpm2-device=auto` kernel argument for unlocking the root filesystem during boot.
  * **Enrolls TPM Key:** Enrolls the TPM (using PCR 7) for each LUKS device, prompting you for the *current* LUKS password to authorize the change.
  * **Configures Non-Root FS:** Modifies `/etc/crypttab` to add the `tpm2-device=auto` option, allowing secondary encrypted drives (e.g., `/home`, `/data`) to be unlocked automatically after boot.
  * **Safety Backup:** Creates a backup of your existing `/etc/crypttab` at `/etc/crypttab.bak` before making changes.
  * **Rebuilds Initramfs:** Automatically runs `dracut --force` if any changes were made that require an initramfs update.

## 📋 Requirements

  * A Linux system using **`dracut`** and **`grubby`** (e.g., Fedora).
  * **`systemd-cryptenroll`** (part of the `systemd` package).
  * A **TPM 2.0** module (physical or virtual) enabled and accessible.
  * One or more **LUKS-encrypted** volumes.
  * You must run this script as **root** or with `sudo`.

## 🚀 How to Use

1.  **Download the Script:**
    Save the file as `autoluks.sh`.

2.  **Make it Executable:**

    ```bash
    chmod +x autoluks.sh
    ```

3.  **Run with Sudo:**

    ```bash
    sudo ./autoluks.sh
    ```

4.  **Authorize Enrollment:**
    The script will loop through each LUKS device it finds. If a device is not yet enrolled with the TPM, the script will pause and ask you to **enter the current LUKS password** for that device.

    ```
    ******************************************************************
    Please enter the CURRENT LUKS password for /dev/sdXN to authorize.
    ******************************************************************
    ```

    This is required by `systemd-cryptenroll` to prove you own the device before adding a new (TPM) key.

5.  **Reboot:**
    If the script completes successfully and `dracut` rebuilds the initramfs, you **must reboot** your system for the changes to take effect.

    After rebooting, your root filesystem should unlock automatically. If you had other LUKS volumes, they should be automatically unlocked and mounted (per your `/etc/fstab` configuration) without a password prompt.

## 🔧 What it Does (Detailed Breakdown)

1.  **Root Check:** Verifies you are running as root.
2.  **Kernel Argument:** Uses `grubby` to add `rd.luks.tpm2-device=auto` to the default kernel's boot arguments. This instructs the initramfs to look for a TPM to unlock the root partition.
3.  **Backup `crypttab`:** Creates `/etc/crypttab.bak` if one doesn't already exist.
4.  **Device Loop:**
      * Finds all `crypto_LUKS` devices (e.g., `/dev/sda3`, `/dev/nvme0n1p3`).
      * For each device:
          * Gets its **UUID**.
          * Checks if a `tpm2` key is already enrolled.
          * If not, it runs `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7` to enroll the device. It uses **PCR 7** (Secure Boot state). You will be prompted for your existing LUKS password here.
          * It then checks `/etc/crypttab` for an entry corresponding to that UUID.
          * **If an entry exists:** It modifies the options (4th field) to append `,tpm2-device=auto`.
          * **If no entry exists:** It creates a new line for the device, using `tpm2-device=auto` in the options. This is for non-root volumes.
5.  **Rebuild Initramfs:**
      * If *any* changes were made (kernel args, TPM enrollment, or `crypttab` edits), a flag (`needs_dracut`) is set.
      * If this flag is `true`, it runs `sudo dracut --force` to rebuild the initramfs with the new configuration.
      * **\! CRITICAL \!** If `dracut` fails, the script will print a large error message. **DO NOT REBOOT** if you see this. Check the `dracut` output for errors.

## 📄 License

This script is released under the **MIT License**. See the header of the script file for full details.
