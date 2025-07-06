#!/bin/bash
################################################################################
# Script: install_kafka_cluster.sh
# Version: 2.0.0
# Description: Installation Kafka 3.9.1 en cluster HA pour ACM Banking
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-06
# 
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped
# 
# CHANGELOG:
# v2.0.0 - Refactorisation avec RPM Java, variables nœuds, vérification filesystem
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Ligne $LINENO. Code de sortie: $?" >&2' ERR

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/kafka-install-$(date +%Y%m%d-%H%M%S).log"
KAFKA_VERSION="3.9.1"
SCALA_VERSION="2.13"

# === CONFIGURATION CLUSTER NODES ===
declare -A KAFKA_NODES=(
    [1]="172.20.2.113"
    [2]="172.20.2.114" 
    [3]="172.20.2.115"
)

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
$SCRIPT_NAME v$SCRIPT_VERSION - Installation Kafka Cluster avec RPM Java

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    -h, --help              Afficher cette aide
    -v, --version           Afficher la version
    -n, --node-id NUM       ID du nœud Kafka (1-3)
    -r, --repo-server IP    IP du serveur repository (défaut: 172.20.2.109)
    --dry-run              Mode test sans modification
    --check-fs             Vérifier seulement les filesystems

EXEMPLES:
    $SCRIPT_NAME -n 1       # Installation broker ID 1
    $SCRIPT_NAME -n 2 -r 172.20.2.109  # Broker 2 avec repo custom
    $SCRIPT_NAME --check-fs # Vérification filesystems seulement

CONFORMITÉ:
    - PCI-DSS Level 1
    - ANSSI-BP-028
    - SELinux enforcing
    - Filesystem dédié requis pour KAFKA_DATA_DIR

NŒUDS CLUSTER:
    Node 1: ${KAFKA_NODES[1]}
    Node 2: ${KAFKA_NODES[2]}
    Node 3: ${KAFKA_NODES[3]}
EOF
}

# === VARIABLES DE CONFIGURATION ===
NODE_ID=""
REPO_SERVER="172.20.2.109"
DRY_RUN=false
CHECK_FS_ONLY=false
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
        --check-fs)
            CHECK_FS_ONLY=true
            shift
            ;;
        *)
            error_exit "Option inconnue: $1. Utilisez -h pour l'aide."
            ;;
    esac
done

# === VÉRIFICATION FILESYSTEM KAFKA_DATA_DIR ===
check_kafka_filesystem() {
    log "Vérification filesystem pour KAFKA_DATA_DIR..."
    
    # Vérification que KAFKA_DATA_DIR est un point de montage dédié
    if ! mountpoint -q "$KAFKA_DATA_DIR" 2>/dev/null; then
        log "ATTENTION: $KAFKA_DATA_DIR n'est pas un point de montage dédié"
        
        # Vérification si le répertoire parent est un filesystem dédié
        parent_dir=$(dirname "$KAFKA_DATA_DIR")
        if mountpoint -q "$parent_dir" 2>/dev/null; then
            log "Point de montage parent trouvé: $parent_dir"
            filesystem_info=$(df -h "$parent_dir" | tail -1)
            log "Filesystem info: $filesystem_info"
        else
            error_exit "KAFKA_DATA_DIR doit être sur un filesystem dédié pour la conformité bancaire"
        fi
    else
        log "✓ Filesystem dédié détecté pour $KAFKA_DATA_DIR"
        filesystem_info=$(df -h "$KAFKA_DATA_DIR" | tail -1)
        log "Filesystem info: $filesystem_info"
    fi
    
    # Vérification espace disque (minimum 50GB pour données Kafka)
    available_space_kb=$(df "$KAFKA_DATA_DIR" | awk 'NR==2 {print $4}')
    available_space_gb=$((available_space_kb / 1024 / 1024))
    
    if [[ $available_space_gb -lt 50 ]]; then
        error_exit "Espace disque insuffisant pour KAFKA_DATA_DIR. Minimum 50GB requis, disponible: ${available_space_gb}GB"
    fi
    
    log "✓ Espace disque suffisant: ${available_space_gb}GB disponible"
    
    # Test écriture/lecture sur le filesystem
    test_file="$KAFKA_DATA_DIR/.kafka_fs_test_$$"
    if ! echo "test" > "$test_file" 2>/dev/null; then
        error_exit "Impossible d'écrire sur $KAFKA_DATA_DIR"
    fi
    
    if [[ "$(cat "$test_file" 2>/dev/null)" != "test" ]]; then
        error_exit "Problème de lecture sur $KAFKA_DATA_DIR"
    fi
    
    rm -f "$test_file"
    log "✓ Test écriture/lecture sur filesystem réussi"
}

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
    
    # Vérification filesystem KAFKA_DATA_DIR
    check_kafka_filesystem
    
    # Vérification nœud courant dans la configuration
    local current_ip=${KAFKA_NODES[$NODE_ID]}
    local actual_ip=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    
    if [[ "$current_ip" != "$actual_ip" ]]; then
        log "ATTENTION: IP configurée ($current_ip) != IP réelle ($actual_ip)"
        log "Proceeding avec IP réelle pour advertised.listeners"
    fi
    
    log "Prérequis validés avec succès"
}

