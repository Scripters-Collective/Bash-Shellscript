#!/bin/bash
#
#
# Collects comprehensive hardware and system information for RHEL 6-8 systems.
# Intended for weekly asset inventory on domain-connected RHEL hosts.
#
# NOTE: Samsung NVMe serial numbers may report inaccurately, mirroring the
#       same caveat documented in the original PowerShell version of this tool.
#
# REQUIRES: root privileges, dmidecode, lspci (pciutils), lsusb (usbutils)
#       required tools should be either native or part of RHEL OS repo
# OPTIONAL: smartctl (smartmontools) for enhanced disk serial/type detail

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

NETWORK_SHARE="/mnt/reports"    # TODO: Replace with actual NFS/CIFS mount path
HOSTNAME_SHORT=$(hostname -s)
REPORT_DATE=$(date +%Y-%m-%d)
FILENAME="${HOSTNAME_SHORT}_${REPORT_DATE}.txt"
OUTPUT_PATH="${NETWORK_SHARE}/${FILENAME}"
FALLBACK_PATH="/tmp/${FILENAME}"
SEP=$(printf '=%.0s' {1..80})
DASH=$(printf -- '-%.0s' {1..80})
TMP_REPORT=$(mktemp /tmp/sysinfo_XXXXXX.txt)

trap 'rm -f "$TMP_REPORT"' EXIT

rpt()      { printf '%s\n' "${1:-}" >> "$TMP_REPORT"; }
rpt_sep()  { rpt "$SEP"; }
rpt_dash() { rpt "$DASH"; }

# Extract a named field value from a block of dmidecode text.
# Usage: dmi_field "$block_text" "Field Name"
dmi_field() {
    printf '%s\n' "$1" | grep -E "^\s+${2}:" | head -1 | sed "s/^\s*${2}:\s*//"
}

# Pre-cache DMI Cache Entries (type 7) for L2/L3 size lookup
declare -A CACHE_MAP
_cur_handle=""
while IFS= read -r _line; do
    if [[ "$_line" =~ ^Handle[[:space:]]+(0x[[:xdigit:]]+) ]]; then
        _cur_handle="${BASH_REMATCH[1]}"
    elif [[ "$_line" =~ ^[[:space:]]+Installed[[:space:]]Size:[[:space:]]*(.+)$ && -n "$_cur_handle" ]]; then
        CACHE_MAP["$_cur_handle"]="${BASH_REMATCH[1]}"
    fi
done < <(dmidecode -t cache 2>/dev/null)

# Network Share Check
if [[ ! -d "$NETWORK_SHARE" ]]; then
    echo "ERROR: Cannot access network share: $NETWORK_SHARE"
    echo "Please verify the path exists and you have write permissions."
    exit 1
fi

echo "Output will be saved to: $OUTPUT_PATH"
echo ""
echo "Gathering hardware information... This may take a moment."
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# REPORT HEADER
# ═══════════════════════════════════════════════════════════════════════════════
rpt_sep
rpt "SYSTEM HARDWARE INFORMATION REPORT"
rpt "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
rpt "Computer Name: $(hostname)"
rpt_sep
rpt ""

# ═══════════════════════════════════════════════════════════════════════════════
# COMPUTER SYSTEM INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "COMPUTER SYSTEM INFORMATION"
rpt_dash

dmi_sys=$(dmidecode -t system 2>/dev/null)
ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
ram_gb=$(awk "BEGIN{printf \"%.2f\", $ram_kb/1048576}")
sys_domain=$(hostname -d 2>/dev/null || dnsdomainname 2>/dev/null || echo "(none)")

rpt "Manufacturer:        $(dmi_field "$dmi_sys" "Manufacturer")"
rpt "Model:               $(dmi_field "$dmi_sys" "Product Name")"
rpt "System Type:         $(uname -m)"
rpt "Domain:              ${sys_domain:-(none)}"
rpt "Total Physical RAM:  $ram_gb GB"
rpt ""

# ═══════════════════════════════════════════════════════════════════════════════
# BIOS INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "BIOS INFORMATION"
rpt_dash

