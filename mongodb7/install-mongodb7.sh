#!/bin/bash

# MongoDB 7.0 Installation Script
VERSION="1.3.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${SCRIPT_NAME%.*}.log"

# Default values
PROTOCOL="http"
REPO_HOSTNAME=""
REPO_PATH="mongodb7"

# Logging function
log_message() {
    local message="$1"
    local timestamp=$(date '+[%Y%m%d-%H:%M:%S]')
    echo "${timestamp} ${message}" | tee -a "${LOG_FILE}"
}

# Help function
show_help() {
    cat << EOF
MongoDB 7.0 Installation Script - Version ${VERSION}

DESCRIPTION:
    This script installs and configures MongoDB 7.0 on RHEL 9 systems
    from a custom repository server.

USAGE:
    ${SCRIPT_NAME} --repo-hostname <hostname> [OPTIONS]

REQUIRED ARGUMENTS:
    --repo-hostname     Repository server IP address or hostname

OPTIONAL ARGUMENTS:
    --protocol          Protocol to use (http|https) [default: http]
    --repo-path         Repository path [default: mongodb7]
    -h, --help          Show this help message

EXAMPLES:
    ${SCRIPT_NAME} --repo-hostname 172.20.2.109
    ${SCRIPT_NAME} --repo-hostname repo.example.com --protocol https
    ${SCRIPT_NAME} --repo-hostname 172.20.2.109 --repo-path custom-mongodb

CHANGELOG:
    v1.3.0 - Added network binding configuration (bindIpAll: true) and firewall rules for port 27017
    v1.2.0 - Fixed repository URL path to include 'repos' directory
    v1.1.0 - Enhanced mount point validation to check fstab entries and actual mount status
    v1.0.0 - Initial version
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --protocol)
            PROTOCOL="$2"
            shift 2
            ;;
        --repo-hostname)
            REPO_HOSTNAME="$2"
            shift 2
            ;;
        --repo-path)
            REPO_PATH="$2"
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

# Validate required arguments
if [[ -z "${REPO_HOSTNAME}" ]]; then
    echo "Error: --repo-hostname is required"
    show_help
    exit 1
fi

# Validate protocol
if [[ "${PROTOCOL}" != "http" && "${PROTOCOL}" != "https" ]]; then
    echo "Error: --protocol must be http or https"
    exit 1
fi

# Start logging
log_message "Starting MongoDB 7.0 installation script v${VERSION}"
log_message "Configuration: ${PROTOCOL}://${REPO_HOSTNAME}/${REPO_PATH}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_message "ERROR: This script must be run as root"
    exit 1
fi

log_message "Root check: OK"

# Check required mount points
log_message "Checking required mount points in fstab"

if ! grep -q "^[^#]*[[:space:]]/var/lib/mongo[[:space:]]" /etc/fstab; then
    log_message "ERROR: Mount point /var/lib/mongo not found in /etc/fstab"
    exit 1
fi

if ! grep -q "^[^#]*[[:space:]]/var/log/mongodb[[:space:]]" /etc/fstab; then
    log_message "ERROR: Mount point /var/log/mongodb not found in /etc/fstab"
    exit 1
fi

# Verify mount points are actually mounted
if ! mountpoint -q /var/lib/mongo; then
    log_message "ERROR: /var/lib/mongo is not mounted"
    exit 1
fi

if ! mountpoint -q /var/log/mongodb; then
    log_message "ERROR: /var/log/mongodb is not mounted"
    exit 1
fi

log_message "Mount points check: OK"

# Create MongoDB repository file
REPO_FILE="/etc/yum.repos.d/mongodb-org-7.0.repo"
log_message "Creating repository file: ${REPO_FILE}"

cat > "${REPO_FILE}" << EOF
[mongodb-org-7.0]
name=MongoDB Community 7.0 local repo
baseurl=${PROTOCOL}://${REPO_HOSTNAME}/repos/${REPO_PATH}/
enabled=1
gpgcheck=1
gpgkey=${PROTOCOL}://${REPO_HOSTNAME}/repos/${REPO_PATH}/server-7.0.asc
EOF

if [[ $? -eq 0 ]]; then
    log_message "Repository file created successfully"
else
    log_message "ERROR: Failed to create repository file"
    exit 1
fi

# Clean DNF cache
log_message "Cleaning DNF cache"
dnf clean all
if [[ $? -eq 0 ]]; then
    log_message "DNF cache cleaned successfully"
else
    log_message "ERROR: Failed to clean DNF cache"
    exit 1
fi

# List repositories
log_message "Listing repositories"
dnf repolist
if [[ $? -eq 0 ]]; then
    log_message "Repository list retrieved successfully"
else
    log_message "ERROR: Failed to list repositories"
    exit 1
