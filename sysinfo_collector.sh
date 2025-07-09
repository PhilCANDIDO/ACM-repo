#!/bin/bash
################################################################################
# Script: sysinfo_collector.sh
# Version: 1.0.1
# Description: Simple script to collect Linux system information
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-09
#
# Compatible: RHEL/CentOS, Debian/Ubuntu
# Environment: Production/Test Linux servers
#
# CHANGELOG:
# v1.0.1 - Fix RAM calculation rounding and disk size detection using lsblk -b
# v1.0.0 - Initial version with OS, CPU, RAM, DISK, IP collection
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_VERSION="1.0.1"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/sysinfo-collector-$(date +%Y%m%d-%H%M%S).log"

# === VARIABLES GLOBALES ===
OUTPUT_FORMAT="table"
SAVE_TO_FILE="false"
OUTPUT_FILE=""
VERBOSE="false"

# === LOGGING FUNCTION ===
log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    fi
}

# === HELP FUNCTION ===
show_help() {
    cat << EOF
System Information Collector Script v${SCRIPT_VERSION}

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

DESCRIPTION:
    Collect basic system information from Linux servers (RHEL/Debian compatible)
    Information collected: OS, CPU, RAM, DISK, IP

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show script version
    -f, --format FORMAT     Output format: table|json|csv (default: table)
    -o, --output FILE       Save output to file
    -V, --verbose           Enable verbose logging
    --hostname              Include hostname in output

EXAMPLES:
    ${SCRIPT_NAME}                          # Basic table output
    ${SCRIPT_NAME} -f json                  # JSON format output
    ${SCRIPT_NAME} -o server_info.txt       # Save to file
    ${SCRIPT_NAME} -f csv -o inventory.csv  # CSV format to file
    ${SCRIPT_NAME} --verbose                # Enable verbose mode

NOTES:
    - Compatible with RHEL/CentOS and Debian/Ubuntu
    - Requires standard Linux commands (no additional packages)
    - Log file: ${LOG_FILE}

EOF
}

# === SYSTEM INFORMATION FUNCTIONS ===

# Detect OS Distribution and Version
get_os_info() {
    local os_info=""
    
    if [[ -f /etc/redhat-release ]]; then
        os_info=$(cat /etc/redhat-release)
    elif [[ -f /etc/debian_version ]]; then
        if [[ -f /etc/os-release ]]; then
            os_info=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
        else
            os_info="Debian $(cat /etc/debian_version)"
        fi
    elif [[ -f /etc/os-release ]]; then
        os_info=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    else
        os_info="Unknown Linux Distribution"
    fi
    
    echo "$os_info"
}