dmi_bios=$(dmidecode -t bios 2>/dev/null)
rpt "Manufacturer:        $(dmi_field "$dmi_bios" "Vendor")"
rpt "Version:             $(dmi_field "$dmi_bios" "Version")"
rpt "Serial Number:       $(dmi_field "$dmi_sys" "Serial Number")"
rpt "Release Date:        $(dmi_field "$dmi_bios" "Release Date")"
rpt ""

# ═══════════════════════════════════════════════════════════════════════════════
# PROCESSOR INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "PROCESSOR INFORMATION"
rpt_dash

proc_num=0
_block=""
while IFS= read -r _line; do
    if [[ "$_line" =~ ^Handle ]]; then
        if [[ "$_block" == *"Processor Information"* ]]; then
            _status=$(dmi_field "$_block" "Status")
            _version=$(dmi_field "$_block" "Version")
            if [[ "$_status" != *"Unpopulated"* && -n "$_version" && "$_version" != "Not Specified" ]]; then
                ((proc_num++))
                _l2h=$(dmi_field "$_block" "L2 Cache Handle")
                _l3h=$(dmi_field "$_block" "L3 Cache Handle")
                rpt "Processor #$proc_num"
                rpt "  Name:               $_version"
                rpt "  Manufacturer:       $(dmi_field "$_block" "Manufacturer")"
                rpt "  Cores:              $(dmi_field "$_block" "Core Count")"
                rpt "  Logical Processors: $(dmi_field "$_block" "Thread Count")"
                rpt "  Max Clock Speed:    $(dmi_field "$_block" "Max Speed")"
                rpt "  Current Clock:      $(dmi_field "$_block" "Current Speed")"
                rpt "  Architecture:       $(uname -m)"
                rpt "  L2 Cache:           ${CACHE_MAP[$_l2h]:-N/A}"
                rpt "  L3 Cache:           ${CACHE_MAP[$_l3h]:-N/A}"
                rpt ""
            fi
        fi
        _block="$_line"
    else
        _block+=$'\n'"$_line"
    fi
done < <(dmidecode -t processor 2>/dev/null; echo "Handle _END_")

# ═══════════════════════════════════════════════════════════════════════════════
# MEMORY (RAM) INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "MEMORY (RAM) INFORMATION"
rpt_dash

mem_num=0
total_ram_installed=0
_block=""
while IFS= read -r _line; do
    if [[ "$_line" =~ ^Handle ]]; then
        if [[ "$_block" == *"Memory Device"* ]]; then
            _size=$(dmi_field "$_block" "Size")
            if [[ "$_size" != "No Module Installed" && -n "$_size" ]]; then
                ((mem_num++))
                if [[ "$_size" =~ ([0-9]+)[[:space:]]*(MB|GB) ]]; then
                    _num="${BASH_REMATCH[1]}"; _unit="${BASH_REMATCH[2]}"
                    if [[ "$_unit" == "MB" ]]; then
                        _slot_gb=$(awk "BEGIN{printf \"%.2f\", $_num/1024}")
                    else
                        _slot_gb=$_num
                    fi
                    total_ram_installed=$(awk "BEGIN{printf \"%.2f\", $total_ram_installed + $_slot_gb}")
                fi
                rpt "Memory Module #$mem_num"
                rpt "  Capacity:          $_size"
                rpt "  Speed:             $(dmi_field "$_block" "Speed")"
                rpt "  Manufacturer:      $(dmi_field "$_block" "Manufacturer")"
                rpt "  Part Number:       $(dmi_field "$_block" "Part Number")"
                rpt "  Serial Number:     $(dmi_field "$_block" "Serial Number")"
                rpt "  Device Locator:    $(dmi_field "$_block" "Locator")"
                rpt "  Bank Locator:      $(dmi_field "$_block" "Bank Locator")"
                rpt "  Memory Type:       $(dmi_field "$_block" "Type")"
                rpt ""
            fi
        fi
        _block="$_line"
    else
        _block+=$'\n'"$_line"
    fi
done < <(dmidecode -t memory 2>/dev/null; echo "Handle _END_")

