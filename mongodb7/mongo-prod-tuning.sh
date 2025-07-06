#!/bin/bash
# mongo-prod-tuning.sh - MongoDB system optimization script (RHEL/Centos/Rocky/Alma)

SCRIPT_VERSION="1.1"
CHANGELOG="1.1: Idempotency, versioning, logging, help, changelog.
1.0: Initial version."

LOGFILE="$(basename "$0" .sh).log"

# Write log with timestamp
log() {
    echo "[$(date '+%Y%m%d-%H:%M:%S')] $*" | tee -a "$LOGFILE"
}

show_help() {
    cat <<EOF
MongoDB system optimization script (RHEL/Centos/Rocky/Alma)
Version: $SCRIPT_VERSION

Usage: $0 [OPTIONS]

Options:
  -h, --help      Show this help and exit.

The script applies recommended system settings for MongoDB:
  1. Set open files limit to 64000.
  2. Set vm.swappiness to 1.
  3. Set net.ipv4.tcp_keepalive_time to 120.
  4. Disable NUMA zone reclaim.
  5. Enable Transparent HugePages for MongoDB 8+.
  6. Set I/O scheduler to 'deadline' for /var/lib/mongo disks.
  7. Warn if /var/lib/mongo is not on XFS or lacks 'noatime'.
  8. Enable and start chronyd NTP service.

Changelog:
$CHANGELOG

EOF
}

# Help argument
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

log "Starting MongoDB system tuning script v$SCRIPT_VERSION"

# 1. Set open files limit
LIMITS_FILE="/etc/security/limits.d/99-mongodb.conf"
if grep -q "^\* - nofile 64000" "$LIMITS_FILE" 2>/dev/null; then
    log "Open files limit already set in $LIMITS_FILE"
else
    echo "* - nofile 64000" > "$LIMITS_FILE"
    log "Set open files limit in $LIMITS_FILE"
fi

# 2. Set swappiness
if sysctl -n vm.swappiness | grep -q '^1$'; then
    log "vm.swappiness is already 0"
else
    sysctl -w vm.swappiness=0
    log "Set vm.swappiness=0"
fi
grep -q '^vm.swappiness=0' /etc/sysctl.conf || {
    echo "vm.swappiness=0" >> /etc/sysctl.conf
    log "Added vm.swappiness=0 to /etc/sysctl.conf"
}

# 3. TCP keepalive
if sysctl -n net.ipv4.tcp_keepalive_time | grep -q '^120$'; then
    log "net.ipv4.tcp_keepalive_time is already 120"
else
    sysctl -w net.ipv4.tcp_keepalive_time=120
    log "Set net.ipv4.tcp_keepalive_time=120"
fi
grep -q '^net.ipv4.tcp_keepalive_time=120' /etc/sysctl.conf || {
    echo "net.ipv4.tcp_keepalive_time=120" >> /etc/sysctl.conf
    log "Added net.ipv4.tcp_keepalive_time=120 to /etc/sysctl.conf"
}

# 4. NUMA: disable zone reclaim
if sysctl -n vm.zone_reclaim_mode | grep -q '^0$'; then
    log "vm.zone_reclaim_mode is already 0"
else
    sysctl -w vm.zone_reclaim_mode=0
    log "Set vm.zone_reclaim_mode=0"
fi
grep -q '^vm.zone_reclaim_mode=0' /etc/sysctl.conf || {
    echo "vm.zone_reclaim_mode=0" >> /etc/sysctl.conf
    log "Added vm.zone_reclaim_mode=0 to /etc/sysctl.conf"
}

# 5. Transparent HugePages (THP) for MongoDB 8+
THP_PATH="/sys/kernel/mm/transparent_hugepage/enabled"
if [ -f "$THP_PATH" ]; then
    if grep -q '\[always\]' "$THP_PATH"; then
        log "Transparent HugePages already set to always"
    else
        echo always > "$THP_PATH"
        log "Set Transparent HugePages to always"
    fi
else
    log "Transparent HugePages setting not available"
fi

# 6. I/O scheduler (deadline) for /var/lib/mongo disks
lsblk -ndo NAME,MOUNTPOINT | awk '$2=="/var/lib/mongo"{print $1}' | while read -r disk; do
    SCHED="/sys/block/$disk/queue/scheduler"
    if [ -w "$SCHED" ]; then
        if grep -q '\[deadline\]' "$SCHED"; then
            log "I/O scheduler for $disk already set to deadline"
        else
            echo deadline > "$SCHED"
            log "Set I/O scheduler for $disk to deadline"
        fi
    fi
done

# 7. Check XFS and noatime on /var/lib/mongo
FS=$(df -T /var/lib/mongo | awk 'NR==2{print $2}')
if [[ "$FS" != "xfs" ]]; then
    log "WARNING: Filesystem on /var/lib/mongo is $FS, not XFS"
fi
MOUNT_OPTS=$(findmnt -no OPTIONS /var/lib/mongo)
if [[ "$MOUNT_OPTS" != *noatime* ]]; then
    log "WARNING: 'noatime' is not set on /var/lib/mongo. Please add it to /etc/fstab"
fi

# 8. Enable and start chronyd
if systemctl is-enabled chronyd &>/dev/null; then
    log "chronyd is already enabled"
else
    yum install -y chrony &>>"$LOGFILE"
    systemctl enable --now chronyd
    log "Installed and started chronyd"
fi

log "MongoDB system configuration complete"
echo "System configuration for MongoDB complete."
echo "WARNING: Please reboot the server to apply some settings."
