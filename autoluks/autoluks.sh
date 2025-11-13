#!/bin/bash

# =========================================================================
# MIT License
#
# Copyright (c) 2025 Google
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# =========================================================================
#
# autoluks.sh
#!/bin/bash

# This script finds all LUKS-encrypted volumes, enrolls them with
# the system's vTPM, adds kernel args (for root fs), MODIFIES
# /etc/crypttab entries (for non-root fs), and rebuilds the initramfs.
#
# It MUST be run as root (or with sudo) to work.

# --- Safety Check: Must be root ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  echo "Example: sudo ./autoluks.sh"
  exit 1
fi

echo "Starting Full LUKS TPM Enrollment and Configuration Process..."
echo ""

# This flag will track if we need to run dracut at the end
needs_dracut=false

# --- 1. Handle Kernel Argument (for Root Filesystem) ---
# This tells the initramfs (pre-boot) to look for a TPM.
if ! grubby --info=DEFAULT | grep -q "rd.luks.tpm2-device=auto"; then
    echo "Adding 'rd.luks.tpm2-device=auto' to kernel boot arguments..."
    if sudo grubby --update-kernel=ALL --args="rd.luks.tpm2-device=auto"; then
        echo "Successfully added kernel argument."
        needs_dracut=true
    else
        echo "ERROR: Failed to add kernel argument with grubby. Halting."
        exit 1
    fi
else
    echo "Kernel argument 'rd.luks.tpm2-device=auto' is already set."
fi
echo "---"

# --- 2. Create a backup of /etc/crypttab ---
if [ ! -f /etc/crypttab.bak ]; then
    echo "Creating backup: /etc/crypttab.bak"
    sudo cp /etc/crypttab /etc/crypttab.bak
fi

# --- 3. Loop Through Devices (Enroll & Add to crypttab) ---
luks_devices=$(lsblk -o PATH,FSTYPE --noheadings | awk '$2 == "crypto_LUKS" {print $1}')

if [ -z "$luks_devices" ]; then
    echo "No LUKS devices found. Exiting."
    exit 0
fi

for device in $luks_devices; do
    echo "--- Processing $device ---"

    # --- Get Device UUID ---
    uuid=$(blkid -s UUID -o value "$device")
    if [ -z "$uuid" ]; then
        echo "Could not find UUID for $device. Skipping."
        continue
    fi
    echo "Device UUID: $uuid"

    # --- Enroll TPM Key ---
    if systemd-cryptenroll "$device" | grep -q 'tpm2'; then
        echo "TPM2 is already enrolled on $device."
    else
        echo "No TPM2 enrollment found. Attempting to enroll $device..."
        echo "******************************************************************"
        echo "Please enter the CURRENT LUKS password for $device to authorize."
        echo "******************************************************************"

        if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$device"; then
            echo "Successfully enrolled $device with TPM2."
            needs_dracut=true
        else
            echo "Failed to enroll $device. The password may have been incorrect."
            echo "Skipping /etc/crypttab check for this device."
            continue
        fi
    fi

    # --- Configure /etc/crypttab (for Non-Root Filesystems) ---
    tpm_entry_exists=$(grep -qE "^[^#]*UUID=$uuid.*tpm2-device=auto" /etc/crypttab && echo "true" || echo "false")
    other_entry_exists=$(grep -qE "^[^#]*UUID=$uuid" /etc/crypttab && echo "true" || echo "false")

    if [ "$tpm_entry_exists" = "true" ]; then
        echo "Correct TPM entry already exists in /etc/crypttab."
    elif [ "$other_entry_exists" = "true" ]; then
        echo "Found existing entry for $uuid. Adding 'tpm2-device=auto'..."
        
        # This sed command finds the line with the UUID and appends ",tpm2-device=auto"
        # to the 4th field (the options field).
        sudo sed -i -E "/^[^#]*UUID=$uuid/ s/([^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t#]+)/\1,tpm2-device=auto/" /etc/crypttab
        
        echo "Modified line in /etc/crypttab."
        needs_dracut=true
    else
        echo "No entry found in /etc/crypttab for this device. Adding new line."
        mapper_name="luks-$uuid"
        echo "$mapper_name  UUID=$uuid  none  tpm2-device=auto" | sudo tee -a /etc/crypttab
        echo "Successfully added new entry to /etc/crypttab."
        needs_dracut=true
    fi

    echo "-----------------------------------"
    echo ""
done

# --- 4. Rebuild initramfs (dracut) ---
if [ "$needs_dracut" = true ]; then
    echo "Changes were made."
    echo "Rebuilding initramfs (dracut)... This may take a moment."
    
    if sudo dracut --force; then
        echo "dracut rebuild complete."
        echo ""
        echo "All steps finished. Please reboot now."
    else
        echo "*****************************************************************"
        echo "DRACUT FAILED. Please check the output above. DO NOT REBOOT."
        echo "*****************************************************************"
    fi
else
    echo "All devices are already configured. No changes needed."
fi
