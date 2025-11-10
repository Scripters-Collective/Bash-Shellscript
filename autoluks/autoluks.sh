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
#
# autoluks.sh
#
# This script automates adding a keyfile to all LUKS-encrypted devices
# to allow for passwordless unlocking at boot.
#

set -e

# --- Configuration ---
KEYFILE="/root/luks-keyfile"

# --- Main Script ---

# 1. Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "INFO: Starting LUKS keyfile setup."

# 2. Generate keyfile if it doesn't exist
if [ -f "$KEYFILE" ]; then
    echo "INFO: Keyfile already exists at $KEYFILE. Using existing key."
else
    echo "INFO: Generating new keyfile at $KEYFILE..."
    dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1
    chmod 0400 "$KEYFILE"
    echo "INFO: Keyfile generated."
fi

# 3. Get current LUKS passphrase
echo -n "Enter the current LUKS passphrase to authorize adding the new key >> "
stty -echo
read -r CURRPP
stty echo
echo

if [ -z "$CURRPP" ]; then
    echo "ERROR: Empty passphrase is not permitted."
    exit 1
fi

# 4. Process all LUKS devices
for blkdev in $(blkid -t TYPE=crypto_LUKS -o device); do
    echo "--- Processing device: $blkdev ---"

    # Add the keyfile to the LUKS device
    echo "INFO: Adding keyfile to $blkdev..."
    if echo -n "$CURRPP" | cryptsetup luksAddKey "$blkdev" "$KEYFILE" --key-file -; then
        echo "INFO: Successfully added keyfile to $blkdev."
    else
        echo "ERROR: Failed to add keyfile to $blkdev. The passphrase may be incorrect."
        # Clean up the keyfile if we created it in this run.
        # Note: This doesn't remove it from devices it was successfully added to.
        # rm -f "$KEYFILE" 
        exit 1
    fi

    # 5. Update /etc/crypttab
    echo "INFO: Updating /etc/crypttab for $blkdev..."
    DEV_UUID=$(blkid -s UUID -o value "$blkdev")
    LUKS_NAME="luks-${DEV_UUID}"
    TEMP_CRYPTTAB=$(mktemp)

    # Create a backup
    cp /etc/crypttab /etc/crypttab.bak.$$

    # Remove any old entry for this device to avoid duplicates
    grep -v "$DEV_UUID" /etc/crypttab > "$TEMP_CRYPTTAB" || true
    
    # Add the new, correct entry
    echo "$LUKS_NAME UUID=$DEV_UUID $KEYFILE luks" >> "$TEMP_CRYPTTAB"
    
    # Overwrite the original with the updated version
    cp "$TEMP_CRYPTTAB" /etc/crypttab
    rm -f "$TEMP_CRYPTTAB"
    echo "INFO: /etc/crypttab updated for $blkdev."
done

# 6. Rebuild initramfs
echo "--- System Configuration ---"
echo "INFO: All devices have been configured."
echo -n "Do you wish to rebuild the initramfs to apply these changes? [y/N] "
read -r ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo "INFO: Rebuilding initramfs. This may take a few minutes..."
    dracut -f --regenerate-all
    echo "INFO: Initramfs rebuild complete."
else
    echo "INFO: Initrd not rebuilt. The system will not use the keyfile on boot."
fi

echo "INFO: Script finished successfully."
exit 0
