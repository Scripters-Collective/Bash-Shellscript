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
#
#!/bin/bash

# This script finds all LUKS-encrypted volumes and enrolls them
# with the system's vTPM for automatic decryption on boot.
#
# It MUST be run as root (or with sudo) to work.

# --- Safety Check: Must be root ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  echo "Example: sudo ./enroll_luks_tpm.sh"
  exit 1
fi

echo "Scanning for all LUKS-encrypted devices..."
echo ""

# Find all devices with FSTYPE="crypto_LUKS" and get their full /dev/path
luks_devices=$(lsblk -o PATH,FSTYPE --noheadings | awk '$2 == "crypto_LUKS" {print $1}')

if [ -z "$luks_devices" ]; then
    echo "No LUKS devices found."
    exit 0
fi

# Loop through each found device
for device in $luks_devices; do
    echo "--- Processing $device ---"

    # Check if a TPM2 key is already enrolled in any slot
    if systemd-cryptenroll "$device" | grep -q 'tpm2'; then
        echo "TPM2 is already enrolled on $device. Skipping."
    else
        echo "No TPM2 enrollment found. Attempting to enroll $device..."
        echo ""
        echo "******************************************************************"
        echo "Please enter the CURRENT LUKS password for $device to authorize."
        echo "This password will NOT be saved. It is only used to add the TPM key."
        echo "******************************************************************"

        # Run the enrollment command.
        # This will interactively ask for the password for "$device".
        if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$device"; then
            echo ""
            echo "Successfully enrolled $device with TPM2."
        else
            echo ""
            echo "Failed to enroll $device. The password may have been incorrect."
            echo "You can re-run this script to try again."
        fi
    fi
    echo "-----------------------------------"
    echo ""
done

echo "All devices processed. Reboot to test automatic decryption."
