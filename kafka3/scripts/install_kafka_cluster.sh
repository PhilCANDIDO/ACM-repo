#!/bin/bash
################################################################################
# Script: install_kafka_cluster.sh
# Version: 2.2.0
# Description: Installation Kafka 3.9.0 en cluster HA pour ACM Banking avec firewall
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-06
#
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped
#
# CHANGELOG:
# v2.2.0 - Ajout configuration automatique firewall TCP/9092 et TCP/2181
# v2.1.0 - Ajout validation interactive KAFKA_NODES et support variable système
# v2.0.0 - Refactorisation avec RPM Java, variables nœuds, vérification filesystem
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Ligne $LINENO. Code de sortie: $?" >&2' ERR

SCRIPT_VERSION="2.2.0"
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
REPO_SERVER_BASEURL="/repos"
DRY_RUN="false"
CHECK_FS_ONLY="false"
SKIP_VALIDATION="false"

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
                    log "Nœud $node_id configuré: $node_ip"
                else
                    error_exit "Format invalide dans KAFKA_NODES: $pair"
                fi
            done

            # Validation minimum 3 nœuds
            if [[ ${#KAFKA_NODES_RUNTIME[@]} -lt 3 ]]; then
                log "ATTENTION: Moins de 3 nœuds configurés. Attendu: 3, Trouvé: ${#KAFKA_NODES_RUNTIME[@]}"
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
        echo -n "Voulez-vous continuer avec cette configuration ? [O/n]: "
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

    # Vérification montage $KAFKA_DATA_DIR
    if ! mountpoint -q $KAFKA_DATA_DIR; then
        error_exit "Filesystem $KAFKA_DATA_DIR non monté. Requis pour KAFKA_DATA_DIR"
    fi

    # Vérification espace libre
    local available_space=$(df $KAFKA_DATA_DIR | tail -1 | awk '{print $4}')
    local min_space_kb=$((10 * 1024 * 1024))  # 20GB en KB

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

    # Vérification filesystem
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
    if ! curl -f -s -k "http://$REPO_SERVER/$REPO_SERVER_BASEURL/" > /dev/null; then
        error_exit "Repository server inaccessible: http://$REPO_SERVER/$REPO_SERVER_BASEURL"
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

    # Création utilisateur kafka
    if ! id "$KAFKA_USER" &>/dev/null; then
        useradd -r -s /sbin/nologin -d "$KAFKA_HOME" "$KAFKA_USER"
        log "Utilisateur $KAFKA_USER créé"
    fi

    # Création des répertoires avec permissions sécurisées
    local directories=("$KAFKA_HOME" "$KAFKA_DATA_DIR" "$KAFKA_LOGS_DIR" "$KAFKA_HOME/logs")
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

# === CONFIGURATION FIREWALL KAFKA/ZOOKEEPER ===
configure_firewall() {
    log "Configuration firewall pour ports Kafka/ZooKeeper..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration firewall simulée"
        return
    fi

    # Vérification si firewalld est installé et actif
    if ! command -v firewall-cmd &> /dev/null; then
        log "ATTENTION: firewall-cmd non disponible - skip configuration firewall"
        return
    fi

    if ! systemctl is-active --quiet firewalld; then
        log "ATTENTION: firewalld non actif - skip configuration firewall"
        return
    fi

    # Sauvegarde de la configuration firewall actuelle
    local backup_file="/tmp/firewall-backup-$(date +%Y%m%d-%H%M%S).xml"
    firewall-cmd --get-active-zones > "$backup_file" 2>/dev/null || true
    log "Sauvegarde firewall créée: $backup_file"

    # Configuration des règles permanentes pour Kafka
    log "Ajout règle firewall permanente TCP/9092 (Kafka)..."
    if firewall-cmd --permanent --add-port=9092/tcp; then
        log "✓ Règle TCP/9092 (Kafka) ajoutée avec succès"
    else
        log "ATTENTION: Échec ajout règle TCP/9092, peut déjà exister"
    fi

    # Configuration des règles permanentes pour ZooKeeper
    log "Ajout règle firewall permanente TCP/2181 (ZooKeeper)..."
    if firewall-cmd --permanent --add-port=2181/tcp; then
        log "✓ Règle TCP/2181 (ZooKeeper) ajoutée avec succès"
    else
        log "ATTENTION: Échec ajout règle TCP/2181, peut déjà exister"
    fi

    # Configuration des règles actives (runtime)
    log "Application des règles firewall en cours d'exécution..."
    if firewall-cmd --add-port=9092/tcp; then
        log "✓ Règle runtime TCP/9092 (Kafka) activée"
    else
        log "ATTENTION: Échec activation runtime TCP/9092"
    fi

    if firewall-cmd --add-port=2181/tcp; then
        log "✓ Règle runtime TCP/2181 (ZooKeeper) activée"
    else
        log "ATTENTION: Échec activation runtime TCP/2181"
    fi

    # Rechargement de la configuration permanente
    log "Rechargement configuration firewall permanente..."
    if firewall-cmd --reload; then
        log "✓ Configuration firewall rechargée avec succès"
    else
        error_exit "Échec rechargement configuration firewall"
    fi

    # Vérification des règles appliquées
    log "Vérification des règles firewall appliquées:"

    # Vérification port Kafka
    if firewall-cmd --query-port=9092/tcp &>/dev/null; then
        log "✓ Port TCP/9092 (Kafka) autorisé"
    else
        log "⚠ Port TCP/9092 (Kafka) NON autorisé"
    fi

    # Vérification port ZooKeeper
    if firewall-cmd --query-port=2181/tcp &>/dev/null; then
        log "✓ Port TCP/2181 (ZooKeeper) autorisé"
    else
        log "⚠ Port TCP/2181 (ZooKeeper) NON autorisé"
    fi

    # Affichage résumé configuration firewall pour audit
    log "=== RÉSUMÉ CONFIGURATION FIREWALL ==="
    log "Zone active: $(firewall-cmd --get-active-zones | head -1)"
    log "Ports ouverts: $(firewall-cmd --list-ports | tr '\n' ' ')"
    log "Services autorisés: $(firewall-cmd --list-services | tr '\n' ' ')"

    # Conformité PCI-DSS : limitation accès réseau
    log "CONFORMITÉ PCI-DSS: Vérification limitation accès réseau"
    local kafka_nodes_string=""
    for node_id in "${!KAFKA_NODES[@]}"; do
        if [[ -n "$kafka_nodes_string" ]]; then
            kafka_nodes_string+=","
        fi
        kafka_nodes_string+="${KAFKA_NODES[$node_id]}"
    done

    log "Nœuds cluster autorisés: $kafka_nodes_string"
    log "Repository server: $REPO_SERVER"

    # Note de sécurité bancaire
    log ""
    log "NOTE SÉCURITÉ BANCAIRE:"
    log "- Ports 9092/2181 ouverts uniquement pour communication inter-cluster"
    log "- Accès externe bloqué par défaut (conformité ANSSI-BP-028)"
    log "- Surveillance logs firewall recommandée: journalctl -u firewalld -f"

    log "Configuration firewall terminée avec succès"
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
ProtectSystem=full
ReadWritePaths=$KAFKA_DATA_DIR $KAFKA_LOGS_DIR $KAFKA_HOME/logs
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
}

# === EXÉCUTION ===
main "$@"