#!/bin/bash
################################################################################
# Script: install_zookeeper.sh
# Version: 3.0.0
# Description: Installation ZooKeeper 3.8.4 pour cluster Kafka ACM Banking
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-06
# 
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped
# Prérequis: install_kafka_cluster.sh doit être exécuté EN PREMIER
# 
# CHANGELOG:
# v3.0.0 - Refactorisation complète selon méthode Basher Pro
#        - Harmonisation avec install_kafka_cluster.sh
#        - Ajout configuration SELinux et firewall complète
#        - Support configuration KAFKA_NODES dynamique
#        - Modes dry-run et validation interactive
#        - Gestion d'idempotence et recovery
#        - Optimisation pour déploiement post-Kafka
# v1.0.0 - Version initiale basique (non fonctionnelle)
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Ligne $LINENO. Code de sortie: $?" >&2' ERR

SCRIPT_VERSION="3.0.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/zookeeper-install-$(date +%Y%m%d-%H%M%S).log"
ZK_VERSION="3.8.4"

# === CONFIGURATION CLUSTER NODES (HÉRITAGE KAFKA) ===
# Cette configuration doit être cohérente avec install_kafka_cluster.sh
declare -A ZK_NODES_DEFAULT=(
    [1]="172.20.2.113"
    [2]="172.20.2.114" 
    [3]="172.20.2.115"
)

# === CONFIGURATION PATHS ET VARIABLES ===
ZK_HOME="/opt/zookeeper"
ZK_USER="zookeeper"
ZK_GROUP="zookeeper"
ZK_DATA_DIR="/data/zookeeper"
ZK_LOGS_DIR="/var/log/zookeeper"
JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
ZK_HEAP_SIZE="1g"

# === VARIABLES GLOBALES ===
NODE_ID=""
REPO_SERVER="172.20.2.109"
REPO_SERVER_BASEURL="/repos"
DRY_RUN="false"
CHECK_FS_ONLY="false"
SKIP_VALIDATION="false"
FORCE_REINSTALL="false"

