#!/bin/bash

# =========================================================================
# LUKS Automatic Unlock Setup using Clevis and TPM2
# Author: Gemini (Google)
# Description: Installs Clevis/TPM2 dependencies and binds ALL LUKS volumes 
#              defined in /etc/crypttab to the local Trusted Platform Module 
#              (TPM) for secure, automatic, non-interactive decryption on RHEL 9.6.
#
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

# --- SCRIPT START ---

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (using sudo)."
    exit 1
fi

echo "--- Starting Clevis/TPM2 LUKS Binding Setup for ALL Volumes ---"

# 1. Check for crypttab
if [ ! -f "/etc/crypttab" ]; then
    echo "ERROR: /etc/crypttab not found. Cannot determine which devices to bind."
    exit 1
fi

# 2. Install required packages once
echo "Installing clevis, clevis-luks, and clevis-tpm2 packages..."
dnf install -y clevis clevis-luks clevis-tpm2

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to install required packages. Check your dnf configuration."
    exit 1
fi

# 3. Parse /etc/crypttab and process each LUKS device
# We look for lines that contain the 'luks' option and extract the device path.
# We also skip comment lines (starting with #) and empty lines.
grep -E '^[^#].*\bluks\b' /etc/crypttab | while read -r line; do
    
    # Read the second column (the device path) from the crypttab entry
    LUKS_DEVICE=$(echo "$line" | awk '{print $2}')
    MAPPED_NAME=$(echo "$line" | awk '{print $1}')

    if [ -z "$LUKS_DEVICE" ]; then
        echo "Skipping entry with empty device path: $line"
        continue
    fi

    echo ""
    echo "Processing LUKS Device: ${LUKS_DEVICE} (Mapped as: ${MAPPED_NAME})"

    # Check if the device node exists before binding
    if [ ! -b "$LUKS_DEVICE" ]; then
        echo "WARNING: Block device ${LUKS_DEVICE} not found. Skipping."
        continue
    fi

    # 4. Bind the LUKS volume to the TPM2
    echo "Binding LUKS device ${LUKS_DEVICE} to TPM2..."

    # This command adds a key to a new key slot. 
    # You will be prompted for the CURRENT LUKS PASSPHRASE for THIS specific device.
    # Note: If multiple devices use the same passphrase, you will enter it once per device.
    clevis luks bind -d ${LUKS_DEVICE} tpm2 '{"pcr_bank":"sha256","pcr_ids":"0,2,4,7"}'

    if [ $? -ne 0 ]; then
        echo "ERROR: Clevis binding failed for ${LUKS_DEVICE}. Ensure the TPM is enabled and the passphrase was correct."
        # Continue to the next device instead of exiting the whole script
    else
        echo "SUCCESS: ${LUKS_DEVICE} successfully bound to TPM2."
    fi

done

# 5. Regenerate initramfs to include the Clevis unlocking logic
echo ""
echo "Regenerating initramfs for all installed kernels to include clevis hooks..."
dracut -f --regenerate-all

if [ $? -ne 0 ]; then
    echo "WARNING: dracut failed to regenerate all images. Check the dracut output above for errors."
    # We continue to the end since some bindings might have worked
fi

echo ""
echo "======================================================================"
echo "--- Setup Complete for ALL LUKS Devices ---"
echo "======================================================================"
echo "Please reboot to test the automation. The system should now boot without"
echo "prompting for passwords for the devices that successfully bound."