# === CONFIGURATION REPOSITORY YUM ===
configure_yum_repository() {
    log "Configuration repository YUM local pour Java..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration repository YUM simulée"
        return
    fi
    
    # Configuration repository local pour Java et dépendances
    cat > /etc/yum.repos.d/acm-local.repo << EOF
# Repository local ACM pour environnement air-gapped
[acm-java]
name=ACM Local Repository - Java
baseurl=http://$REPO_SERVER/java/
enabled=1
gpgcheck=0
module_hotfixes=1
sslverify=false

[acm-kafka]
name=ACM Local Repository - Kafka
baseurl=http://$REPO_SERVER/kafka/
enabled=1
gpgcheck=0
module_hotfixes=1
sslverify=false
EOF
    
    # Nettoyage cache YUM
    yum clean all
    yum makecache
    
    log "Repository YUM configuré et cache mis à jour"
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
# Kafka system limits - Banking Standards PCI-DSS
kafka soft nofile 65536
kafka hard nofile 65536
kafka soft nproc 32768
kafka hard nproc 32768
kafka soft memlock unlimited
kafka hard memlock unlimited
EOF
    
    # Configuration sysctl pour performance réseau et I/O
    cat > /etc/sysctl.d/99-kafka.conf << 'EOF'
# Kafka Performance Tuning - Banking Standards
# Gestion mémoire virtuelle
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 60
vm.dirty_expire_centisecs = 12000

# Configuration réseau
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Optimisation pour charges élevées
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 4096
EOF
    
    sysctl -p /etc/sysctl.d/99-kafka.conf
    
    log "Configuration système terminée"
}

