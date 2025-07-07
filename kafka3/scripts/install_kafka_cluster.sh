#!/bin/bash
################################################################################
# Script: install_kafka_cluster.sh
# Version: 2.3.0
# Description: Installation Kafka 3.9.0 en cluster HA pour ACM avec firewall
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-07
# 
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped
# 
# CHANGELOG:
# v2.3.0 - Ajout argument --skip-fs-validation pour désactiver check_kafka_filesystem
# v2.2.0 - Ajout configuration automatique firewall TCP/9092 et TCP/2181
# v2.1.0 - Ajout validation interactive KAFKA_NODES et support variable système
# v2.0.0 - Refactorisation avec RPM Java, variables nœuds, vérification filesystem
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Ligne $LINENO. Code de sortie: $?" >&2' ERR

SCRIPT_VERSION="2.3.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/kafka-install-$(date +%Y%m%d-%H%M%S).log"
KAFKA_VERSION="3.9.1"
SCALA_VERSION="2.13"

# === CONFIGURATION CLUSTER NODES (PAR DÉFAUT) ===
# Cette configuration peut être surchargée par la variable système KAFKA_NODES
declare -A KAFKA_NODES_DEFAULT=(
    [1]="172.20.2.113"
    [2]="172.20.2.114" 
    [3]="172.20.2.115"
)

# === CONFIGURATION PATHS ET VARIABLES ===
KAFKA_HOME="/opt/kafka"
KAFKA_USER="kafka"
KAFKA_GROUP="kafka"
KAFKA_DATA_DIR="/data/kafka"
KAFKA_LOGS_DIR="/var/log/kafka"
JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
JVM_HEAP_SIZE="2g"

# === VARIABLES GLOBALES ===
NODE_ID=""
REPO_SERVER="172.20.2.109"
REPO_SERVER_BASEURL="repos"
DRY_RUN="false"
CHECK_FS_ONLY="false"
SKIP_VALIDATION="false"
SKIP_FS_VALIDATION="false"  # NOUVELLE VARIABLE