fi

# Install MongoDB
log_message "Installing MongoDB packages"
dnf install -y mongodb-org
if [[ $? -eq 0 ]]; then
    log_message "MongoDB packages installed successfully"
else
    log_message "ERROR: Failed to install MongoDB packages"
    exit 1
fi

# Add SELinux contexts
log_message "Adding SELinux contexts"
semanage fcontext -a -t mongod_var_lib_t "/var/lib/mongo(/.*)?"
if [[ $? -eq 0 ]]; then
    log_message "SELinux context for /var/lib/mongo added successfully"
else
    log_message "ERROR: Failed to add SELinux context for /var/lib/mongo"
    exit 1
fi

semanage fcontext -a -t mongod_log_t "/var/log/mongodb(/.*)?"
if [[ $? -eq 0 ]]; then
    log_message "SELinux context for /var/log/mongodb added successfully"
else
    log_message "ERROR: Failed to add SELinux context for /var/log/mongodb"
    exit 1
fi

# Restore SELinux contexts
log_message "Restoring SELinux contexts"
restorecon -Rv /var/lib/mongo /var/log/mongodb
if [[ $? -eq 0 ]]; then
    log_message "SELinux contexts restored successfully"
else
    log_message "ERROR: Failed to restore SELinux contexts"
    exit 1
fi

# Backup configuration file
MONGOD_CONF="/etc/mongod.conf"
BACKUP_CONF="${MONGOD_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
log_message "Backing up configuration file to ${BACKUP_CONF}"
cp "${MONGOD_CONF}" "${BACKUP_CONF}"
if [[ $? -eq 0 ]]; then
    log_message "Configuration file backed up successfully"
else
    log_message "ERROR: Failed to backup configuration file"
    exit 1
fi

# Enable authentication in configuration
log_message "Enabling authentication in MongoDB configuration"
if grep -q "^security:" "${MONGOD_CONF}"; then
    sed -i '/^security:/,/^[^[:space:]]/ { /authorization:/ s/.*/  authorization: "enabled"/ }' "${MONGOD_CONF}"
else
    echo -e "\nsecurity:\n  authorization: \"enabled\"" >> "${MONGOD_CONF}"
fi

if [[ $? -eq 0 ]]; then
    log_message "Authentication enabled in configuration"
else
    log_message "ERROR: Failed to enable authentication in configuration"
    exit 1
fi

# Configure network binding
log_message "Configuring network binding to accept all connections"
if grep -q "^[[:space:]]*bindIp:" "${MONGOD_CONF}"; then
    sed -i '/^[[:space:]]*bindIp:/c\  bindIpAll: true' "${MONGOD_CONF}"
elif grep -q "^net:" "${MONGOD_CONF}"; then
    sed -i '/^net:/a\  bindIpAll: true' "${MONGOD_CONF}"
else
    echo -e "\nnet:\n  bindIpAll: true" >> "${MONGOD_CONF}"
fi

if [[ $? -eq 0 ]]; then
    log_message "Network binding configured successfully"
else
    log_message "ERROR: Failed to configure network binding"
    exit 1
fi

# Configure firewall for MongoDB port
log_message "Configuring firewall for MongoDB port 27017"
firewall-cmd --permanent --add-port=27017/tcp
if [[ $? -eq 0 ]]; then
    log_message "Firewall rule added for port 27017"
else
    log_message "ERROR: Failed to add firewall rule for port 27017"
    exit 1
fi

firewall-cmd --reload
if [[ $? -eq 0 ]]; then
    log_message "Firewall rules reloaded successfully"
else
    log_message "ERROR: Failed to reload firewall rules"
    exit 1
fi

# Start and enable MongoDB service
log_message "Starting MongoDB service"
systemctl start mongod
if [[ $? -eq 0 ]]; then
    log_message "MongoDB service started successfully"
else
    log_message "ERROR: Failed to start MongoDB service"
    exit 1
fi

# Wait for service to be ready
log_message "Waiting 5 seconds for MongoDB to initialize"
sleep 5

# Check if MongoDB is running
log_message "Checking MongoDB service status"
systemctl is-active --quiet mongod
if [[ $? -eq 0 ]]; then
    log_message "MongoDB service is running"
else
    log_message "ERROR: MongoDB service is not running"
    exit 1
fi

# Enable MongoDB service for automatic startup
log_message "Enabling MongoDB service for automatic startup"
systemctl enable mongod
if [[ $? -eq 0 ]]; then
    log_message "MongoDB service enabled for automatic startup"
else
    log_message "ERROR: Failed to enable MongoDB service for automatic startup"
    exit 1
fi

log_message "MongoDB 7.0 installation completed successfully"
exit 0