rpt "Total Installed RAM: $total_ram_installed GB"
rpt ""

# ═══════════════════════════════════════════════════════════════════════════════
# MOTHERBOARD INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "MOTHERBOARD INFORMATION"
rpt_dash

dmi_mb=$(dmidecode -t baseboard 2>/dev/null)
rpt "Manufacturer:        $(dmi_field "$dmi_mb" "Manufacturer")"
rpt "Product:             $(dmi_field "$dmi_mb" "Product Name")"
rpt "Serial Number:       $(dmi_field "$dmi_mb" "Serial Number")"
rpt "Version:             $(dmi_field "$dmi_mb" "Version")"
rpt ""

# ═══════════════════════════════════════════════════════════════════════════════
# DISK DRIVE INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "DISK DRIVE INFORMATION"
rpt_dash

disk_num=0
while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    ((disk_num++))
    dev_path="/dev/$dev"
    dev_model=$(lsblk -nd -o MODEL "$dev_path" 2>/dev/null | xargs || echo "N/A")
    dev_size=$(lsblk -nd -o SIZE  "$dev_path" 2>/dev/null | xargs || echo "N/A")
    dev_tran=$(lsblk -nd -o TRAN  "$dev_path" 2>/dev/null | xargs || echo "N/A")
    dev_parts=$(lsblk -n "$dev_path" 2>/dev/null | grep -c "part" || echo "0")
    dev_serial="N/A"
    dev_media="N/A"

    _rota=$(cat "/sys/block/${dev}/queue/rotational" 2>/dev/null)
    [[ "$_rota" == "0" ]] && dev_media="SSD/NVMe"
    [[ "$_rota" == "1" ]] && dev_media="HDD (Rotational)"

    if command -v smartctl &>/dev/null; then
        _smart=$(smartctl -i "$dev_path" 2>/dev/null)
        _ser=$(printf '%s\n' "$_smart" | grep -Ei "^Serial (Number|number):" | head -1 | sed 's/^[^:]*:\s*//' | xargs)
        _rrate=$(printf '%s\n' "$_smart" | grep "^Rotation Rate:" | head -1 | sed 's/^[^:]*:\s*//')
        [[ -n "$_ser"   ]] && dev_serial="$_ser"
        [[ -n "$_rrate" ]] && dev_media="$_rrate"
    fi

    rpt "Disk #$disk_num"
    rpt "  Device:            $dev_path"
    rpt "  Model:             ${dev_model:-N/A}"
    rpt "  Interface Type:    ${dev_tran:-N/A}"
    rpt "  Size:              $dev_size"
    rpt "  Partitions:        $dev_parts"
    rpt "  Serial Number:     $dev_serial"
    rpt "  Media Type:        $dev_media"
    rpt ""