# === LOGGING FUNCTION ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# === FONCTION CHARGEMENT CONFIGURATION KAFKA_NODES ===
load_kafka_nodes_configuration() {
    log "Chargement configuration KAFKA_NODES..."
    
    # Vérification variable système KAFKA_NODES
    if [[ -n "${KAFKA_NODES:-}" ]]; then
        log "Variable système KAFKA_NODES détectée: $KAFKA_NODES"
        log "Source de configuration: Variable système"
        
        # Parse du format "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
        if [[ "$KAFKA_NODES" =~ ^[0-9]+:[0-9.]+([,][0-9]+:[0-9.]+)*$ ]]; then
            declare -A KAFKA_NODES_RUNTIME
            
            IFS=',' read -ra NODE_PAIRS <<< "$KAFKA_NODES"
            for pair in "${NODE_PAIRS[@]}"; do
                IFS=':' read -ra NODE_INFO <<< "$pair"
                local node_id="${NODE_INFO[0]}"
                local node_ip="${NODE_INFO[1]}"
                
                if [[ "$node_id" =~ ^[1-9][0-9]*$ ]] && [[ "$node_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    KAFKA_NODES_RUNTIME[$node_id]="$node_ip"
                    log "  Nœud $node_id: $node_ip"
                else
                    error_exit "Format invalide dans KAFKA_NODES: '$pair'. Format attendu: 'ID:IP'"
                fi
            done
            
            # Copie de la configuration runtime vers la variable globale
            declare -A -g KAFKA_NODES
            for key in "${!KAFKA_NODES_RUNTIME[@]}"; do
                KAFKA_NODES[$key]="${KAFKA_NODES_RUNTIME[$key]}"
            done
        else
            error_exit "Format KAFKA_NODES invalide: '$KAFKA_NODES'. Format: '1:IP,2:IP,3:IP'"
        fi
    else
        log "Utilisation configuration par défaut"
        log "Source de configuration: Script (défaut)"
        
        # Copie de la configuration par défaut
        declare -A -g KAFKA_NODES
        for key in "${!KAFKA_NODES_DEFAULT[@]}"; do
            KAFKA_NODES[$key]="${KAFKA_NODES_DEFAULT[$key]}"
            log "  Nœud $key: ${KAFKA_NODES_DEFAULT[$key]}"
        done
    fi
    
    # Validation nombre de nœuds minimum
    if [[ ${#KAFKA_NODES[@]} -lt 3 ]]; then
        error_exit "Configuration insuffisante: ${#KAFKA_NODES[@]} nœud(s). Minimum 3 nœuds requis pour HA"
    fi
    
    log "Configuration KAFKA_NODES chargée: ${#KAFKA_NODES[@]} nœud(s)"
}

# === VALIDATION INTERACTIVE KAFKA_NODES ===
validate_kafka_nodes_interactive() {
    log "=== VALIDATION CONFIGURATION KAFKA_NODES ==="
    echo ""
    echo "Configuration des nœuds Kafka détectée :"
    echo ""
    
    for node_id in $(printf '%s\n' "${!KAFKA_NODES[@]}" | sort -n); do
        echo "  Nœud $node_id: ${KAFKA_NODES[$node_id]}"
    done
    
    echo ""
    echo "Cette configuration sera utilisée pour :"
    echo "  - Générer la configuration ZooKeeper connect string"
    echo "  - Configurer advertised.listeners du broker $NODE_ID"
    echo "  - Établir la communication inter-brokers"
    echo ""
    
    while true; do
        echo -n "Confirmer cette configuration et continuer l'installation ? [O/n]: "
        read -r response
        case "$response" in
            [oO]|[oO][uU][iI]|"")
                log "Configuration validée par l'utilisateur"
                break
                ;;
            [nN]|[nN][oO][nN])
                log "Installation annulée par l'utilisateur"
                exit 0
                ;;
            *)
                echo "Réponse invalide. Veuillez répondre par 'oui' (O) ou 'non' (n)."
                ;;
        esac
    done
    
    echo ""
}

# === HELP FUNCTION ===
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Installation Kafka Cluster avec RPM Java et firewall

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
    --skip-fs-validation   Désactiver la vérification des filesystems

EXEMPLES:
    $SCRIPT_NAME -n 1                    # Installation broker ID 1
    $SCRIPT_NAME -n 2 -r 172.20.2.109    # Broker 2 avec repo custom
    $SCRIPT_NAME --check-fs              # Vérification filesystems seulement
    $SCRIPT_NAME -n 1 --skip-validation  # Installation sans validation interactive
    $SCRIPT_NAME -n 1 --skip-fs-validation  # Installation sans vérification filesystem

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
    - PCI-DSS: Chiffrement, logs, permissions restrictives
    - ANSSI-BP-028: SELinux, firewall, comptes de service
    - Banking Standards: Haute disponibilité, monitoring, audit trail

AUTEUR: Philippe.candido@emerging-it.fr
EOF
}

# === VERSION FUNCTION ===
show_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
    echo "Kafka $KAFKA_VERSION / Scala $SCALA_VERSION"
    echo "Support: RHEL 9, PCI-DSS, ANSSI-BP-028"
}

# === PARSE ARGUMENTS ===
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
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
            DRY_RUN="true"
            shift
            ;;
        --check-fs)
            CHECK_FS_ONLY="true"
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION="true"
            shift
            ;;
        --skip-fs-validation)
            SKIP_FS_VALIDATION="true"
            shift
            ;;
        *)
            error_exit "Option inconnue: $1. Utilisez --help pour l'aide."
            ;;
    esac
done

# === VALIDATION ARGUMENTS ===
if [[ -z "$NODE_ID" ]]; then
    error_exit "ID nœud requis. Utilisez -n NUM (1-3)"
