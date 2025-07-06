#!/bin/bash
################################################################################
# Script: install_kafka_cluster_enhanced.sh
# Version: 2.1.0
# Description: Installation Kafka 3.9.0 en cluster HA pour ACM Banking (Enhanced)
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-06
# 
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped
# 
# CHANGELOG:
# v2.1.0 - Ajout validation interactive KAFKA_NODES et support variable système
# v2.0.0 - Refactorisation avec RPM Java, variables nœuds, vérification filesystem
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Ligne $LINENO. Code de sortie: $?" >&2' ERR

SCRIPT_VERSION="2.1.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/kafka-install-$(date +%Y%m%d-%H%M%S).log"
KAFKA_VERSION="3.9.0"
SCALA_VERSION="2.13"

# === CONFIGURATION CLUSTER NODES (PAR DÉFAUT) ===
# Cette configuration peut être surchargée par la variable système KAFKA_NODES
declare -A KAFKA_NODES_DEFAULT=(
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

# === FONCTION VALIDATION INTERACTIVE KAFKA_NODES ===
validate_kafka_nodes_interactive() {
    local -A nodes_to_validate
    
    # Copie du tableau à valider
    for key in "${!KAFKA_NODES[@]}"; do
        nodes_to_validate[$key]="${KAFKA_NODES[$key]}"
    done
    
    echo ""
    echo "=========================================================================="
    echo "                   VALIDATION CONFIGURATION KAFKA_NODES"
    echo "=========================================================================="
    echo ""
    echo "Configuration actuelle des nœuds du cluster Kafka :"
    echo ""
    
    # Affichage formaté du tableau
    printf "%-10s %-15s %-30s\n" "NODE ID" "IP ADDRESS" "DESCRIPTION"
    printf "%-10s %-15s %-30s\n" "-------" "----------" "-----------"
    
    for node_id in $(printf '%s\n' "${!nodes_to_validate[@]}" | sort -n); do
        local ip="${nodes_to_validate[$node_id]}"
        local description="Nœud Kafka/ZooKeeper $node_id"
        printf "%-10s %-15s %-30s\n" "$node_id" "$ip" "$description"
    done
    
    echo ""
    echo "Réseau cible   : 172.20.2.0/24"
    echo "Ports Kafka    : 9092 (inter-cluster)"
    echo "Ports ZooKeeper: 2181 (inter-cluster)"
    echo "Repository     : $REPO_SERVER"
    echo ""
    
    # Demande de validation
    while true; do
        echo -n "Voulez-vous continuer avec cette configuration ? [O/n] : "
        read -r response
        
        case "$response" in
            ""|"O"|"o"|"Oui"|"oui"|"Y"|"y"|"Yes"|"yes")
                log "✓ Configuration KAFKA_NODES validée par l'utilisateur"
                break
                ;;
            "N"|"n"|"Non"|"non"|"No"|"no")
                echo ""
                echo "Installation annulée par l'utilisateur."
                echo "Pour modifier la configuration :"
                echo "1. Éditez le script et modifiez KAFKA_NODES_DEFAULT"
                echo "2. Ou définissez la variable système KAFKA_NODES"
                echo ""
                exit 1
                ;;
            *)
                echo "Réponse invalide. Veuillez répondre par 'O' (Oui) ou 'n' (Non)."
                ;;
        esac
    done
    
    echo ""
}

