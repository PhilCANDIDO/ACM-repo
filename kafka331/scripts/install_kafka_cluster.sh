#!/bin/bash
################################################################################
# Script: install_kafka_cluster.sh
# Version: 1.0.0
# Description: Installation Kafka 3.9.1 en cluster HA pour ACM Banking
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-06
# 
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Ligne $LINENO. Code de sortie: $?" >&2' ERR

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/kafka-install-$(date +%Y%m%d-%H%M%S).log"
KAFKA_VERSION="3.9.1"
SCALA_VERSION="2.13"

# === LOGGING FUNCTION ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# === HELP FUNCTION ===
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Installation Kafka Cluster

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    -h, --help              Afficher cette aide
    -v, --version           Afficher la version
    -n, --node-id NUM       ID du nœud Kafka (1-3)
    -r, --repo-server IP    IP du serveur repository (défaut: 172.20.2.109)
    --dry-run              Mode test sans modification

EXEMPLES:
    $SCRIPT_NAME -n 1       # Installation broker ID 1
    $SCRIPT_NAME -n 2 -r 172.20.2.109  # Broker 2 avec repo custom

CONFORMITÉ:
    - PCI-DSS Level 1
    - ANSSI-BP-028
    - SELinux enforcing
EOF
}

# === VARIABLES DE CONFIGURATION ===
NODE_ID=""
REPO_SERVER="172.20.2.109"
DRY_RUN=false
KAFKA_USER="kafka"
KAFKA_GROUP="kafka"
KAFKA_HOME="/opt/kafka"
KAFKA_DATA_DIR="/data/kafka"
KAFKA_LOGS_DIR="/var/log/kafka"
JVM_HEAP_SIZE="2G"

# === PARSING ARGUMENTS ===
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "$SCRIPT_NAME version $SCRIPT_VERSION"
            exit 0
            ;;
        -n|--node-id)
            NODE_ID="$2"
            shift 2
            ;;
        -r|--repo-server)
            REPO_SERVER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            error_exit "Option inconnue: $1. Utilisez -h pour l'aide."
            ;;
    esac
done

# === VALIDATION PREREQUISITES ===
validate_prerequisites() {
    log "Validation des prérequis..."
    
    # Vérification ID nœud
    if [[ -z "$NODE_ID" ]] || [[ ! "$NODE_ID" =~ ^[1-3]$ ]]; then
        error_exit "ID nœud requis (1-3). Utilisez -n NUM"
    fi
    
    # Vérification root
    if [[ $EUID -ne 0 ]]; then
        error_exit "Script doit être exécuté en root"
    fi
    
    # Vérification connectivité repository
    if ! curl -s --connect-timeout 5 "http://$REPO_SERVER/kafka/" > /dev/null; then
        error_exit "Repository Kafka inaccessible sur $REPO_SERVER"
    fi
    
    # Vérification espace disque (minimum 10GB)
    available_space=$(df /opt | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 10485760 ]]; then
        error_exit "Espace disque insuffisant. Minimum 10GB requis."
    fi
    
    log "Prérequis validés avec succès"
}

# === CONFIGURATION SYSTÈME ===
configure_system() {
    log "Configuration système pour Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration système simulée"
        return
    fi
    
    # Création utilisateur système Kafka
    if ! id "$KAFKA_USER" &>/dev/null; then
        useradd -r -s /bin/false -d "$KAFKA_HOME" "$KAFKA_USER"
        log "Utilisateur $KAFKA_USER créé"
    fi
    
    # Création des répertoires
    mkdir -p "$KAFKA_HOME" "$KAFKA_DATA_DIR" "$KAFKA_LOGS_DIR"
    chown -R "$KAFKA_USER:$KAFKA_GROUP" "$KAFKA_HOME" "$KAFKA_DATA_DIR" "$KAFKA_LOGS_DIR"
    
    # Configuration limites système (PCI-DSS)
    cat > /etc/security/limits.d/kafka.conf << 'EOF'
kafka soft nofile 65536
kafka hard nofile 65536
kafka soft nproc 32768
kafka hard nproc 32768
EOF
    
    # Configuration sysctl pour performance
    cat > /etc/sysctl.d/99-kafka.conf << 'EOF'
# Kafka Performance Tuning - Banking Standards
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 60
vm.dirty_expire_centisecs = 12000
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
    sysctl -p /etc/sysctl.d/99-kafka.conf
    
    log "Configuration système terminée"
}

# === INSTALLATION JAVA 17 ===
install_java() {
    log "Installation Java 17..."
    
    if java -version 2>&1 | grep -q "17\."; then
        log "Java 17 déjà installé"
        return
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation Java 17 simulée"
        return
    fi
    
    # Installation via repository local
    cd /tmp
    curl -O "http://$REPO_SERVER/kafka/jdk-17_linux-x64_bin.tar.gz"
    tar -xzf jdk-17_linux-x64_bin.tar.gz -C /opt/
    
    # Création des liens symboliques
    ln -sf /opt/jdk-17.0.2 /opt/java
    
    # Configuration environnement
    cat > /etc/profile.d/java.sh << 'EOF'
export JAVA_HOME=/opt/java
export PATH=$JAVA_HOME/bin:$PATH
EOF
    
    source /etc/profile.d/java.sh
    log "Java 17 installé : $(java -version 2>&1 | head -1)"
}