fi

if [[ ! "$NODE_ID" =~ ^[1-3]$ ]]; then
    error_exit "ID nœud invalide: $NODE_ID. Valeurs acceptées: 1, 2, 3"
fi

# === VÉRIFICATION FILESYSTEM KAFKA ===
check_kafka_filesystem() {
    log "Vérification filesystem pour Kafka..."
    
    # Vérification si la validation filesystem est désactivée
    if [[ "$SKIP_FS_VALIDATION" == "true" ]]; then
        log "⚠️  ATTENTION: Vérification filesystem désactivée (--skip-fs-validation)"
        log "⚠️  Assurez-vous que les filesystems suivants sont correctement configurés :"
        log "   - $KAFKA_DATA_DIR (minimum 20GB, monté et accessible en écriture)"
        log "   - $KAFKA_LOGS_DIR (accessible en écriture)"
        return 0
    fi
    
    # Vérification montage $KAFKA_DATA_DIR
    if ! mountpoint -q $KAFKA_DATA_DIR; then
        error_exit "Filesystem $KAFKA_DATA_DIR non monté. Requis pour KAFKA_DATA_DIR"
    fi
    
    # Vérification espace libre
    local available_space=$(df $KAFKA_DATA_DIR | tail -1 | awk '{print $4}')
    local min_space_kb=$((20 * 1024 * 1024))  # 20GB en KB
    
    if [[ "$available_space" -lt "$min_space_kb" ]]; then
        error_exit "Espace insuffisant sur $KAFKA_DATA_DIR: ${available_space}KB disponible, ${min_space_kb}KB requis"
    fi
    
    log "✓ Filesystem $KAFKA_DATA_DIR: ${available_space}KB disponible"
    
    # Vérification permissions et montage /var/log
    if [[ ! -d "$KAFKA_LOGS_DIR" ]] || [[ ! -w "$KAFKA_LOGS_DIR" ]]; then
        error_exit "Répertoire $KAFKA_LOGS_DIR inaccessible ou non accessible en écriture"
    fi
    
    log "✓ Répertoire $KAFKA_LOGS_DIR accessible"
    log "✓ Validation filesystem terminée avec succès"
}

# === VALIDATION PRÉREQUIS ===
validate_prerequisites() {
    log "Validation des prérequis système..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Validation prérequis simulée"
        return
    fi
    
    # Vérification OS
    if [[ ! -f /etc/redhat-release ]] || ! grep -q "Red Hat Enterprise Linux.*9\." /etc/redhat-release; then
        error_exit "OS non supporté. RHEL 9 requis."
    fi
    
    # Vérification architecture
    if [[ "$(uname -m)" != "x86_64" ]]; then
        error_exit "Architecture non supportée: $(uname -m). x86_64 requis."
    fi
    
    # Vérification privilèges root
    if [[ "$EUID" -ne 0 ]]; then
        error_exit "Privilèges root requis pour l'installation"
    fi
    
    # Vérification outils système
    local required_tools=("curl" "tar" "systemctl" "useradd" "chown")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error_exit "Outil manquant: $tool"
        fi
    done
    
    # Vérification mémoire (minimum 4GB pour Kafka)
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local min_mem_kb=$((4 * 1024 * 1024))
    if [[ "$mem_kb" -lt "$min_mem_kb" ]]; then
        error_exit "Mémoire insuffisante: ${mem_kb}KB disponible, ${min_mem_kb}KB requis"
    fi
    
    # Vérification filesystem (peut être désactivée avec --skip-fs-validation)
    check_kafka_filesystem
    
    log "✓ Prérequis système validés"
}