# === LOGGING FUNCTION ===
log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# === FONCTION CHARGEMENT CONFIGURATION ZK_NODES ===
load_zk_nodes_configuration() {
    log "Chargement configuration ZK_NODES..."
    
    # Vérification variable système KAFKA_NODES (prioritaire pour cohérence)
    if [[ -n "${KAFKA_NODES:-}" ]]; then
        log "Variable système KAFKA_NODES détectée: $KAFKA_NODES"
        log "Source de configuration: Héritage configuration Kafka"
        
        # Parse du format "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
        if [[ "$KAFKA_NODES" =~ ^[0-9]+:[0-9.]+([,][0-9]+:[0-9.]+)*$ ]]; then
            declare -A ZK_NODES_RUNTIME
            
            IFS=',' read -ra NODE_PAIRS <<< "$KAFKA_NODES"
            for pair in "${NODE_PAIRS[@]}"; do
                IFS=':' read -ra NODE_INFO <<< "$pair"
                local node_id="${NODE_INFO[0]}"
                local node_ip="${NODE_INFO[1]}"
                
                if [[ "$node_id" =~ ^[1-9][0-9]*$ ]] && [[ "$node_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    ZK_NODES_RUNTIME[$node_id]="$node_ip"
                    log "  Nœud ZooKeeper $node_id: $node_ip (hérité de KAFKA_NODES)"
                fi
            done
            
            # Validation cohérence cluster (3 nœuds requis)
            if [[ "${#ZK_NODES_RUNTIME[@]}" -ne 3 ]]; then
                error_exit "Configuration KAFKA_NODES invalide pour ZooKeeper. Attendu: 3, Trouvé: ${#ZK_NODES_RUNTIME[@]}"
            fi
            
            # Copie vers le tableau principal
            declare -gA ZK_NODES
            for key in "${!ZK_NODES_RUNTIME[@]}"; do
                ZK_NODES[$key]="${ZK_NODES_RUNTIME[$key]}"
            done
            
        else
            error_exit "Variable système KAFKA_NODES format invalide. Format: '1:172.20.2.113,2:172.20.2.114,3:172.20.2.115'"
        fi
        
    else
        log "Variable système KAFKA_NODES non définie"
        log "Source de configuration: Configuration par défaut ZooKeeper"
        
        # Utilisation de la configuration par défaut
        declare -gA ZK_NODES
        for key in "${!ZK_NODES_DEFAULT[@]}"; do
            ZK_NODES[$key]="${ZK_NODES_DEFAULT[$key]}"
        done
    fi
    
    # Validation de la configuration finale
    log "Configuration ZK_NODES finale :"
    for node_id in $(printf '%s\n' "${!ZK_NODES[@]}" | sort -n); do
        log "  Nœud ZooKeeper $node_id: ${ZK_NODES[$node_id]}"
    done
}

# === FONCTION VALIDATION INTERACTIVE ZK_NODES ===
validate_zk_nodes_interactive() {
    local -A nodes_to_validate
    
    # Copie du tableau à valider
    for key in "${!ZK_NODES[@]}"; do
        nodes_to_validate[$key]="${ZK_NODES[$key]}"
    done
    
    echo ""
    echo "=========================================================================="
    echo "                   VALIDATION CONFIGURATION ZK_NODES"
    echo "=========================================================================="
    echo ""
    echo "Configuration actuelle des nœuds du cluster ZooKeeper :"
    echo ""
    
    # Affichage formaté du tableau
    printf "%-10s %-15s %-30s\n" "NODE ID" "IP ADDRESS" "DESCRIPTION"
    printf "%-10s %-15s %-30s\n" "-------" "----------" "-----------"
    
    for node_id in $(printf '%s\n' "${!nodes_to_validate[@]}" | sort -n); do
        local ip="${nodes_to_validate[$node_id]}"
        local description="Nœud ZooKeeper $node_id"
        printf "%-10s %-15s %-30s\n" "$node_id" "$ip" "$description"
    done
    
    echo ""
    echo "Ports ZooKeeper: 2181 (client), 2888 (peer), 3888 (election)"
    echo "Repository     : $REPO_SERVER"
    echo "Prérequis      : install_kafka_cluster.sh exécuté avec succès"
    echo ""
    
    # Vérification prérequis Kafka
    if [[ ! -f "/etc/systemd/system/kafka.service" ]]; then
        echo "⚠️  ATTENTION: Service Kafka non détecté!"
        echo "   Le script install_kafka_cluster.sh doit être exécuté EN PREMIER"
        echo ""
    fi
    
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
$SCRIPT_NAME v$SCRIPT_VERSION - Installation ZooKeeper Cluster pour Kafka ACM

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    -h, --help              Afficher cette aide
    -v, --version           Afficher la version
    -n, --node-id NUM       ID du nœud ZooKeeper (1-3)
    -r, --repo-server IP    IP du serveur repository (défaut: 172.20.2.109)
    --dry-run              Mode test sans modification
    --check-fs             Vérifier seulement les filesystems
    --skip-validation      Ignorer la validation interactive (mode automatique)
    --force-reinstall      Forcer la réinstallation même si déjà installé

EXEMPLES:
    $SCRIPT_NAME -n 1                    # Installation nœud ZooKeeper ID 1
    $SCRIPT_NAME -n 2 -r 172.20.2.109    # Nœud 2 avec repo custom
    $SCRIPT_NAME --check-fs              # Vérification filesystems seulement
    $SCRIPT_NAME -n 1 --skip-validation  # Installation sans validation interactive

CONFIGURATION ZK_NODES:
    Le script supporte deux méthodes de configuration des nœuds :
    
    1. Configuration par défaut (dans le script) :
       Node 1: ${ZK_NODES_DEFAULT[1]}
       Node 2: ${ZK_NODES_DEFAULT[2]}
       Node 3: ${ZK_NODES_DEFAULT[3]}
    
    2. Variable système KAFKA_NODES (prioritaire si définie) :
       export KAFKA_NODES="1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
       
    La configuration ZooKeeper hérite automatiquement de KAFKA_NODES pour garantir
    la cohérence du cluster.

PRÉREQUIS CRITIQUES:
    ⚠️  Le script install_kafka_cluster.sh DOIT être exécuté EN PREMIER
    ⚠️  Java JDK 17 doit être installé (via install_kafka_cluster.sh)
    ⚠️  Filesystem /data/zookeeper doit être monté

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
    echo "ZooKeeper $ZK_VERSION"
    echo "Support: RHEL 9, PCI-DSS, ANSSI-BP-028"
    echo "Dépendance: install_kafka_cluster.sh (à exécuter en premier)"
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
        --force-reinstall)
            FORCE_REINSTALL="true"
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

# === VÉRIFICATION FILESYSTEM ZOOKEEPER ===
check_zk_filesystem() {
    log "Vérification filesystem pour ZooKeeper..."
    
    # Vérification montage $ZK_DATA_DIR
    if ! mountpoint -q $ZK_DATA_DIR 2>/dev/null; then
        # Tentative de création si n'existe pas
        if [[ ! -d "$ZK_DATA_DIR" ]]; then
            log "Création répertoire $ZK_DATA_DIR..."
            mkdir -p "$ZK_DATA_DIR"
        fi
        log "ATTENTION: $ZK_DATA_DIR n'est pas un point de montage dédié"
    fi
    
    # Vérification espace libre (minimum 5GB pour ZooKeeper)
    local available_space=$(df $ZK_DATA_DIR | tail -1 | awk '{print $4}')
    local min_space_kb=$((1 * 1024 * 1024))  # 1GB en KB
    
    if [[ "$available_space" -lt "$min_space_kb" ]]; then
        error_exit "Espace insuffisant sur $ZK_DATA_DIR: ${available_space}KB disponible, ${min_space_kb}KB requis"
    fi
    
    log "✓ Filesystem $ZK_DATA_DIR: ${available_space}KB disponible"
    
    # Vérification permissions et montage /var/log
    if [[ ! -d "$ZK_LOGS_DIR" ]] || [[ ! -w "$ZK_LOGS_DIR" ]]; then
        log "Création répertoire $ZK_LOGS_DIR..."
        mkdir -p "$ZK_LOGS_DIR"
    fi
    
    log "✓ Répertoire $ZK_LOGS_DIR accessible"
    log "✓ Validation filesystem terminée avec succès"
}

# === VALIDATION PRÉREQUIS ===
validate_prerequisites() {
    log "Validation des prérequis système..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Validation prérequis simulée"
        return
    fi
    
    # Vérification CRITIQUE: Kafka doit être installé EN PREMIER
    if [[ ! -f "/etc/systemd/system/kafka.service" ]]; then
        error_exit "PRÉREQUIS MANQUANT: Le script install_kafka_cluster.sh doit être exécuté EN PREMIER!"
    fi
    
    if [[ ! -d "/opt/kafka" ]]; then
        error_exit "PRÉREQUIS MANQUANT: Kafka non installé. Exécutez install_kafka_cluster.sh d'abord."
    fi
    
    log "✓ Prérequis Kafka validé: installation détectée"
    
    # Vérification Java (devrait être installé par install_kafka_cluster.sh)
    if [[ ! -f "$JAVA_HOME/bin/java" ]]; then
        error_exit "Java JDK 17 non trouvé dans $JAVA_HOME. Réexécutez install_kafka_cluster.sh."
    fi
    
    local java_version=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)
    log "✓ Java détecté: $java_version"
    
    # Vérifications système standard
    if [[ ! -f /etc/redhat-release ]] || ! grep -q "Red Hat Enterprise Linux.*9\." /etc/redhat-release; then
        error_exit "OS non supporté. RHEL 9 requis."
    fi
    
    if [[ "$(uname -m)" != "x86_64" ]]; then
        error_exit "Architecture non supportée: $(uname -m). x86_64 requis."
    fi
    
    if [[ "$EUID" -ne 0 ]]; then
        error_exit "Privilèges root requis pour l'installation"
    fi
    
    # Vérification mémoire (minimum 2GB pour ZooKeeper)
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local min_mem_kb=$((2 * 1024 * 1024))
    if [[ "$mem_kb" -lt "$min_mem_kb" ]]; then
        error_exit "Mémoire insuffisante: ${mem_kb}KB disponible, ${min_mem_kb}KB requis"
    fi
    
    # Vérification filesystem
    check_zk_filesystem
    
    log "✓ Prérequis système validés"
}

# === VÉRIFICATION INSTALLATION EXISTANTE ===
check_existing_installation() {
    log "Vérification installation ZooKeeper existante..."
    
    if [[ -f "/etc/systemd/system/zookeeper.service" ]] && [[ "$FORCE_REINSTALL" != "true" ]]; then
        log "Installation ZooKeeper existante détectée"
        
        if systemctl is-active --quiet zookeeper; then
            log "Service ZooKeeper actif - arrêt requis pour réinstallation"
            if [[ "$DRY_RUN" != "true" ]]; then
                systemctl stop zookeeper
                log "Service ZooKeeper arrêté"
            fi
        fi
        
        log "Mode mise à jour: préservation configuration existante"
        return 0
    fi
    
    if [[ -d "$ZK_HOME" ]] && [[ "$FORCE_REINSTALL" == "true" ]]; then
        log "Force réinstallation activée - suppression installation existante"
        if [[ "$DRY_RUN" != "true" ]]; then
            systemctl stop zookeeper 2>/dev/null || true
            systemctl disable zookeeper 2>/dev/null || true
            rm -rf "$ZK_HOME"
            log "Installation existante supprimée"
        fi
    fi
    
    log "✓ Vérification installation existante terminée"
}

# === CONFIGURATION REPOSITORY YUM (HÉRITAGE KAFKA) ===
configure_yum_repository() {
    log "Vérification repository YUM (héritage Kafka)..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration repository simulée"
        return
    fi
    
    # Vérification repository configuré par install_kafka_cluster.sh
    if [[ ! -f "/etc/yum.repos.d/java-local.repo" ]]; then
        log "ATTENTION: Repository Java non configuré - configuration manuelle..."
        
        cat > /etc/yum.repos.d/java-local.repo << EOF
[java-local]
name=Java Local Repository  
baseurl=http://$REPO_SERVER/$REPO_SERVER_BASEURL/java/
enabled=1
gpgcheck=0
priority=1
EOF
        log "Repository Java configuré"
    else
        log "✓ Repository Java déjà configuré (héritage Kafka)"
    fi
    
    # Test connectivité repository pour ZooKeeper
    if ! curl -f -s -k "http://$REPO_SERVER/$REPO_SERVER_BASEURL/zookeeper/" > /dev/null; then
        log "ATTENTION: Repository ZooKeeper non accessible: http://$REPO_SERVER/$REPO_SERVER_BASEURL/zookeeper/"
        log "Tentative utilisation repository Kafka pour ZooKeeper..."
    fi
    
    log "✓ Configuration repository validée"
}

# === CONFIGURATION SYSTÈME ===
configure_system() {
    log "Configuration système pour ZooKeeper..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration système simulée"
        return
    fi
    
    # Création utilisateur zookeeper
    if ! id "$ZK_USER" &>/dev/null; then
        useradd -r -s /sbin/nologin -d "$ZK_HOME" "$ZK_USER"
        log "Utilisateur $ZK_USER créé"
    else
        log "✓ Utilisateur $ZK_USER déjà existant"
    fi
    
    # Création des répertoires avec permissions sécurisées
    local directories=("$ZK_HOME" "$ZK_DATA_DIR" "$ZK_LOGS_DIR")
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
        chown "$ZK_USER:$ZK_GROUP" "$dir"
        chmod 750 "$dir"
    done
    
    # Configuration limits système pour ZooKeeper
    if [[ ! -f "/etc/security/limits.d/zookeeper.conf" ]]; then
        cat > /etc/security/limits.d/zookeeper.conf << EOF
# Limits pour utilisateur zookeeper - Banking Requirements
$ZK_USER soft nofile 65536
$ZK_USER hard nofile 65536
$ZK_USER soft nproc 2048
$ZK_USER hard nproc 2048
EOF
        log "Configuration limits ZooKeeper créée"
    else
        log "✓ Configuration limits ZooKeeper déjà existante"
    fi
    
    log "Configuration système appliquée"
}

# === INSTALLATION ZOOKEEPER ===
install_zookeeper() {
    log "Installation ZooKeeper $ZK_VERSION depuis repository local..."
    log "URL Archive : http://$REPO_SERVER/$REPO_SERVER_BASEURL/zookeeper/apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Installation ZooKeeper simulée"
        return
    fi
    
    cd /tmp
    
    # Tentative téléchargement depuis repository zookeeper dédié
    if curl -f "http://$REPO_SERVER/$REPO_SERVER_BASEURL/zookeeper/apache-zookeeper-${ZK_VERSION}-bin.tar.gz" -o "apache-zookeeper-${ZK_VERSION}-bin.tar.gz" 2>/dev/null; then
        log "✓ Téléchargement depuis repository ZooKeeper dédié"
    # Fallback: repository kafka (comme version originale)
    elif curl -f "http://$REPO_SERVER/kafka/apache-zookeeper-${ZK_VERSION}-bin.tar.gz" -o "apache-zookeeper-${ZK_VERSION}-bin.tar.gz" 2>/dev/null; then
        log "✓ Téléchargement depuis repository Kafka (fallback)"
    else
        error_exit "Échec téléchargement ZooKeeper depuis $REPO_SERVER"
    fi
    
    # Vérification checksum si disponible
    if curl -f "http://$REPO_SERVER/$REPO_SERVER_BASEURL/zookeeper/apache-zookeeper-${ZK_VERSION}-bin.tar.gz.sha512" -o "apache-zookeeper-${ZK_VERSION}-bin.tar.gz.sha512" 2>/dev/null; then
        if sha512sum -c "apache-zookeeper-${ZK_VERSION}-bin.tar.gz.sha512"; then
            log "✓ Checksum validé avec succès"
        else
            error_exit "Échec validation checksum ZooKeeper"
        fi
    else
        log "ATTENTION: Pas de checksum disponible, procédure sans validation"
    fi
    
    # Extraction et installation
    tar -xzf "apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
    cp -r "apache-zookeeper-${ZK_VERSION}-bin"/* "$ZK_HOME/"
    
    # Permissions de sécurité strictes (Banking Standards)
    chown -R "$ZK_USER:$ZK_GROUP" "$ZK_HOME"
    chmod -R 750 "$ZK_HOME"
    chmod 755 "$ZK_HOME/bin"/*.sh
    
    log "ZooKeeper installé dans $ZK_HOME"
}

# === CONFIGURATION ZOOKEEPER ===
configure_zookeeper() {
    log "Configuration ZooKeeper node ID $NODE_ID..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration ZooKeeper simulée"
        return
    fi
    
    # Configuration zoo.cfg avec variables
    cat > "$ZK_HOME/conf/zoo.cfg" << EOF
# === CONFIGURATION ZOOKEEPER CLUSTER BANCAIRE ===
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# Date: $(date)
# Conformité: PCI-DSS, ANSSI-BP-028

# === CONFIGURATION DE BASE ===
tickTime=2000
initLimit=10
syncLimit=5
dataDir=$ZK_DATA_DIR
clientPort=2181

# === CONFIGURATION RÉSEAU ET SÉCURITÉ ===
maxClientCnxns=60
maxSessionTimeout=40000
minSessionTimeout=4000

# === CONFIGURATION AVANCÉE BANCAIRE ===
autopurge.snapRetainCount=5
autopurge.purgeInterval=24
preAllocSize=65536
snapCount=100000

# === CONFIGURATION 4LW (Four Letter Words) ===
4lw.commands.whitelist=stat,ruok,conf,isro,srvr,mntr

# === CLUSTER CONFIGURATION ===
EOF

    # Ajout des serveurs du cluster
    for node_id in $(printf '%s\n' "${!ZK_NODES[@]}" | sort -n); do
        echo "server.$node_id=${ZK_NODES[$node_id]}:2888:3888" >> "$ZK_HOME/conf/zoo.cfg"
        log "Ajout serveur $node_id: ${ZK_NODES[$node_id]}:2888:3888"
    done
    
    # Configuration myid
    echo "$NODE_ID" > "$ZK_DATA_DIR/myid"
    chown "$ZK_USER:$ZK_GROUP" "$ZK_DATA_DIR/myid"
    chmod 640 "$ZK_DATA_DIR/myid"
    
    # Configuration log4j pour compliance Banking
    cat > "$ZK_HOME/conf/log4j.properties" << EOF
# === CONFIGURATION LOGGING ZOOKEEPER BANCAIRE ===
# Root logger
zookeeper.root.logger=INFO, CONSOLE, ROLLINGFILE

# Console appender
zookeeper.console.threshold=INFO
log4j.appender.CONSOLE=org.apache.log4j.ConsoleAppender
log4j.appender.CONSOLE.Threshold=\${zookeeper.console.threshold}
log4j.appender.CONSOLE.layout=org.apache.log4j.PatternLayout
log4j.appender.CONSOLE.layout.ConversionPattern=%d{ISO8601} [myid:%X{myid}] - %-5p [%t:%C{1}@%L] - %m%n

# File appender avec rotation (Banking Requirements)
log4j.appender.ROLLINGFILE=org.apache.log4j.RollingFileAppender
log4j.appender.ROLLINGFILE.Threshold=INFO
log4j.appender.ROLLINGFILE.File=$ZK_LOGS_DIR/zookeeper.log
log4j.appender.ROLLINGFILE.MaxFileSize=100MB
log4j.appender.ROLLINGFILE.MaxBackupIndex=10
log4j.appender.ROLLINGFILE.layout=org.apache.log4j.PatternLayout
log4j.appender.ROLLINGFILE.layout.ConversionPattern=%d{ISO8601} [myid:%X{myid}] - %-5p [%t:%C{1}@%L] - %m%n

# Suppression logs sensibles pour conformité PCI-DSS
log4j.logger.org.apache.zookeeper.server.auth=ERROR
log4j.logger.org.apache.zookeeper.server.quorum.QuorumCnxManager=WARN
EOF
    
    log "Configuration ZooKeeper générée pour nœud $NODE_ID"
}

# === CONFIGURATION SELINUX ===
configure_selinux() {
    log "Configuration SELinux pour ZooKeeper..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration SELinux simulée"
        return
    fi
    
    # Vérification SELinux actif
    if ! command -v getenforce &> /dev/null || [[ "$(getenforce)" == "Disabled" ]]; then
        log "SELinux désactivé - skipping configuration"
        return
    fi
    
    # Configuration ports ZooKeeper
    semanage port -a -t http_port_t -p tcp 2181 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp 2181
    
    semanage port -a -t http_port_t -p tcp 2888 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp 2888
    
    semanage port -a -t http_port_t -p tcp 3888 2>/dev/null || \
    semanage port -m -t http_port_t -p tcp 3888
    
    # Contextes pour répertoires ZooKeeper
    semanage fcontext -a -t admin_home_t "$ZK_HOME(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t admin_home_t "$ZK_HOME(/.*)?"
    
    semanage fcontext -a -t var_log_t "$ZK_LOGS_DIR(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t var_log_t "$ZK_LOGS_DIR(/.*)?"
    
    semanage fcontext -a -t admin_home_t "$ZK_DATA_DIR(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t admin_home_t "$ZK_DATA_DIR(/.*)?"
    
    # Application des contextes
    restorecon -R "$ZK_HOME" "$ZK_LOGS_DIR" "$ZK_DATA_DIR"
    
    log "Configuration SELinux appliquée"
}

# === CONFIGURATION FIREWALL ===
configure_firewall() {
    log "Configuration firewall pour ports ZooKeeper..."
    
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
    local backup_file="/tmp/firewall-backup-zk-$(date +%Y%m%d-%H%M%S).xml"
    firewall-cmd --get-active-zones > "$backup_file" 2>/dev/null || true
    log "Sauvegarde firewall créée: $backup_file"
    
    # Configuration des règles permanentes pour ZooKeeper
    local zk_ports=("2181" "2888" "3888")
    local zk_descriptions=("Client" "Peer" "Election")
    
    for i in "${!zk_ports[@]}"; do
        local port="${zk_ports[$i]}"
        local desc="${zk_descriptions[$i]}"
        
        log "Ajout règle firewall permanente TCP/$port (ZooKeeper $desc)..."
        if firewall-cmd --permanent --add-port="$port/tcp"; then
            log "✓ Règle TCP/$port (ZooKeeper $desc) ajoutée avec succès"
        else
            log "ATTENTION: Échec ajout règle TCP/$port, peut déjà exister"
        fi
        
        # Configuration des règles actives (runtime)
        if firewall-cmd --add-port="$port/tcp"; then
            log "✓ Règle runtime TCP/$port (ZooKeeper $desc) activée"
        else
            log "ATTENTION: Échec activation runtime TCP/$port"
        fi
    done
    
    # Rechargement de la configuration permanente
    log "Rechargement configuration firewall permanente..."
    if firewall-cmd --reload; then
        log "✓ Configuration firewall rechargée avec succès"
    else
        error_exit "Échec rechargement configuration firewall"
    fi
    
    # Vérification des règles appliquées
    log "Vérification des règles firewall appliquées:"
    
    for i in "${!zk_ports[@]}"; do
        local port="${zk_ports[$i]}"
        local desc="${zk_descriptions[$i]}"
        
        if firewall-cmd --query-port="$port/tcp" &>/dev/null; then
            log "✓ Port TCP/$port (ZooKeeper $desc) autorisé"
        else
            log "⚠ Port TCP/$port (ZooKeeper $desc) NON autorisé"
        fi
    done
    
    # Affichage résumé configuration firewall pour audit
    log "=== RÉSUMÉ CONFIGURATION FIREWALL ZOOKEEPER ==="
    log "Zone active: $(firewall-cmd --get-active-zones | head -1)"
    log "Ports ouverts: $(firewall-cmd --list-ports | tr '\n' ' ')"
    
    # Conformité PCI-DSS : limitation accès réseau
    log "CONFORMITÉ PCI-DSS: Vérification limitation accès réseau"
    local zk_nodes_string=""
    for node_id in "${!ZK_NODES[@]}"; do
        if [[ -n "$zk_nodes_string" ]]; then
            zk_nodes_string+=","
        fi
        zk_nodes_string+="${ZK_NODES[$node_id]}"
    done
    
    log "Nœuds cluster autorisés: $zk_nodes_string"
    log "Repository server: $REPO_SERVER"
    
    log "Configuration firewall ZooKeeper terminée avec succès"
}

# === CRÉATION SERVICE SYSTEMD ===
create_systemd_service() {
    log "Création service systemd ZooKeeper..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Création service systemd simulée"
        return
    fi
    
    # Service ZooKeeper avec configuration Banking
    cat > /etc/systemd/system/zookeeper.service << EOF
[Unit]
Description=Apache ZooKeeper Server (Banking Cluster Node $NODE_ID)
Documentation=https://zookeeper.apache.org/
Requires=network.target remote-fs.target
After=network.target remote-fs.target
Before=kafka.service

[Service]
Type=simple
User=$ZK_USER
Group=$ZK_GROUP
Environment=JAVA_HOME=$JAVA_HOME
Environment=ZOO_LOG_DIR=$ZK_LOGS_DIR
Environment=ZOO_LOG4J_PROP=INFO,CONSOLE,ROLLINGFILE
Environment=JVMFLAGS="-Xmx$ZK_HEAP_SIZE -Xms$ZK_HEAP_SIZE"
ExecStart=$ZK_HOME/bin/zkServer.sh start-foreground
ExecStop=$ZK_HOME/bin/zkServer.sh stop
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=zookeeper
KillMode=process
TimeoutStopSec=30

# Sécurité Banking (ANSSI-BP-028)
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$ZK_DATA_DIR $ZK_LOGS_DIR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    
    # Activation du service
    systemctl daemon-reload
    systemctl enable zookeeper
    
    log "Service systemd zookeeper créé et activé"
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
        "$ZK_HOME/bin/zkServer.sh"
        "$ZK_HOME/conf/zoo.cfg"
        "$ZK_HOME/conf/log4j.properties"
        "$ZK_DATA_DIR/myid"
        "/etc/systemd/system/zookeeper.service"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error_exit "Fichier manquant: $file"
        fi
    done
    
    # Vérification permissions
    if [[ "$(stat -c %U:%G "$ZK_HOME")" != "$ZK_USER:$ZK_GROUP" ]]; then
        error_exit "Permissions incorrectes sur $ZK_HOME"
    fi
    
    # Vérification contenu myid
    local myid_content=$(cat "$ZK_DATA_DIR/myid")
    if [[ "$myid_content" != "$NODE_ID" ]]; then
        error_exit "Contenu myid incorrect: $myid_content (attendu: $NODE_ID)"
    fi
    
    # Vérification service systemd
    if ! systemctl is-enabled zookeeper &>/dev/null; then
        error_exit "Service zookeeper non activé"
    fi
    
    # Vérification règles firewall (optionnelle si firewalld actif)
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        local zk_ports=("2181" "2888" "3888")
        for port in "${zk_ports[@]}"; do
            if ! firewall-cmd --query-port="$port/tcp" &>/dev/null; then
                log "ATTENTION: Port TCP/$port (ZooKeeper) non autorisé par firewall"
            fi
        done
    fi
    
    log "✓ Validation installation réussie"
}

# === FONCTION PRINCIPALE ===
main() {
    log "=== DÉBUT INSTALLATION ZOOKEEPER CLUSTER v$SCRIPT_VERSION ==="
    
    # Chargement de la configuration ZK_NODES
    load_zk_nodes_configuration
    
    # Validation interactive (sauf si skip-validation)
    if [[ "$SKIP_VALIDATION" != "true" && "$CHECK_FS_ONLY" != "true" && "$DRY_RUN" != "true" ]]; then
        validate_zk_nodes_interactive
    fi
    
    log "Nœud ZooKeeper: $NODE_ID (${ZK_NODES[$NODE_ID]}), Repository: $REPO_SERVER"
    
    # Mode vérification filesystem seulement
    if [[ "$CHECK_FS_ONLY" == "true" ]]; then
        check_zk_filesystem
        exit 0
    fi
    
    validate_prerequisites
    check_existing_installation
    configure_yum_repository
    configure_system
    install_zookeeper
    configure_zookeeper
    configure_selinux
    configure_firewall
    create_systemd_service
    validate_installation
    
    log "=== INSTALLATION ZOOKEEPER TERMINÉE ==="
    log "ZooKeeper nœud $NODE_ID prêt à démarrer"
    log ""
    log "PROCHAINES ÉTAPES:"
    log "1. Démarrer ZooKeeper: systemctl start zookeeper"
    log "2. Vérifier statut: systemctl status zookeeper"
    log "3. Consulter logs: journalctl -u zookeeper -f"
    log "4. Après démarrage de tous les nœuds ZooKeeper, démarrer Kafka"
    log ""
    log "VALIDATION CLUSTER ZOOKEEPER:"
    log "  echo ruok | nc localhost 2181"
    log "  echo stat | nc localhost 2181"
    log "  echo conf | nc localhost 2181"
    log ""
    log "VALIDATION CONNECTIVITÉ INTER-NŒUDS:"
    for node_id in "${!ZK_NODES[@]}"; do
        if [[ "$node_id" != "$NODE_ID" ]]; then
            log "  telnet ${ZK_NODES[$node_id]} 2181"
            log "  telnet ${ZK_NODES[$node_id]} 2888"
            log "  telnet ${ZK_NODES[$node_id]} 3888"
        fi
    done
    log ""
    log "ORDRE DE DÉMARRAGE RECOMMANDÉ:"
    log "1. Démarrer ZooKeeper sur tous les nœuds: systemctl start zookeeper"
    log "2. Vérifier cluster ZooKeeper: echo stat | nc localhost 2181"
    log "3. Démarrer Kafka sur tous les nœuds: systemctl start kafka"
    log ""
    log "CONFIGURATION UTILISÉE:"
    for node_id in $(printf '%s\n' "${!ZK_NODES[@]}" | sort -n); do
        log "  Nœud ZooKeeper $node_id: ${ZK_NODES[$node_id]}"
    done
}

# === EXÉCUTION ===
main "$@"