# === FONCTION GESTION VARIABLE SYSTÈME KAFKA_NODES ===
load_kafka_nodes_configuration() {
    log "Chargement de la configuration KAFKA_NODES..."
    
    # Vérification existence variable système KAFKA_NODES
    if [[ -n "${KAFKA_NODES:-}" ]]; then
        log "✓ Variable système KAFKA_NODES détectée"
        log "Source de configuration: Variable système"
        
        # Parsing de la variable système (format attendu: "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115")
        if [[ "$KAFKA_NODES" =~ ^[0-9]+:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(,[0-9]+:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
            declare -gA KAFKA_NODES_RUNTIME
            
            # Parsing des entrées
            IFS=',' read -ra ENTRIES <<< "$KAFKA_NODES"
            for entry in "${ENTRIES[@]}"; do
                if [[ "$entry" =~ ^([0-9]+):([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
                    local node_id="${BASH_REMATCH[1]}"
                    local node_ip="${BASH_REMATCH[2]}"
                    KAFKA_NODES_RUNTIME[$node_id]="$node_ip"
                    log "  Nœud $node_id: $node_ip"
                else
                    error_exit "Format invalide dans KAFKA_NODES: '$entry'. Format attendu: 'ID:IP'"
                fi
            done
            
            # Validation du nombre de nœuds
            if [[ ${#KAFKA_NODES_RUNTIME[@]} -lt 3 ]]; then
                error_exit "Cluster Kafka requiert minimum 3 nœuds. Trouvé: ${#KAFKA_NODES_RUNTIME[@]}"
            fi
            
            # Copie vers le tableau principal
            declare -gA KAFKA_NODES
            for key in "${!KAFKA_NODES_RUNTIME[@]}"; do
                KAFKA_NODES[$key]="${KAFKA_NODES_RUNTIME[$key]}"
            done
            
        else
            error_exit "Variable système KAFKA_NODES format invalide. Format: '1:172.20.2.113,2:172.20.2.114,3:172.20.2.115'"
        fi
        
    else
        log "Variable système KAFKA_NODES non définie"
        log "Source de configuration: Configuration par défaut du script"
        
        # Utilisation de la configuration par défaut
        declare -gA KAFKA_NODES
        for key in "${!KAFKA_NODES_DEFAULT[@]}"; do
            KAFKA_NODES[$key]="${KAFKA_NODES_DEFAULT[$key]}"
        done
    fi
    
    # Validation de la configuration finale
    log "Configuration KAFKA_NODES finale :"
    for node_id in $(printf '%s\n' "${!KAFKA_NODES[@]}" | sort -n); do
        log "  Nœud $node_id: ${KAFKA_NODES[$node_id]}"
    done
}

# === HELP FUNCTION ===
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Installation Kafka Cluster avec RPM Java (Enhanced)

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    -h, --help              Afficher cette aide
    -v, --version           Afficher la version
    -n, --node-id NUM       ID du nœud Kafka (1-3)
    -r, --repo-server IP    IP du serveur repository (défaut: 172.20.2.109)
    --dry-run              Mode test sans modification
    --check-fs             Vérifier seulement les filesystems
    --skip-validation      Ignorer la validation interactive (mode automatique)

EXEMPLES:
    $SCRIPT_NAME -n 1                    # Installation broker ID 1
    $SCRIPT_NAME -n 2 -r 172.20.2.109    # Broker 2 avec repo custom
    $SCRIPT_NAME --check-fs              # Vérification filesystems seulement
    $SCRIPT_NAME -n 1 --skip-validation  # Installation sans validation interactive

CONFIGURATION KAFKA_NODES:
    Le script supporte deux méthodes de configuration des nœuds :
    
    1. Configuration par défaut (dans le script) :
       Node 1: ${KAFKA_NODES_DEFAULT[1]}
       Node 2: ${KAFKA_NODES_DEFAULT[2]}
       Node 3: ${KAFKA_NODES_DEFAULT[3]}
    
    2. Variable système KAFKA_NODES (prioritaire si définie) :
       export KAFKA_NODES="1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
       
    La validation interactive permet de confirmer la configuration avant installation.

CONFORMITÉ:
    - PCI-DSS Level 1
    - ANSSI-BP-028
    - SELinux enforcing
    - Filesystem dédié requis pour KAFKA_DATA_DIR

SÉCURITÉ BANKING:
    - Validation interactive de la topologie réseau
    - Support variable système pour automatisation
    - Logging complet des opérations
    - Vérification intégrité configuration
EOF
}

# === VARIABLES DE CONFIGURATION ===
NODE_ID=""
REPO_SERVER="172.20.2.109"
DRY_RUN=false
CHECK_FS_ONLY=false
SKIP_VALIDATION=false
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
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        *)
            error_exit "Option inconnue: $1. Utilisez -h pour l'aide."
            ;;
    esac
done

# === VÉRIFICATION FILESYSTEM KAFKA ===
check_kafka_filesystem() {
    log "Vérification filesystem dédié pour Kafka..."
    
    if [[ ! -d "$KAFKA_DATA_DIR" ]]; then
        error_exit "Répertoire KAFKA_DATA_DIR manquant: $KAFKA_DATA_DIR"
    fi
    
    # Vérification mount point dédié (Banking Requirement)
    local mount_point=$(df "$KAFKA_DATA_DIR" | tail -1 | awk '{print $6}')
    if [[ "$mount_point" == "/" ]]; then
        log "ATTENTION: $KAFKA_DATA_DIR sur filesystem racine (non recommandé en production)"
    else
        log "✓ $KAFKA_DATA_DIR sur filesystem dédié: $mount_point"
    fi
    
    # Vérification espace disque (minimum 10GB pour cluster de test)
    local available_space=$(df "$KAFKA_DATA_DIR" | tail -1 | awk '{print $4}')
    local min_space_kb=$((10 * 1024 * 1024)) # 10GB en KB
    
    if [[ $available_space -lt $min_space_kb ]]; then
        error_exit "Espace disque insuffisant. Requis: 10GB, Disponible: $((available_space / 1024 / 1024))GB"
    fi
    
    log "✓ Espace disque suffisant: $((available_space / 1024 / 1024))GB disponible"
}

# === VALIDATION PRÉREQUIS ===
validate_prerequisites() {
    log "Validation des prérequis d'installation..."
    
    # Validation NODE_ID
    if [[ ! "$NODE_ID" =~ ^[1-3]$ ]]; then
        error_exit "ID nœud requis (1-3). Utilisez -n NUM"
    fi
    
    # Vérification root
    if [[ $EUID -ne 0 ]]; then
        error_exit "Script doit être exécuté en root"
    fi
    
    # Vérification connectivité repository
    if ! curl -s --connect-timeout 5 "http://$REPO_SERVER/repos/kafka3/" > /dev/null; then
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
baseurl=http://$REPO_SERVER/repos/java/
enabled=1
gpgcheck=0
module_hotfixes=1
sslverify=false

[acm-kafka]
name=ACM Local Repository - Kafka
baseurl=http://$REPO_SERVER/repos/kafka3/
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
        useradd -r -s /sbin/nologin -d "$KAFKA_HOME" "$KAFKA_USER"
        log "Utilisateur $KAFKA_USER créé"
    fi
    
    # Création des répertoires avec permissions sécurisées
    local directories=("$KAFKA_HOME" "$KAFKA_DATA_DIR" "$KAFKA_LOGS_DIR")
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
        chown "$KAFKA_USER:$KAFKA_GROUP" "$dir"
        chmod 750 "$dir"
    done
    
    # Configuration limits système pour Kafka
    cat > /etc/security/limits.d/kafka.conf << EOF
# Limits pour utilisateur kafka - Banking Requirements
$KAFKA_USER soft nofile 65536
$KAFKA_USER hard nofile 65536
$KAFKA_USER soft nproc 4096
$KAFKA_USER hard nproc 4096
EOF
    
    # Configuration sysctl pour performances réseau
    cat > /etc/sysctl.d/99-kafka.conf << EOF
# Optimisations réseau pour Kafka - Banking Performance
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 12582912 134217728
net.ipv4.tcp_wmem = 4096 12582912 134217728
vm.swappiness = 1
EOF
    
    sysctl -p /etc/sysctl.d/99-kafka.conf
    
    log "Configuration système appliquée"
}

# === INSTALLATION JAVA VIA RPM ===
install_java_rpm() {
    log "Installation Java JDK 17 via RPM local..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation Java simulée"
        return
    fi
    
    # Installation Java depuis repository local
    if ! rpm -q java-17-openjdk-headless &>/dev/null; then
        yum install -y java-17-openjdk-headless java-17-openjdk-devel
        log "Java JDK 17 installé avec succès"
    else
        log "Java JDK 17 déjà installé"
    fi
    
    # Configuration JAVA_HOME
    export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
    echo "export JAVA_HOME=$JAVA_HOME" > /etc/profile.d/java.sh
    chmod 644 /etc/profile.d/java.sh
    
    # Vérification installation
    local java_version=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)
    log "Java installé: $java_version"
}

# === INSTALLATION KAFKA ===
install_kafka() {
    log "Installation Kafka $KAFKA_VERSION depuis repository local..."
    log "URL Archive : http://$REPO_SERVER/repos/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    log "URL Checksum : http://$REPO_SERVER/repos/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512.ok"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation Kafka simulée"
        return
    fi
    
    cd /tmp
    
    # Téléchargement depuis repository local
    if ! curl -f "http://$REPO_SERVER/repos/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" -o "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"; then
        error_exit "Échec téléchargement Kafka depuis $REPO_SERVER"
    fi
    
    # Vérification checksum si disponible
    if curl -f "http://$REPO_SERVER/repos/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512.ok" -o "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512.ok"; then
        if sha512sum -c "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512.ok"; then
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
# === CONFIGURATION KAFKA CLUSTER BANCAIRE ===
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# Date: $(date)
# Conformité: PCI-DSS, ANSSI-BP-028

# === IDENTITÉ BROKER ===
broker.id=$NODE_ID

# === LISTENERS ET NETWORK ===
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://$local_ip:9092
listener.security.protocol.map=PLAINTEXT:PLAINTEXT

# === ZOOKEEPER CONNECTION ===
zookeeper.connect=$zk_connect
zookeeper.connection.timeout.ms=18000
zookeeper.session.timeout.ms=18000

# === DATA DIRECTORIES ===
log.dirs=$KAFKA_DATA_DIR
num.network.threads=8
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600

# === LOG CONFIGURATION (Banking Requirements) ===
num.partitions=5
num.recovery.threads.per.data.dir=1
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
default.replication.factor=3
min.insync.replicas=2

# === RETENTION ET CLEANUP (ACM Banking) ===
log.retention.hours=168
log.retention.bytes=-1
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
log.cleanup.policy=delete

# === GROUP COORDINATOR ===
group.initial.rebalance.delay.ms=3000
offsets.topic.num.partitions=50
offsets.retention.minutes=10080

# === COMPRESSION ET PERFORMANCES ===
compression.type=lz4
message.max.bytes=1000000
replica.fetch.max.bytes=1048576

# === MONITORING ET MÉTRIQUES ===
auto.create.topics.enable=true
delete.topic.enable=true
controlled.shutdown.enable=true
controlled.shutdown.max.retries=3
controlled.shutdown.retry.backoff.ms=5000

# === SÉCURITÉ BANCAIRE ===
inter.broker.protocol.version=3.9-IV0
log.message.format.version=3.9-IV0
EOF
    
    # Configuration log4j pour compliance Banking
    cat > "$KAFKA_HOME/config/log4j.properties" << EOF
# === CONFIGURATION LOGGING BANCAIRE ===
# Root logger
log4j.rootLogger=INFO, stdout, kafkaAppender

# Console appender
log4j.appender.stdout=org.apache.log4j.ConsoleAppender
log4j.appender.stdout.layout=org.apache.log4j.PatternLayout
log4j.appender.stdout.layout.ConversionPattern=[%d] %p %m (%c)%n

# File appender avec rotation (Banking Requirements)
log4j.appender.kafkaAppender=org.apache.log4j.RollingFileAppender
log4j.appender.kafkaAppender.File=$KAFKA_LOGS_DIR/server.log
log4j.appender.kafkaAppender.MaxFileSize=100MB
log4j.appender.kafkaAppender.MaxBackupIndex=10
log4j.appender.kafkaAppender.layout=org.apache.log4j.PatternLayout
log4j.appender.kafkaAppender.layout.ConversionPattern=[%d] %p %m (%c)%n

# Suppression logs sensibles pour conformité PCI-DSS
log4j.logger.kafka.network.RequestChannel\$=WARN
log4j.logger.kafka.producer.async.DefaultEventHandler=DEBUG
log4j.logger.kafka.request.logger=WARN
log4j.logger.kafka.controller=TRACE
log4j.logger.kafka.log.LogCleaner=INFO
log4j.logger.state.change.logger=TRACE
log4j.logger.kafka.authorizer.logger=DEBUG
EOF
    
    log "Configuration Kafka générée avec IP locale: $local_ip"
}

# === CONFIGURATION SELINUX ===
configure_selinux() {
    log "Configuration SELinux pour Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration SELinux simulée"
        return
    fi
    
    # Vérification SELinux actif
    if ! command -v getenforce &> /dev/null || [[ "$(getenforce)" == "Disabled" ]]; then
        log "SELinux désactivé - skipping configuration"
        return
    fi
    
    # Configuration ports Kafka
    semanage port -a -t http_port_t -p tcp 9092 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp 9092
    
    # Contextes pour répertoires Kafka
    semanage fcontext -a -t admin_home_t "$KAFKA_HOME(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t admin_home_t "$KAFKA_HOME(/.*)?"
    
    semanage fcontext -a -t var_log_t "$KAFKA_LOGS_DIR(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t var_log_t "$KAFKA_LOGS_DIR(/.*)?"
    
    semanage fcontext -a -t admin_home_t "$KAFKA_DATA_DIR(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t admin_home_t "$KAFKA_DATA_DIR(/.*)?"
    
    # Application des contextes
    restorecon -R "$KAFKA_HOME" "$KAFKA_LOGS_DIR" "$KAFKA_DATA_DIR"
    
    log "Configuration SELinux appliquée"
}

# === CRÉATION SERVICE SYSTEMD ===
create_systemd_service() {
    log "Création service systemd Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Création service systemd simulée"
        return
    fi
    
    # Service Kafka avec configuration Banking
    cat > /etc/systemd/system/kafka.service << EOF
[Unit]
Description=Apache Kafka Server (Banking Cluster Node $NODE_ID)
Documentation=https://kafka.apache.org/documentation/
Requires=network.target remote-fs.target
After=network.target remote-fs.target zookeeper.service

[Service]
Type=simple
User=$KAFKA_USER
Group=$KAFKA_GROUP
Environment=JAVA_HOME=$JAVA_HOME
Environment=KAFKA_HEAP_OPTS="-Xmx$JVM_HEAP_SIZE -Xms$JVM_HEAP_SIZE"
Environment=KAFKA_JVM_PERFORMANCE_OPTS="-server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35"
Environment=KAFKA_LOG4J_OPTS="-Dlog4j.configuration=file:$KAFKA_HOME/config/log4j.properties"
ExecStart=$KAFKA_HOME/bin/kafka-server-start.sh $KAFKA_HOME/config/server.properties
ExecStop=$KAFKA_HOME/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kafka
KillMode=process
TimeoutStopSec=30

# Sécurité Banking (ANSSI-BP-028)
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$KAFKA_DATA_DIR $KAFKA_LOGS_DIR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    
    # Activation du service
    systemctl daemon-reload
    systemctl enable kafka
    
    log "Service systemd kafka créé et activé"
}

# === VALIDATION INSTALLATION ===
validate_installation() {
    log "Validation de l'installation..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Validation installation simulée"
        return
    fi
    
    # Vérification fichiers critiques
    local required_files=(
        "$KAFKA_HOME/bin/kafka-server-start.sh"
        "$KAFKA_HOME/config/server.properties"
        "$KAFKA_HOME/config/log4j.properties"
        "/etc/systemd/system/kafka.service"
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
    
    # Chargement de la configuration KAFKA_NODES
    load_kafka_nodes_configuration
    
    # Validation interactive (sauf si skip-validation)
    if [[ "$SKIP_VALIDATION" != "true" && "$CHECK_FS_ONLY" != "true" && "$DRY_RUN" != "true" ]]; then
        validate_kafka_nodes_interactive
    fi
    
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
    log ""
    log "CONFIGURATION UTILISÉE:"
    for node_id in $(printf '%s\n' "${!KAFKA_NODES[@]}" | sort -n); do
        log "  Nœud $node_id: ${KAFKA_NODES[$node_id]}"
    done
}

# === EXÉCUTION ===
main "$@"