# === CONFIGURATION REPOSITORY YUM ===
configure_yum_repository() {
    log "Configuration repository YUM local..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration repository simulée"
        return
    fi
    
    # Test connectivité repository
    if ! curl -sf "http://$REPO_SERVER/$REPO_SERVER_BASEURL/" >/dev/null; then
        error_exit "Repository $REPO_SERVER/$REPO_SERVER_BASEURL/ inaccessible"
    fi
    
    # Configuration repository Kafka
    cat > /etc/yum.repos.d/kafka-local.repo << EOF
[kafka-local]
name=Kafka Local Repository
baseurl=http://$REPO_SERVER/$REPO_SERVER_BASEURL/kafka3/
enabled=1
gpgcheck=0
priority=1
EOF

    # Configuration repository Kafka
    cat > /etc/yum.repos.d/java-local.repo << EOF
[java-local]
name=Java Local Repository
baseurl=http://$REPO_SERVER/$REPO_SERVER_BASEURL/java/
enabled=1
gpgcheck=0
priority=1
EOF

    # Nettoyage cache YUM
    yum clean all
    yum makecache

    log "Repository YUM configuré: http://$REPO_SERVER/$REPO_SERVER_BASEURL/kafka3/"
    log "Repository YUM configuré: http://$REPO_SERVER/$REPO_SERVER_BASEURL/java/"
}

# === CONFIGURATION SYSTÈME ===
configure_system() {
    log "Configuration système pour Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration système simulée"
        return
    fi
    
    # Création groupe et utilisateur kafka
    if ! getent group "$KAFKA_GROUP" >/dev/null; then
        groupadd -r "$KAFKA_GROUP"
        log "✓ Groupe $KAFKA_GROUP créé"
    fi
    
    if ! getent passwd "$KAFKA_USER" >/dev/null; then
        useradd -r -g "$KAFKA_GROUP" -s /bin/bash -d "$KAFKA_HOME" "$KAFKA_USER"
        log "✓ Utilisateur $KAFKA_USER créé"
    fi
    
    # Création répertoires avec permissions
    local directories=("$KAFKA_HOME" "$KAFKA_DATA_DIR" "$KAFKA_LOGS_DIR")
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
        fi
        chown "$KAFKA_USER:$KAFKA_GROUP" "$dir"
        chmod 750 "$dir"
        log "✓ Répertoire $dir configuré"
    done
    
    # Configuration limites système
    cat > /etc/security/limits.d/kafka.conf << EOF
# Limites système pour Kafka (PCI-DSS/ANSSI-BP-028)
$KAFKA_USER soft nofile 65536
$KAFKA_USER hard nofile 65536
$KAFKA_USER soft nproc 32768
$KAFKA_USER hard nproc 32768
EOF
    
    log "✓ Configuration système terminée"
}

# === INSTALLATION JAVA VIA RPM ===
install_java_rpm() {
    log "Installation Java OpenJDK 17 via RPM..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation Java simulée"
        return
    fi
    
    # Installation Java OpenJDK 17
    if ! rpm -qa | grep -q "java-17-openjdk"; then
        yum install -y java-17-openjdk java-17-openjdk-devel
        log "✓ Java OpenJDK 17 installé"
    else
        log "✓ Java OpenJDK 17 déjà installé"
    fi
    
    # Vérification installation Java
    if [[ ! -d "$JAVA_HOME" ]]; then
        error_exit "JAVA_HOME $JAVA_HOME non trouvé après installation"
    fi
    
    local java_version=$("$JAVA_HOME/bin/java" -version 2>&1 | head -n1)
    log "✓ Java configuré: $java_version"
}