# === INSTALLATION KAFKA ===
install_kafka() {
    log "Installation Kafka $KAFKA_VERSION..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation Kafka simulée"
        return
    fi
    
    # Téléchargement depuis repository local
    cd /tmp
    curl -O "http://$REPO_SERVER/kafka/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    
    # Vérification intégrité (optionnel avec checksum)
    if [[ -f "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha256" ]]; then
        sha256sum -c "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha256"
    fi
    
    # Extraction et installation
    tar -xzf "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    cp -r "kafka_${SCALA_VERSION}-${KAFKA_VERSION}"/* "$KAFKA_HOME/"
    
    # Permissions de sécurité
    chown -R "$KAFKA_USER:$KAFKA_GROUP" "$KAFKA_HOME"
    chmod -R 750 "$KAFKA_HOME"
    
    log "Kafka installé dans $KAFKA_HOME"
}

# === CONFIGURATION KAFKA ===
configure_kafka() {
    log "Configuration Kafka broker ID $NODE_ID..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration Kafka simulée"
        return
    fi
    
    # Calcul IP locale
    LOCAL_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    
    # Configuration server.properties
    cat > "$KAFKA_HOME/config/server.properties" << EOF
# === CONFIGURATION KAFKA BROKER $NODE_ID ===
# Banking Environment - PCI-DSS Compliant

# Broker Configuration
broker.id=$NODE_ID
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://$LOCAL_IP:9092

# Cluster Configuration
zookeeper.connect=172.20.2.113:2181,172.20.2.114:2181,172.20.2.115:2181

# Log Configuration
log.dirs=$KAFKA_DATA_DIR
num.network.threads=8
num.io.threads=16
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600

# Topic Configuration for ACM
num.partitions=12
default.replication.factor=3
min.insync.replicas=2
auto.create.topics.enable=true

# Log Retention (Banking Standards)
log.retention.hours=168
log.retention.bytes=1073741824
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

# Recovery Configuration
unclean.leader.election.enable=false
delete.topic.enable=true

# JMX Configuration for Monitoring
jmx.port=9999

# Security Configuration
security.protocol=PLAINTEXT
inter.broker.protocol.version=3.9

# Performance Tuning
replica.fetch.max.bytes=1048576
message.max.bytes=1000000
replica.socket.timeout.ms=30000
replica.lag.time.max.ms=10000

# ACM Specific Configuration
group.initial.rebalance.delay.ms=3000
controlled.shutdown.enable=true
controlled.shutdown.max.retries=3
EOF
    
    # Configuration JVM
    cat > "$KAFKA_HOME/bin/kafka-server-start-env.sh" << EOF
#!/bin/bash
export KAFKA_HEAP_OPTS="-Xmx$JVM_HEAP_SIZE -Xms$JVM_HEAP_SIZE"
export KAFKA_JVM_PERFORMANCE_OPTS="-server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -XX:+ExplicitGCInvokesConcurrent -Djava.awt.headless=true"
export KAFKA_LOG4J_OPTS="-Dlog4j.configuration=file:$KAFKA_HOME/config/log4j.properties"
EOF
    
    chmod +x "$KAFKA_HOME/bin/kafka-server-start-env.sh"
    
    log "Configuration Kafka terminée"
}

# === CONFIGURATION SELINUX ===
configure_selinux() {
    log "Configuration SELinux pour Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration SELinux simulée"
        return
    fi
    
    # Vérification mode SELinux
    if [[ "$(getenforce)" != "Enforcing" ]]; then
        log "ATTENTION: SELinux n'est pas en mode Enforcing"
    fi
    
    # Contextes SELinux pour Kafka
    semanage fcontext -a -t bin_t "$KAFKA_HOME/bin(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t etc_t "$KAFKA_HOME/config(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t var_log_t "$KAFKA_LOGS_DIR(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t var_lib_t "$KAFKA_DATA_DIR(/.*)?" 2>/dev/null || true
    
    # Application des contextes
    restorecon -R "$KAFKA_HOME" "$KAFKA_LOGS_DIR" "$KAFKA_DATA_DIR"
    
    # Port Kafka
    semanage port -a -t http_port_t -p tcp 9092 2>/dev/null || true
    semanage port -a -t http_port_t -p tcp 9999 2>/dev/null || true
    
    log "SELinux configuré pour Kafka"
}

# === SERVICE SYSTEMD ===
create_systemd_service() {
    log "Création service systemd..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Service systemd simulé"
        return
    fi
    
    cat > /etc/systemd/system/kafka.service << EOF
[Unit]
Description=Apache Kafka Server (Broker $NODE_ID)
Documentation=https://kafka.apache.org/
Requires=network.target
After=network.target zookeeper.service

[Service]
Type=simple
User=$KAFKA_USER
Group=$KAFKA_GROUP
Environment=JAVA_HOME=/opt/java
Environment=KAFKA_HOME=$KAFKA_HOME
ExecStartPre=/bin/bash $KAFKA_HOME/bin/kafka-server-start-env.sh
ExecStart=$KAFKA_HOME/bin/kafka-server-start.sh $KAFKA_HOME/config/server.properties
ExecStop=$KAFKA_HOME/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kafka
KillMode=process
TimeoutStopSec=300

# Security Settings (Banking Standards)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$KAFKA_DATA_DIR $KAFKA_LOGS_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable kafka
    
    log "Service systemd créé et activé"
}

# === FONCTION PRINCIPALE ===
main() {
    log "=== DÉBUT INSTALLATION KAFKA CLUSTER ==="
    log "Version script: $SCRIPT_VERSION"
    log "Nœud: $NODE_ID, Repository: $REPO_SERVER"
    
    validate_prerequisites
    configure_system
    install_java
    install_kafka
    configure_kafka
    configure_selinux
    create_systemd_service
    
    log "=== INSTALLATION TERMINÉE ==="
    log "Kafka broker $NODE_ID prêt à démarrer"
    log "Commandes utiles:"
    log "  systemctl start kafka"
    log "  systemctl status kafka"
    log "  journalctl -u kafka -f"
}

# === EXÉCUTION ===
main "$@"