# Get CPU Information
get_cpu_info() {
    local cpu_count=""
    local cpu_model=""
    
    # Get CPU count
    cpu_count=$(nproc)
    
    # Get CPU model (first CPU only for brevity)
    if [[ -f /proc/cpuinfo ]]; then
        cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^ *//')
        if [[ -z "$cpu_model" ]]; then
            cpu_model=$(grep "cpu model" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^ *//')
        fi
    fi
    
    if [[ -z "$cpu_model" ]]; then
        cpu_model="Unknown CPU Model"
    fi
    
    echo "${cpu_count} cores (${cpu_model})"
}

# Get RAM Information
get_ram_info() {
    local ram_total_kb=""
    local ram_total_gb=""
    
    if [[ -f /proc/meminfo ]]; then
        ram_total_kb=$(grep "MemTotal" /proc/meminfo | awk '{print $2}')
        
        # Calculate GB with proper rounding
        if command -v bc &> /dev/null; then
            ram_total_gb=$(echo "scale=1; ($ram_total_kb / 1024 / 1024) + 0.05" | bc | cut -d. -f1)
        else
            # Fallback without bc: add 512MB for rounding before division
            ram_total_gb=$(( (ram_total_kb + 524288) / 1024 / 1024 ))
        fi
    else
        ram_total_gb="Unknown"
    fi
    
    echo "${ram_total_gb} GB"
}

# Get Disk Information
get_disk_info() {
    local disk_count=0
    local total_size_gb=0
    local disk_info=""
    
    # Method 1: Use lsblk for better disk detection
    if command -v lsblk &> /dev/null; then
        # Get disk information from lsblk
        local disk_data=""
        disk_data=$(lsblk -d -n -b -o NAME,TYPE,SIZE 2>/dev/null | grep -E "disk|nvme" || true)
        
        if [[ -n "$disk_data" ]]; then
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    ((disk_count++))
                    # Extract size in bytes (third column)
                    local size_bytes=$(echo "$line" | awk '{print $3}')
                    if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
                        # Convert bytes to GB
                        local size_gb_calc=""
                        if command -v bc &> /dev/null; then
                            size_gb_calc=$(echo "scale=1; $size_bytes / 1024 / 1024 / 1024" | bc)
                        else
                            size_gb_calc=$(( size_bytes / 1024 / 1024 / 1024 ))
                        fi
                        
                        if command -v bc &> /dev/null; then
                            total_size_gb=$(echo "scale=1; $total_size_gb + $size_gb_calc" | bc)
                        else
                            total_size_gb=$(( total_size_gb + size_gb_calc ))
                        fi
                    fi
                fi
            done <<< "$disk_data"
        fi
    fi
    
    # Method 2: Fallback - count physical devices
    if [[ "$disk_count" -eq 0 ]]; then
        for disk in /dev/sd[a-z] /dev/hd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
            if [[ -b "$disk" ]]; then
                ((disk_count++))
                # Try to get size from /sys/block
                local disk_name=$(basename "$disk")
                local size_file="/sys/block/$disk_name/size"
                if [[ -f "$size_file" ]]; then
                    local size_sectors=$(cat "$size_file" 2>/dev/null || echo "0")
                    if [[ "$size_sectors" =~ ^[0-9]+$ ]] && [[ "$size_sectors" -gt 0 ]]; then
                        # Convert sectors to GB (sector = 512 bytes)
                        local size_gb_calc=""
                        if command -v bc &> /dev/null; then
                            size_gb_calc=$(echo "scale=1; $size_sectors * 512 / 1024 / 1024 / 1024" | bc)
                            total_size_gb=$(echo "scale=1; $total_size_gb + $size_gb_calc" | bc)
                        else
                            size_gb_calc=$(( size_sectors * 512 / 1024 / 1024 / 1024 ))
                            total_size_gb=$(( total_size_gb + size_gb_calc ))
                        fi
                    fi
                fi
            fi
        done
    fi
    
    # Format output
    if [[ "$disk_count" -gt 0 ]]; then
        if command -v bc &> /dev/null; then
            # Round to 1 decimal place
            local total_rounded=$(echo "scale=1; $total_size_gb + 0.05" | bc | sed 's/\.0$//')
        else
            local total_rounded="$total_size_gb"
        fi
        
        if [[ "$total_rounded" == "0" ]] || [[ -z "$total_rounded" ]]; then
            echo "${disk_count} disks (size detection failed)"
        else
            echo "${disk_count} disks (${total_rounded} GB total)"
        fi
    else
        echo "No disks detected"
    fi
}

# Get Primary IP Address
get_ip_info() {
    local primary_ip=""
    
    # Try multiple methods to get the primary IP
    # Method 1: ip route (preferred)
    if command -v ip &> /dev/null; then
        primary_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    fi
    
    # Method 2: hostname command
    if [[ -z "$primary_ip" ]] && command -v hostname &> /dev/null; then
        primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # Method 3: ifconfig fallback
    if [[ -z "$primary_ip" ]] && command -v ifconfig &> /dev/null; then
        primary_ip=$(ifconfig 2>/dev/null | grep -oP 'inet \K[0-9.]+' | grep -v "127.0.0.1" | head -1)
    fi
    
    # Method 4: /proc/net/route fallback
    if [[ -z "$primary_ip" ]] && [[ -f /proc/net/route ]]; then
        local default_iface=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
        if [[ -n "$default_iface" ]] && [[ -f "/sys/class/net/$default_iface/address" ]]; then
            primary_ip=$(ip addr show "$default_iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
        fi
    fi
    
    if [[ -z "$primary_ip" ]]; then
        primary_ip="Unknown"
    fi
    
    echo "$primary_ip"
}

# === OUTPUT FUNCTIONS ===

# Format output as table
output_table() {
    local hostname_info=""
    if [[ "$INCLUDE_HOSTNAME" == "true" ]]; then
        hostname_info="$(hostname)"
    fi
    
    echo "========================================"
    echo "       SYSTEM INFORMATION REPORT"
    echo "========================================"
    echo "Date/Time    : $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -n "$hostname_info" ]]; then
        echo "Hostname     : $hostname_info"
    fi
    echo "OS           : $OS_INFO"
    echo "CPU          : $CPU_INFO"
    echo "RAM          : $RAM_INFO"
    echo "DISK         : $DISK_INFO"
    echo "Primary IP   : $IP_INFO"
    echo "========================================"
}

# Format output as JSON
output_json() {
    local hostname_json=""
    if [[ "$INCLUDE_HOSTNAME" == "true" ]]; then
        hostname_json="\"hostname\": \"$(hostname)\","
    fi
    
    cat << EOF
{
  "system_info": {
    "collection_date": "$(date '+%Y-%m-%d %H:%M:%S')",
    ${hostname_json}
    "os": "$OS_INFO",
    "cpu": "$CPU_INFO",
    "ram": "$RAM_INFO",
    "disk": "$DISK_INFO",
    "primary_ip": "$IP_INFO"
  }
}
EOF
}

# Format output as CSV
output_csv() {
    local hostname_csv=""
    if [[ "$INCLUDE_HOSTNAME" == "true" ]]; then
        hostname_csv="$(hostname),"
    fi
    
    if [[ "$SAVE_TO_FILE" == "true" ]] && [[ ! -f "$OUTPUT_FILE" ]]; then
        # Write CSV header
        if [[ "$INCLUDE_HOSTNAME" == "true" ]]; then
            echo "Date,Hostname,OS,CPU,RAM,DISK,IP" > "$OUTPUT_FILE"
        else
            echo "Date,OS,CPU,RAM,DISK,IP" > "$OUTPUT_FILE"
        fi
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${hostname_csv}\"$OS_INFO\",\"$CPU_INFO\",\"$RAM_INFO\",\"$DISK_INFO\",\"$IP_INFO\""
}

# === MAIN COLLECTION FUNCTION ===
collect_system_info() {
    log "Starting system information collection..."
    
    # Collect all information
    OS_INFO=$(get_os_info)
    CPU_INFO=$(get_cpu_info)
    RAM_INFO=$(get_ram_info)
    DISK_INFO=$(get_disk_info)
    IP_INFO=$(get_ip_info)
    
    log "System information collected successfully"
    
    # Generate output based on format
    local output=""
    case "$OUTPUT_FORMAT" in
        "table")
            output=$(output_table)
            ;;
        "json")
            output=$(output_json)
            ;;
        "csv")
            output=$(output_csv)
            ;;
        *)
            log "ERROR: Unknown output format: $OUTPUT_FORMAT"
            exit 1
            ;;
    esac
    
    # Display or save output
    if [[ "$SAVE_TO_FILE" == "true" ]]; then
        if [[ "$OUTPUT_FORMAT" == "csv" ]]; then
            # For CSV, append to file
            echo "$output" >> "$OUTPUT_FILE"
            echo "System information saved to: $OUTPUT_FILE"
        else
            # For other formats, write to file
            echo "$output" > "$OUTPUT_FILE"
            echo "System information saved to: $OUTPUT_FILE"
        fi
        log "Output saved to file: $OUTPUT_FILE"
    else
        echo "$output"
    fi
}

# === COMMAND LINE PARSING ===
INCLUDE_HOSTNAME="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "System Information Collector v${SCRIPT_VERSION}"
            exit 0
            ;;
        -f|--format)
            OUTPUT_FORMAT="$2"
            if [[ ! "$OUTPUT_FORMAT" =~ ^(table|json|csv)$ ]]; then
                echo "ERROR: Invalid format. Supported: table, json, csv" >&2
                exit 1
            fi
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            SAVE_TO_FILE="true"
            shift 2
            ;;
        -V|--verbose)
            VERBOSE="true"
            shift
            ;;
        --hostname)
            INCLUDE_HOSTNAME="true"
            shift
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# === MAIN EXECUTION ===
main() {
    log "System Information Collector v${SCRIPT_VERSION} started"
    log "Parameters: Format=$OUTPUT_FORMAT, SaveFile=$SAVE_TO_FILE, Verbose=$VERBOSE"
    
    # Check if bc is available for calculations
    if ! command -v bc &> /dev/null; then
        log "WARNING: 'bc' command not found. RAM calculations may be less precise"
    fi
    
    # Collect and display system information
    collect_system_info
    
    log "System Information Collector completed successfully"
}

# Execute main function
main "$@"