# === INSTALLATION KAFKA ===
install_kafka() {
    log "Installation Kafka $KAFKA_VERSION depuis repository local..."
    log "URL Archive : http://$REPO_SERVER/$REPO_SERVER_BASEURL/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    log "URL Checksum : http://$REPO_SERVER/$REPO_SERVER_BASEURL/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512.ok"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation Kafka simulée"
        return
    fi

    cd /tmp

    # Téléchargement depuis repository local
    if ! curl -f "http://$REPO_SERVER/$REPO_SERVER_BASEURL/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" -o "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"; then
        error_exit "Échec téléchargement Kafka depuis $REPO_SERVER"
    fi

    # Vérification checksum si disponible
    if curl -f "http://$REPO_SERVER/$REPO_SERVER_BASEURL/kafka3/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512.ok" -o "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512.ok"; then
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
    log "Configuration Kafka broker $NODE_ID..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration Kafka simulée"
        return
    fi
    
    # Récupération IP locale du nœud
    local local_ip="${KAFKA_NODES[$NODE_ID]}"
    log "IP locale du broker: $local_ip"
    
    # Construction ZooKeeper connect string
    local zk_connect=""
    for node_id in $(printf '%s\n' "${!KAFKA_NODES[@]}" | sort -n); do
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
inter.broker.protocol.version=$KAFKA_VERSION
log.message.format.version=$KAFKA_VERSION
EOF
    
    # Configuration JVM heap
    cat > "$KAFKA_HOME/bin/kafka-server-start.sh.env" << EOF
export KAFKA_HEAP_OPTS="-Xmx$JVM_HEAP_SIZE -Xms$JVM_HEAP_SIZE"
export KAFKA_JVM_PERFORMANCE_OPTS="-server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35"
export KAFKA_GC_LOG_OPTS="-Xlog:gc*:$KAFKA_LOGS_DIR/kafka-gc.log:time,tags"
export JAVA_HOME=$JAVA_HOME
EOF
    
    log "✓ Configuration Kafka broker $NODE_ID terminée"
}

# === CONFIGURATION SELINUX ===
configure_selinux() {
    log "Configuration SELinux pour Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration SELinux simulée"
        return
    fi
    
    # Vérification état SELinux
    if ! command -v getenforce &> /dev/null; then
        log "⚠️ SELinux non disponible, ignorer configuration"
        return
    fi
    
    if [[ "$(getenforce)" == "Disabled" ]]; then
        log "⚠️ SELinux désactivé, ignorer configuration"
        return
    fi
    
    # Configuration contextes SELinux
    semanage fcontext -a -t bin_t "$KAFKA_HOME/bin/.*" 2>/dev/null || true
    semanage fcontext -a -t etc_t "$KAFKA_HOME/config/.*" 2>/dev/null || true
    semanage fcontext -a -t var_log_t "$KAFKA_LOGS_DIR/.*" 2>/dev/null || true
    semanage fcontext -a -t usr_t "$KAFKA_DATA_DIR/.*" 2>/dev/null || true
    
    # Application contextes
    restorecon -R "$KAFKA_HOME" "$KAFKA_LOGS_DIR" "$KAFKA_DATA_DIR" 2>/dev/null || true
    
    # Configuration port Kafka
    semanage port -a -t unreserved_port_t -p tcp 9092 2>/dev/null || true
    
    log "✓ Configuration SELinux appliquée"
}

# === CONFIGURATION FIREWALL ===
configure_firewall() {
    log "Configuration firewall pour Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration firewall simulée"
        return
    fi
    
    # Vérification disponibilité firewalld
    if ! command -v firewall-cmd &> /dev/null; then
        log "⚠️ firewalld non disponible, ignorer configuration firewall"
        return
    fi
    
    if ! systemctl is-active --quiet firewalld; then
        log "⚠️ firewalld inactif, ignorer configuration firewall"
        return
    fi
    
    # Configuration ports Kafka et ZooKeeper
    local kafka_ports=("9092/tcp" "2181/tcp")
    
    for port in "${kafka_ports[@]}"; do
        if ! firewall-cmd --query-port="$port" &>/dev/null; then
            firewall-cmd --permanent --add-port="$port"
            log "✓ Port $port autorisé"
        else
            log "✓ Port $port déjà autorisé"
        fi
    done
    
    # Rechargement configuration
    firewall-cmd --reload
    log "✓ Configuration firewall appliquée et rechargée"
}