done < <(lsblk -nd -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

# ═══════════════════════════════════════════════════════════════════════════════
# LOGICAL DISK (PARTITION / FILESYSTEM) INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "LOGICAL DISK (PARTITION) INFORMATION"
rpt_dash

while read -r _dev _1k _used _avail _pct _mount; do
    [[ -z "$_dev" ]] && continue
    _size_gb=$(awk "BEGIN{printf \"%.2f\", $_1k/1048576}")
    _used_gb=$(awk "BEGIN{printf \"%.2f\", $_used/1048576}")
    _free_gb=$(awk "BEGIN{printf \"%.2f\", $_avail/1048576}")
    _fstype=$(df -T "$_mount" 2>/dev/null | tail -1 | awk '{print $2}')
    rpt "Mount: $_mount"
    rpt "  Device:            $_dev"
    rpt "  File System:       ${_fstype:-N/A}"
    rpt "  Total Size:        $_size_gb GB"
    rpt "  Used Space:        $_used_gb GB"
    rpt "  Free Space:        $_free_gb GB ($_pct used)"
    rpt ""
done < <(df -lkP 2>/dev/null | grep -v '^Filesystem\|tmpfs\|devtmpfs\|none\|udev\|proc\|sysfs\|cgroup')

# ═══════════════════════════════════════════════════════════════════════════════
# VIDEO CONTROLLER (GPU) INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "VIDEO CONTROLLER (GPU) INFORMATION"
rpt_dash

vid_num=0
while IFS= read -r _pci_addr; do
    [[ -z "$_pci_addr" ]] && continue
    ((vid_num++))
    _pci_detail=$(lspci -vvv -s "$_pci_addr" 2>/dev/null)
    _vid_name=$(lspci -s "$_pci_addr" 2>/dev/null | sed "s/^${_pci_addr} //")
    _sysfs_vid="/sys/bus/pci/devices/0000:${_pci_addr}"
    [[ ! -d "$_sysfs_vid" ]] && _sysfs_vid=$(ls -d /sys/bus/pci/devices/*:"${_pci_addr}" 2>/dev/null | head -1)

    _vid_driver="(none)"
    if [[ -L "${_sysfs_vid}/driver" ]]; then
        _vid_driver=$(basename "$(readlink "${_sysfs_vid}/driver")" 2>/dev/null)
    fi

    _vid_vram="N/A"
    _vram_line=$(printf '%s\n' "$_pci_detail" | grep -i "Memory.*prefetchable\|Memory.*64-bit" | head -1)
    if [[ "$_vram_line" =~ \[size=([0-9]+)([MG])\] ]]; then
        _vs="${BASH_REMATCH[1]}"; _vu="${BASH_REMATCH[2]}"
        [[ "$_vu" == "M" ]] && _vid_vram="${_vs} MB" || _vid_vram="${_vs} GB"
    fi

    _vid_irq=$(cat "${_sysfs_vid}/irq" 2>/dev/null || \
               printf '%s\n' "$_pci_detail" | grep "Interrupt:" | head -1 | awk '{print $2}')
    _vid_res=$(printf '%s\n' "$_pci_detail" | grep -E "^\s+(Memory|I/O) at" | sed 's/^\s*//')

    rpt "Video Controller #$vid_num"
    rpt "  PCI Address:       $_pci_addr"
    rpt "  Name:              ${_vid_name:-N/A}"
    rpt "  Driver:            $_vid_driver"
    rpt "  Video RAM:         $_vid_vram"
    rpt "  IRQ:               ${_vid_irq:-N/A}"
    while IFS= read -r _res; do
        [[ -n "$_res" ]] && rpt "  Resource:          $_res"
    done <<< "$_vid_res"
    rpt ""
done < <(lspci 2>/dev/null | grep -Ei "VGA|3D controller|Display controller" | awk '{print $1}')

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORK ADAPTER INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "NETWORK ADAPTER INFORMATION"
rpt_dash

net_num=0
for _iface_path in /sys/class/net/*/; do
    _iface=$(basename "$_iface_path")
    # Physical adapters have a 'device' symlink; skip virtual and loopback
    [[ ! -e "${_iface_path}device" || "$_iface" == "lo" ]] && continue
    ((net_num++))

    _mac=$(cat "${_iface_path}address" 2>/dev/null || echo "N/A")
    _speed=$(cat "${_iface_path}speed" 2>/dev/null || echo "N/A")
    [[ "$_speed" == "-1" || "$_speed" == "" ]] && _speed="Link down"
    _operstate=$(cat "${_iface_path}operstate" 2>/dev/null || echo "N/A")

    _iface_driver="N/A"
    if [[ -L "${_iface_path}device/driver" ]]; then
        _iface_driver=$(basename "$(readlink "${_iface_path}device/driver")" 2>/dev/null || echo "N/A")
    fi

    _iface_desc="N/A"
    _pci_vid=$(cat "${_iface_path}device/vendor" 2>/dev/null)
    _pci_did=$(cat "${_iface_path}device/device" 2>/dev/null)
    if [[ -n "$_pci_vid" && -n "$_pci_did" ]]; then
        _iface_desc=$(lspci -d "${_pci_vid#0x}:${_pci_did#0x}" 2>/dev/null | head -1 | sed 's/^[^:]*: //' || echo "N/A")
    fi

    rpt "Network Adapter #$net_num"
    rpt "  Interface:         $_iface"
    rpt "  Description:       ${_iface_desc:-N/A}"
    rpt "  Driver:            $_iface_driver"
    rpt "  MAC Address:       $_mac"
    rpt "  Speed:             ${_speed} Mbps"
    rpt "  State:             $_operstate"
    rpt ""
done

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORK CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "NETWORK CONFIGURATION"
rpt_dash

cfg_num=0
for _iface_path in /sys/class/net/*/; do
    _iface=$(basename "$_iface_path")
    [[ ! -e "${_iface_path}device" || "$_iface" == "lo" ]] && continue
    # Only include interfaces with an IPv4 address
    _has_ip=$(ip addr show "$_iface" 2>/dev/null | grep -c "^\s*inet\b" || echo 0)
    [[ "$_has_ip" -eq 0 ]] && continue
    ((cfg_num++))

    _ip4=$(ip addr show "$_iface" 2>/dev/null | awk '/inet /{print $2}' | paste -sd', ')
    _ip6=$(ip addr show "$_iface" 2>/dev/null | awk '/inet6 /{print $2}' | paste -sd', ')
    _gw=$(ip route show dev "$_iface" 2>/dev/null | awk '/^default/{print $3}' | head -1)
    _dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd', ')

    # DHCP detection — check dhclient lease files (RHEL 6/7) then nmcli (RHEL 7/8)
    _dhcp="No"
    _dhcp_server="N/A"
    for _lf in "/var/lib/dhclient/dhclient-${_iface}.leases" \
               "/var/lib/dhclient/dhclient.leases"; do
        if [[ -f "$_lf" ]] && grep -q "$_iface" "$_lf" 2>/dev/null; then
            _dhcp="Yes"
            _dhcp_server=$(grep "dhcp-server-identifier" "$_lf" 2>/dev/null | \
                           tail -1 | awk '{print $3}' | tr -d ';')
            break
        fi
    done
    if [[ "$_dhcp" == "No" ]] && command -v nmcli &>/dev/null; then
        _nm_conn=$(nmcli -g GENERAL.CONNECTION device show "$_iface" 2>/dev/null)
        if [[ -n "$_nm_conn" ]]; then
            _nm_method=$(nmcli -g ipv4.method connection show "$_nm_conn" 2>/dev/null)
            [[ "$_nm_method" == "auto" ]] && _dhcp="Yes"
        fi
    fi

    rpt "Network Configuration #$cfg_num"
    rpt "  Interface:         $_iface"
    rpt "  IPv4 Address:      ${_ip4:-N/A}"
    rpt "  IPv6 Address:      ${_ip6:-N/A}"
    rpt "  Default Gateway:   ${_gw:-N/A}"
    rpt "  DNS Servers:       ${_dns:-N/A}"
    rpt "  DHCP Enabled:      $_dhcp"
    if [[ "$_dhcp" == "Yes" ]]; then
        rpt "  DHCP Server:       ${_dhcp_server:-N/A}"
    fi
    rpt ""
done

# ═══════════════════════════════════════════════════════════════════════════════
# USB DEVICE INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "USB DEVICE INFORMATION"
rpt_dash

usb_num=0
while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    ((usb_num++))
    # lsusb format: Bus NNN Device NNN: ID xxxx:xxxx Description
    _usb_id=$(printf '%s\n' "$_line" | awk '{print $6}')
    _usb_desc=$(printf '%s\n' "$_line" | cut -d' ' -f7-)
    rpt "USB Device #$usb_num"
    rpt "  ID:                ${_usb_id:-N/A}"
    rpt "  Description:       ${_usb_desc:-N/A}"
    rpt ""
done < <(lsusb 2>/dev/null)

if [[ $usb_num -eq 0 ]]; then
    rpt "No USB devices detected."
    rpt ""
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PCI/PCIe DEVICE INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "PCI/PCIe DEVICE INFORMATION"
rpt_dash

pci_num=0
while IFS= read -r _pci_addr; do
    [[ -z "$_pci_addr" ]] && continue
    ((pci_num++))

    # Locate sysfs path 
    _sysfs="/sys/bus/pci/devices/0000:${_pci_addr}"
    [[ ! -d "$_sysfs" ]] && _sysfs=$(ls -d /sys/bus/pci/devices/*:"${_pci_addr}" 2>/dev/null | head -1)

    _pci_detail=$(lspci -vvv -s "$_pci_addr" 2>/dev/null)
    _pci_name=$(lspci -s "$_pci_addr" 2>/dev/null | sed "s/^${_pci_addr} //")
    _vendor_id=$(cat "${_sysfs}/vendor"           2>/dev/null || echo "N/A")
    _device_id=$(cat "${_sysfs}/device"           2>/dev/null || echo "N/A")
    _sub_vendor=$(cat "${_sysfs}/subsystem_vendor" 2>/dev/null || echo "N/A")
    _sub_device=$(cat "${_sysfs}/subsystem_device" 2>/dev/null || echo "N/A")
    _class=$(cat "${_sysfs}/class"                2>/dev/null || echo "N/A")
    _irq=$(cat "${_sysfs}/irq"                    2>/dev/null || echo "N/A")
    _enable=$(cat "${_sysfs}/enable"              2>/dev/null || echo "0")
    [[ "$_enable" == "1" ]] && _pci_status="Enabled" || _pci_status="Disabled"

    # Driver
    _driver="(none)"
    if [[ -L "${_sysfs}/driver" ]]; then
        _driver=$(basename "$(readlink "${_sysfs}/driver")" 2>/dev/null)
    fi

    # Driver module version
    _mod_ver="N/A"
    if [[ -L "${_sysfs}/driver/module" ]]; then
        _mod_name=$(basename "$(readlink "${_sysfs}/driver/module")" 2>/dev/null)
        _mod_ver=$(modinfo "$_mod_name" 2>/dev/null | awk '/^version:/{print $2}' | head -1)
        [[ -z "$_mod_ver" ]] && _mod_ver="${_mod_name} (version N/A)"
    fi

    # Hardware ID (vendor:device from lspci -n)
    _hw_id=$(lspci -n -s "$_pci_addr" 2>/dev/null | awk '{print $3}')

    # Capabilities summary from lspci -vvv
    _caps=$(printf '%s\n' "$_pci_detail" | grep -E "^\s+Capabilities:" | \
            sed 's/^\s*//' | paste -sd'; ')

    # Memory/IO resources from lspci -vvv
    _mem_io=$(printf '%s\n' "$_pci_detail" | grep -E "^\s+(Memory|I/O) at" | sed 's/^\s*//')

    # Resource BARs from sysfs resource file
    # Each entry is: start_addr end_addr flags
    _bar_info=""
    if [[ -f "${_sysfs}/resource" ]]; then
        _bar_idx=0
        while IFS=' ' read -r _rstart _rend _rflags; do
            if [[ "$_rstart" != "0x0000000000000000" || "$_rend" != "0x0000000000000000" ]]; then
                _rflags_dec=$(( 16#${_rflags#0x} ))
                if (( (_rflags_dec & 0x1) != 0 )); then
                    _rtype="I/O"
                elif (( (_rflags_dec & 0x200) != 0 )); then
                    _rtype="Memory (prefetchable)"
                else
                    _rtype="Memory"
                fi
                _bar_info+="  BAR${_bar_idx} Resource:    Type: $_rtype | ${_rstart}-${_rend}"$'\n'
            fi
            (( _bar_idx++ ))
            [[ $_bar_idx -ge 7 ]] && break
        done < "${_sysfs}/resource"
    fi

    rpt "PCI/PCIe Device #$pci_num"
    rpt "  Bus Address:       $_pci_addr"
    rpt "  Name:              ${_pci_name:-N/A}"
    rpt "  Vendor ID:         ${_vendor_id:-N/A}"
    rpt "  Device ID:         ${_device_id:-N/A}"
    rpt "  Hardware ID:       ${_hw_id:-N/A}"
    rpt "  Subsystem Vendor:  ${_sub_vendor:-N/A}"
    rpt "  Subsystem Device:  ${_sub_device:-N/A}"
    rpt "  Class:             ${_class:-N/A}"
    rpt "  Status:            $_pci_status"
    rpt "  IRQ:               ${_irq:-N/A}"
    rpt "  Driver:            $_driver"
    rpt "  Driver Version:    ${_mod_ver:-N/A}"
    if [[ -n "$_caps" ]]; then
        rpt "  Capabilities:      $_caps"
    fi
    if [[ -n "$_mem_io" ]]; then
        while IFS= read -r _res; do
            [[ -n "$_res" ]] && rpt "  Resource:          $_res"
        done <<< "$_mem_io"
    fi
    if [[ -n "$_bar_info" ]]; then
        printf '%s' "$_bar_info" >> "$TMP_REPORT"
    fi
    rpt ""
done < <(lspci 2>/dev/null | awk '{print $1}')

rpt "Total PCI/PCIe Devices: $pci_num"
rpt ""

# ═══════════════════════════════════════════════════════════════════════════════
# OPERATING SYSTEM INFORMATION
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "OPERATING SYSTEM INFORMATION"
rpt_dash

_os_name=$(cat /etc/redhat-release 2>/dev/null || \
           grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
_os_kernel=$(uname -r)
_os_arch=$(uname -m)
_last_boot=$(who -b 2>/dev/null | awk '{print $3, $4}')
_uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
_up_days=$(( _uptime_sec / 86400 ))
_up_hrs=$(( (_uptime_sec % 86400) / 3600 ))
_up_mins=$(( (_uptime_sec % 3600) / 60 ))

# Best-effort install date via RPM
_os_install=$(rpm -qi basesystem 2>/dev/null | \
              grep "^Install Date" | head -1 | sed 's/^[^:]*:\s*//')

rpt "OS Name:             ${_os_name:-N/A}"
rpt "Kernel Version:      $_os_kernel"
rpt "Architecture:        $_os_arch"
rpt "Install Date:        ${_os_install:-N/A}"
rpt "Last Boot Time:      ${_last_boot:-N/A}"
rpt "Uptime:              ${_up_days} days, ${_up_hrs} hours, ${_up_mins} minutes"
rpt ""

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM ENVIRONMENT VARIABLES
# ═══════════════════════════════════════════════════════════════════════════════
rpt_dash
rpt "SYSTEM ENVIRONMENT VARIABLES"
rpt_dash

while IFS= read -r _entry; do
    [[ -z "$_entry" ]] && continue
    _vname="${_entry%%=*}"
    _vval="${_entry#*=}"
    rpt "  $_vname"
    # Split PATH-style variables on ':' for readability (mirrors PS ';' split)
    if [[ "$_vval" == *":"* ]]; then
        IFS=':' read -ra _parts <<< "$_vval"
        for _part in "${_parts[@]}"; do
            [[ -n "$_part" ]] && rpt "    -> $_part"
        done
    else
        rpt "    -> $_vval"
    fi
    rpt ""
done < <(printenv | sort)

# ═══════════════════════════════════════════════════════════════════════════════
# REPORT FOOTER
# ═══════════════════════════════════════════════════════════════════════════════
rpt_sep
rpt "END OF REPORT"
rpt_sep

# ═══════════════════════════════════════════════════════════════════════════════
# WRITE OUTPUT — network share with local fallback
# ═══════════════════════════════════════════════════════════════════════════════
if cp "$TMP_REPORT" "$OUTPUT_PATH" 2>/dev/null; then
    echo ""
    echo "Hardware information successfully saved to: $OUTPUT_PATH"
else
    echo ""
    echo "Failed to write to network share: $NETWORK_SHARE"
    echo "Attempting to save locally to: $FALLBACK_PATH"
    if cp "$TMP_REPORT" "$FALLBACK_PATH" 2>/dev/null; then
        echo "Hardware information saved to fallback location: $FALLBACK_PATH"
    else
        echo "ERROR: Failed to write to fallback location: $FALLBACK_PATH" >&2
        exit 1
    fi
fi

echo ""
echo "Information gathered. Disregard any errors that may be present."