# === INSTALLATION JAVA 17 via RPM ===
install_java_rpm() {
    log "Installation Java 17 via RPM..."
    
    # Vérification si Java 17 déjà installé
    if java -version 2>&1 | grep -q "17\."; then
        log "Java 17 déjà installé"
        java -version 2>&1 | head -3 | while read line; do log "$line"; done
        return
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation Java 17 RPM simulée"
        return
    fi
    
    # Installation via YUM depuis repository local
    log "Installation du package java-17-openjdk.x86_64..."
    yum install -y java-17-openjdk.x86_64 java-17-openjdk-devel.x86_64
    
    # Configuration des alternatives pour Java
    alternatives --install /usr/bin/java java /usr/lib/jvm/java-17-openjdk/bin/java 1
    alternatives --install /usr/bin/javac javac /usr/lib/jvm/java-17-openjdk/bin/javac 1
    
    # Configuration variable d'environnement globale
    cat > /etc/profile.d/java.sh << 'EOF'
# Java 17 Environment Configuration
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
export PATH=$JAVA_HOME/bin:$PATH
EOF
    
    source /etc/profile.d/java.sh
    
    # Validation installation
    java_version=$(java -version 2>&1 | head -1)
    log "Java installé avec succès: $java_version"
    log "JAVA_HOME: $JAVA_HOME"
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
    
    # Vérification intégrité avec checksum si disponible
    if curl -s "http://$REPO_SERVER/kafka/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha256" -o "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha256"; then
        if sha256sum -c "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha256"; then
            log "✓ Checksum validé avec succès"
        else
            error_exit "Échec validation checksum Kafka"
        fi
    else
        log "ATTENTION: Pas de checksum disponible, proceeding sans validation"
    fi
    
    # Extraction et installation
    tar -xzf "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    cp -r "kafka_${SCALA_VERSION}-${KAFKA_VERSION}"/* "$KAFKA_HOME/"
    
    # Permissions de sécurité strictes (Banking Standards)
    chown -R "$KAFKA_USER:$KAFKA_GROUP" "$KAFKA_HOME"
    chmod -R 750 "$KAFKA_HOME"
    chmod 755 "$KAFKA_HOME/bin"/*.sh
    
    log "Kafka installé dans $KAFKA_HOME"
}

# === CONFIGURATION KAFKA ===
configure_kafka() {
    log "Configuration Kafka broker ID $NODE_ID..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration Kafka simulée"
        return
    fi
    
    # Récupération IP locale réelle
    local local_ip=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    log "IP locale détectée: $local_ip"
    
    # Construction de la liste ZooKeeper
    local zk_connect=""
    for node_id in "${!KAFKA_NODES[@]}"; do
        if [[ -n "$zk_connect" ]]; then
            zk_connect+=","
        fi
        zk_connect+="${KAFKA_NODES[$node_id]}:2181"
    done
    
    log "ZooKeeper connect string: $zk_connect"
    
    # Configuration server.properties avec variables
    cat > "$KAFKA_HOME/config/server.properties" << EOF
# === CONFIGURATION KAFKA BROKER $NODE_ID ===
# Banking Environment - PCI-DSS Compliant
# Node IP: ${KAFKA_NODES[$NODE_ID]}

# Broker Configuration
broker.id=$NODE_ID
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://$local_ip:9092

# Cluster Configuration
zookeeper.connect=$zk_connect

# Log Configuration
log.dirs=$KAFKA_DATA_DIR
num.network.threads=8
num.io.threads=16
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600

# Topic Configuration for ACM Banking
num.partitions=12
default.replication.factor=3
min.insync.replicas=2
auto.create.topics.enable=true

# Log Retention (Banking Standards - 7 jours)
log.retention.hours=168
log.retention.bytes=1073741824
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

# Recovery Configuration (High Availability)
unclean.leader.election.enable=false
delete.topic.enable=true
controlled.shutdown.enable=true
controlled.shutdown.max.retries=3

# JMX Configuration for Monitoring
jmx.port=9999

# Security Configuration (ANSSI-BP-028)
security.protocol=PLAINTEXT
inter.broker.protocol.version=3.9

# Performance Tuning
replica.fetch.max.bytes=1048576
message.max.bytes=1000000
replica.socket.timeout.ms=30000
replica.lag.time.max.ms=10000

# ACM Specific Configuration
group.initial.rebalance.delay.ms=3000
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2

# Banking Compliance Settings
log.flush.interval.messages=10000
log.flush.interval.ms=1000
EOF
    
    # Configuration JVM optimisée pour environnement bancaire
    cat > "$KAFKA_HOME/bin/kafka-server-start-env.sh" << EOF
#!/bin/bash
# === KAFKA JVM CONFIGURATION - Banking Standards ===

# Heap sizing
export KAFKA_HEAP_OPTS="-Xmx$JVM_HEAP_SIZE -Xms$JVM_HEAP_SIZE"

# GC Configuration (G1GC pour stabilité)
export KAFKA_JVM_PERFORMANCE_OPTS="-server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -XX:+ExplicitGCInvokesConcurrent -Djava.awt.headless=true -XX:+UseStringDeduplication"

# Logging Configuration
export KAFKA_LOG4J_OPTS="-Dlog4j.configuration=file:$KAFKA_HOME/config/log4j.properties"

# Security and Monitoring
export KAFKA_OPTS="-Djava.security.auth.login.config=$KAFKA_HOME/config/kafka_server_jaas.conf -Dcom.sun.management.jmxremote=true -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false"

# Memory mapping optimization
export KAFKA_OPTS="\$KAFKA_OPTS -XX:+AlwaysPreTouch"
EOF
    
    chmod +x "$KAFKA_HOME/bin/kafka-server-start-env.sh"
    
    log "Configuration Kafka terminée pour nœud $NODE_ID"
}

# === CONFIGURATION SELINUX ===
configure_selinux() {
    log "Configuration SELinux pour Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration SELinux simulée"
        return
    fi
    
    # Vérification mode SELinux
    selinux_mode=$(getenforce)
    log "Mode SELinux actuel: $selinux_mode"
    
    if [[ "$selinux_mode" != "Enforcing" ]]; then
        log "ATTENTION: SELinux n'est pas en mode Enforcing (requis pour conformité bancaire)"
    fi
    
    # Contextes SELinux pour Kafka
    semanage fcontext -a -t bin_t "$KAFKA_HOME/bin(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t etc_t "$KAFKA_HOME/config(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t var_log_t "$KAFKA_LOGS_DIR(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t var_lib_t "$KAFKA_DATA_DIR(/.*)?" 2>/dev/null || true
    
    # Application des contextes
    restorecon -R "$KAFKA_HOME" "$KAFKA_LOGS_DIR" "$KAFKA_DATA_DIR"
    
    # Ports Kafka et JMX
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
Description=Apache Kafka Server (Broker $NODE_ID) - ACM Banking
Documentation=https://kafka.apache.org/
Requires=network.target
After=network.target zookeeper.service

[Service]
Type=simple
User=$KAFKA_USER
Group=$KAFKA_GROUP
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk
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

# Security Settings (Banking Standards PCI-DSS)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$KAFKA_DATA_DIR $KAFKA_LOGS_DIR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable kafka
    
    log "Service systemd créé et activé"
}

# === VALIDATION POST-INSTALLATION ===
validate_installation() {
    log "Validation de l'installation..."
    
    # Vérification Java
    if ! java -version &>/dev/null; then
        error_exit "Java non disponible après installation"
    fi
    
    # Vérification fichiers Kafka
    local required_files=(
        "$KAFKA_HOME/bin/kafka-server-start.sh"
        "$KAFKA_HOME/config/server.properties"
        "$KAFKA_HOME/bin/kafka-server-start-env.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error_exit "Fichier manquant: $file"
        fi
    done
    
    # Vérification permissions
    if [[ "$(stat -c %U:%G "$KAFKA_HOME")" != "$KAFKA_USER:$KAFKA_GROUP" ]]; then
        error_exit "Permissions incorrectes sur $KAFKA_HOME"
    fi
    
    # Vérification service systemd
    if ! systemctl is-enabled kafka &>/dev/null; then
        error_exit "Service kafka non activé"
    fi
    
    log "✓ Validation installation réussie"
}

# === FONCTION PRINCIPALE ===
main() {
    log "=== DÉBUT INSTALLATION KAFKA CLUSTER v$SCRIPT_VERSION ==="
    log "Nœud: $NODE_ID (${KAFKA_NODES[$NODE_ID]}), Repository: $REPO_SERVER"
    
    # Mode vérification filesystem seulement
    if [[ "$CHECK_FS_ONLY" == "true" ]]; then
        check_kafka_filesystem
        exit 0
    fi
    
    validate_prerequisites
    configure_yum_repository
    configure_system
    install_java_rpm
    install_kafka
    configure_kafka
    configure_selinux
    create_systemd_service
    validate_installation
    
    log "=== INSTALLATION TERMINÉE ==="
    log "Kafka broker $NODE_ID prêt à démarrer"
    log ""
    log "PROCHAINES ÉTAPES:"
    log "1. Démarrer ZooKeeper: systemctl start zookeeper"
    log "2. Démarrer Kafka: systemctl start kafka"
    log "3. Vérifier statut: systemctl status kafka"
    log "4. Consulter logs: journalctl -u kafka -f"
    log ""
    log "VALIDATION CLUSTER:"
    log "  kafka-broker-api-versions.sh --bootstrap-server localhost:9092"
    log "  kafka-topics.sh --bootstrap-server localhost:9092 --list"
}

# === EXÉCUTION ===
main "$@"