# === CRÉATION SERVICE SYSTEMD ===
create_systemd_service() {
    log "Création service systemd Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Création service systemd simulée"
        return
    fi
    
    # Fichier service Kafka
    cat > /etc/systemd/system/kafka.service << EOF
[Unit]
Description=Apache Kafka Broker
Documentation=https://kafka.apache.org/documentation/
Requires=network.target
After=network.target zookeeper.service
Wants=zookeeper.service

[Service]
Type=simple
User=$KAFKA_USER
Group=$KAFKA_GROUP
ExecStart=$KAFKA_HOME/bin/kafka-server-start.sh $KAFKA_HOME/config/server.properties
ExecStop=$KAFKA_HOME/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
KillMode=process

# Variables d'environnement
Environment=JAVA_HOME=$JAVA_HOME
Environment=KAFKA_HEAP_OPTS=-Xmx$JVM_HEAP_SIZE -Xms$JVM_HEAP_SIZE
Environment=KAFKA_JVM_PERFORMANCE_OPTS=-server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35
Environment=KAFKA_GC_LOG_OPTS=-Xlog:gc*:$KAFKA_LOGS_DIR/kafka-gc.log:time,tags

# Sécurité (PCI-DSS/ANSSI-BP-028)
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$KAFKA_DATA_DIR $KAFKA_LOGS_DIR
PrivateDevices=yes
PrivateTmp=yes

# Ressources
LimitNOFILE=65536
LimitNPROC=32768

[Install]
WantedBy=multi-user.target
EOF
    
    # Rechargement et activation service
    systemctl daemon-reload
    systemctl enable kafka
    
    log "✓ Service systemd kafka créé et activé"
}

# === VALIDATION INSTALLATION ===
validate_installation() {
    log "Validation installation Kafka..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Validation installation simulée"
        return
    fi
    
    # Vérification fichiers Kafka
    local kafka_files=("$KAFKA_HOME/bin/kafka-server-start.sh" "$KAFKA_HOME/config/server.properties")
    for file in "${kafka_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error_exit "Fichier Kafka manquant: $file"
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
    
    # Vérification règles firewall (optionnelle si firewalld actif)
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        if ! firewall-cmd --query-port=9092/tcp &>/dev/null; then
            log "ATTENTION: Port TCP/9092 (Kafka) non autorisé par firewall"
        fi
        if ! firewall-cmd --query-port=2181/tcp &>/dev/null; then
            log "ATTENTION: Port TCP/2181 (ZooKeeper) non autorisé par firewall"
        fi
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
    
    # Affichage état --skip-fs-validation
    if [[ "$SKIP_FS_VALIDATION" == "true" ]]; then
        log "⚠️  Mode: Validation filesystem désactivée (--skip-fs-validation)"
    fi
    
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
    configure_firewall
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
    log "VALIDATION FIREWALL:"
    log "  firewall-cmd --list-ports"
    log "  telnet <IP_AUTRE_NOEUD> 9092"
    log "  telnet <IP_AUTRE_NOEUD> 2181"
    log ""
    log "CONFIGURATION UTILISÉE:"
    for node_id in $(printf '%s\n' "${!KAFKA_NODES[@]}" | sort -n); do
        log "  Nœud $node_id: ${KAFKA_NODES[$node_id]}"
    done
    
    # Avertissement supplémentaire si validation filesystem désactivée
    if [[ "$SKIP_FS_VALIDATION" == "true" ]]; then
        log ""
        log "⚠️  AVERTISSEMENT: Validation filesystem désactivée"
        log "   Assurez-vous manuellement que :"
        log "   - $KAFKA_DATA_DIR est monté avec au moins 20GB disponibles"
        log "   - $KAFKA_LOGS_DIR est accessible en écriture"
        log "   - Les permissions sont correctes pour l'utilisateur $KAFKA_USER"
    fi
}

# === EXÉCUTION ===
main "$@"