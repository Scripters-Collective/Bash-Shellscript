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
# This script finds all LUKS-encrypted volumes, enrolls them with
# the system's vTPM, adds a configuration to /etc/crypttab,
# and finally rebuilds the initramfs (dracut).
#
# It MUST be run as root (or with sudo) to work.

# --- Safety Check: Must be root ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  echo "Example: sudo ./enroll_configure_luks.sh"
  exit 1
fi

echo "Starting Full LUKS TPM Enrollment Process..."
echo ""

# This flag will track if we need to run dracut at the end
needs_dracut=false

# Find all devices with FSTYPE="crypto_LUKS" and get their full /dev/path
luks_devices=$(lsblk -o PATH,FSTYPE --noheadings | awk '$2 == "crypto_LUKS" {print $1}')

if [ -z "$luks_devices" ]; then
    echo "No LUKS devices found."
    exit 0
fi

# Loop through each found device
for device in $luks_devices; do
    echo "--- Processing $device ---"

    # --- 1. Get Device UUID ---
    uuid=$(blkid -s UUID -o value "$device")
    if [ -z "$uuid" ]; then
        echo "Could not find UUID for $device. Skipping."
        continue
    fi
    echo "Device UUID: $uuid"

    # --- 2. Enroll TPM Key ---
    if systemd-cryptenroll "$device" | grep -q 'tpm2'; then
        echo "TPM2 is already enrolled on $device."
    else
        echo "No TPM2 enrollment found. Attempting to enroll $device..."
        echo ""
        echo "******************************************************************"
        echo "Please enter the CURRENT LUKS password for $device to authorize."
        echo "This password will NOT be saved. It is only used to add the TPM key."
        echo "******************************************************************"

        if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$device"; then
            echo "Successfully enrolled $device with TPM2."
            needs_dracut=true
        else
            echo ""
            echo "Failed to enroll $device. The password may have been incorrect."
            echo "Skipping /etc/crypttab check for this device."
            continue
        fi
    fi

    # --- 3. Check and Configure /etc/crypttab ---
    
    # Check if a correct, non-commented-out TPM entry already exists.
    tpm_entry_exists=$(grep -qE "^[^#]*UUID=$uuid.*tpm2-device=auto" /etc/crypttab && echo "true" || echo "false")
    
    # Check if any non-commented-out entry for this UUID exists.
    other_entry_exists=$(grep -qE "^[^#]*UUID=$uuid" /etc/crypttab && echo "true" || echo "false")

    if [ "$tpm_entry_exists" = "true" ]; then
        echo "Correct TPM entry already exists in /etc/crypttab."
    elif [ "$other_entry_exists" = "true" ]; then
        # An entry exists, but it's not the correct TPM one.
        echo "Warning: Found an entry for $uuid in /etc/crypttab, but it does NOT have 'tpm2-device=auto'."
        echo "Please edit /etc/crypttab manually to add this option to the existing line."
        echo "Skipping automatic add to avoid duplicate entries."
        # We'll run dracut anyway, in case the user fixes it manually and re-runs
        needs_dracut=true
    else
        # No entry found for this UUID. It's safe to add one.
        echo "No entry found in /etc/crypttab. Adding new line."
        
        # We will use the 'luks-<uuid>' convention for the name.
        mapper_name="luks-$uuid"
        
        # Append the new, correct line to /etc/crypttab
        echo "$mapper_name  UUID=$uuid  none  tpm2-device=auto" | sudo tee -a /etc/crypttab
        
        echo "Successfully added new entry to /etc/crypttab."
        needs_dracut=true
    fi

    echo "-----------------------------------"
    echo ""
done

# --- 4. Rebuild initramfs (dracut) ---
if [ "$needs_dracut" = true ]; then
    echo "Changes were made to LUKS keys or /etc/crypttab."
    echo "Rebuilding initramfs (dracut)... This may take a moment."
    
    if sudo dracut --force; then
        echo "dracut rebuild complete."
        echo ""
        echo "All steps finished. Please reboot now to test automatic decryption."
    else
        echo ""
        echo "*****************************************************************"
        echo "DRACUT FAILED. Please check the output above. DO NOT REBOOT."
        echo "*****************************************************************"
    fi
else
    echo "All devices are already configured. No changes needed."
fi
