#!/bin/bash

# MongoDB Replication Configuration Script
VERSION="1.1.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${SCRIPT_NAME%.*}.log"

# Default values
KEYFILE_PATH="/opt/mongo-keyfile"
REPLICATION_NAME=""
KEYFILE_VALUE=""
KEYFILE_FROM_FILE=""
KEYFILE_FROM_URL=""

# Logging function
log_message() {
    local message="$1"
    local timestamp
    timestamp=$(date '+[%Y%m%d-%H:%M:%S]')
    echo "${timestamp} ${message}" | tee -a "${LOG_FILE}"
}

# Help function
show_help() {
    cat << EOF
MongoDB Replication Configuration Script - Version ${VERSION}

DESCRIPTION:
    This script configures MongoDB 7 replication by setting up the keyfile and replication parameters.

USAGE:
    ${SCRIPT_NAME} --replication-name <name> (--keyfile-value <value> | --keyfile-from-file <file> | --keyfile-from-url <url>) [OPTIONS]

REQUIRED ARGUMENTS:
    --replication-name      Name of the MongoDB replica set
    One of the following must be provided:
        --keyfile-value     Content to be written in the keyfile
        --keyfile-from-file Path to a file containing the keyfile value
        --keyfile-from-url  URL to retrieve the keyfile content

OPTIONAL ARGUMENTS:
    --keyfile-path          Path to the keyfile [default: /opt/mongo-keyfile]
    -h, --help              Show this help message

EXAMPLES:
    ${SCRIPT_NAME} --replication-name rs0 --keyfile-value "secret"
    ${SCRIPT_NAME} --replication-name rs0 --keyfile-from-file /tmp/keyfile.txt
    ${SCRIPT_NAME} --replication-name rs0 --keyfile-from-url http://repo.local/keyfile.txt

CHANGELOG:
    v1.1.0 - Added --keyfile-from-file and --keyfile-from-url (mutually exclusive)
    v1.0.0 - Initial version
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keyfile-value)
            KEYFILE_VALUE="$2"
            shift 2
            ;;
        --keyfile-from-file)
            KEYFILE_FROM_FILE="$2"
            shift 2
            ;;
        --keyfile-from-url)
            KEYFILE_FROM_URL="$2"
            shift 2
            ;;
        --replication-name)
            REPLICATION_NAME="$2"
            shift 2
            ;;
        --keyfile-path)
            KEYFILE_PATH="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate mutual exclusivity
used_sources=0
[[ -n "$KEYFILE_VALUE" ]] && ((used_sources++))
[[ -n "$KEYFILE_FROM_FILE" ]] && ((used_sources++))
[[ -n "$KEYFILE_FROM_URL" ]] && ((used_sources++))

if [[ $used_sources -ne 1 || -z "$REPLICATION_NAME" ]]; then
    echo "ERROR: You must provide exactly one of --keyfile-value, --keyfile-from-file, or --keyfile-from-url"
    show_help
    exit 1
fi

# Load keyfile content
if [[ -n "$KEYFILE_FROM_FILE" ]]; then
    if [[ -f "$KEYFILE_FROM_FILE" ]]; then
        KEYFILE_VALUE=$(<"$KEYFILE_FROM_FILE")
    else
        log_message "ERROR: File $KEYFILE_FROM_FILE does not exist"
        exit 1
    fi
elif [[ -n "$KEYFILE_FROM_URL" ]]; then
    if command -v curl >/dev/null 2>&1; then
        KEYFILE_VALUE=$(curl -fsSL "$KEYFILE_FROM_URL")
        if [[ $? -ne 0 || -z "$KEYFILE_VALUE" ]]; then
            log_message "ERROR: Failed to download keyfile from $KEYFILE_FROM_URL"
            exit 1
        fi
    else
        log_message "ERROR: curl is not installed"
        exit 1
    fi
fi

log_message "Starting MongoDB replication setup script v${VERSION}"

# Check and create keyfile
if [[ -f "$KEYFILE_PATH" ]]; then
    current_value=$(<"$KEYFILE_PATH")
    if [[ "$current_value" != "$KEYFILE_VALUE" ]]; then
        log_message "CRITICAL: Keyfile exists but content mismatch"
        exit 1
    fi
    log_message "Keyfile already exists and matches the provided value"
else
    echo "$KEYFILE_VALUE" > "$KEYFILE_PATH"
    chown mongod:mongod "$KEYFILE_PATH"
    chmod 600 "$KEYFILE_PATH"
    log_message "Keyfile created at $KEYFILE_PATH"
fi

# Apply SELinux context
semanage fcontext -a -t mongod_key_file_t "$KEYFILE_PATH"
restorecon -v "$KEYFILE_PATH"
log_message "SELinux context applied to keyfile"

# Update mongod.conf
CONF="/etc/mongod.conf"
backup="$CONF.backup.$(date +%Y%m%d-%H%M%S)"
cp "$CONF" "$backup"
log_message "Configuration file backed up to $backup"

grep -q "^security:" "$CONF" || echo -e "\nsecurity:" >> "$CONF"
grep -q "authorization:" "$CONF" || sed -i '/^security:/a\  authorization: "enabled"' "$CONF"
grep -q "keyFile:" "$CONF" || sed -i "/^security:/a\  keyFile: \"$KEYFILE_PATH\"" "$CONF"

if grep -q "^replication:" "$CONF"; then
    if grep -q "replSetName:" "$CONF"; then
        existing_repl=$(grep "replSetName:" "$CONF" | awk '{print $2}')
        if [[ "$existing_repl" != "$REPLICATION_NAME" ]]; then
            log_message "ERROR: replSetName mismatch: expected $REPLICATION_NAME, found $existing_repl"
            exit 1
        fi
    else
        sed -i "/^replication:/a\  replSetName: $REPLICATION_NAME" "$CONF"
    fi
else
    echo -e "\nreplication:\n  replSetName: $REPLICATION_NAME" >> "$CONF"
fi
log_message "Replication configuration verified"

for dir in /var/lib/mongo /var/log/mongodb; do
    owner=$(stat -c "%U:%G" "$dir")
    if [[ "$owner" != "mongod:mongod" ]]; then
        chown -R mongod:mongod "$dir"
        log_message "Ownership corrected for $dir"
    else
        log_message "Ownership verified for $dir"
    fi
done

systemctl enable mongod
systemctl restart mongod
log_message "MongoDB service restarted, waiting 10 seconds"
for i in {1..10}; do
    echo -ne "$i\033[0K\r"
    sleep 1
done

systemctl is-active --quiet mongod
if [[ $? -eq 0 ]]; then
    log_message "MongoDB is running"
else
    log_message "ERROR: MongoDB failed to start"
    exit 1
fi

log_message "MongoDB replication configuration completed"
exit 0
