#!/bin/bash
################################################################################
# Script: install_zookeeper.sh
# Version: 4.0.0
# Description: Configuration ZooKeeper depuis installation Kafka ACM Banking
# Author: Philippe.candido@emerging-it.fr
# Date: 2025-07-06
# 
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped
# Prérequis: install_kafka_cluster.sh doit être exécuté EN PREMIER
# 
# CHANGEMENTS MAJEURS v4.0.0:
# - PLUS D'INSTALLATION ZOOKEEPER: utilise les binaires Kafka existants
# - Configuration ZooKeeper depuis /opt/kafka/config/zookeeper.properties
# - Création service systemd utilisant les binaires Kafka
# - Suppression téléchargement et extraction archive ZooKeeper
# - Conservation des fonctionnalités Basher Pro (dry-run, validation, etc.)
# 
# CHANGELOG:
# v4.0.0 - Refactorisation majeure: utilisation binaires Kafka existants
#        - Suppression installation redondante ZooKeeper
#        - Configuration basée sur /opt/kafka/config/zookeeper.properties
#        - Service systemd pointant vers binaires Kafka
#        - Conservation sécurité bancaire et normes ANSSI
# v3.0.0 - Refactorisation complète selon méthode Basher Pro (obsolète)
# v1.0.0 - Version initiale basique (obsolète)
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'echo "ERROR: Ligne $LINENO. Code de sortie: $?" >&2' ERR

SCRIPT_VERSION="4.0.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/zookeeper-config-$(date +%Y%m%d-%H%M%S).log"

# === CONFIGURATION CLUSTER NODES (HÉRITAGE KAFKA) ===
# Cette configuration doit être cohérente avec install_kafka_cluster.sh
declare -A ZK_NODES_DEFAULT=(
    [1]="172.20.2.113"
    [2]="172.20.2.114" 
    [3]="172.20.2.115"
)

# === CONFIGURATION PATHS (UTILISATION BINAIRES KAFKA) ===
KAFKA_HOME="/opt/kafka"
ZK_USER="kafka"
ZK_GROUP="kafka"
ZK_DATA_DIR="/data/zookeeper"
ZK_LOGS_DIR="/var/log/zookeeper"
KAFKA_DIR="/opt/kafka"
JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
ZK_HEAP_SIZE="1g"
ZK_CONFIG_FILE="$KAFKA_HOME/config/zookeeper.properties"

# === VARIABLES GLOBALES ===
NODE_ID=""
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
    
    # Déclaration du tableau associatif ZK_NODES
    declare -gA ZK_NODES
    
    # Vérification variable système KAFKA_NODES (prioritaire pour cohérence)
    if [[ -n "${KAFKA_NODES:-}" ]]; then
        log "Variable système KAFKA_NODES détectée: $KAFKA_NODES"
        log "Source de configuration: Héritage configuration Kafka"
        
        # Parse du format "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
        if [[ "$KAFKA_NODES" =~ ^[0-9]+:[0-9.]+([,][0-9]+:[0-9.]+)*$ ]]; then
            IFS=',' read -ra pairs <<< "$KAFKA_NODES"
            for pair in "${pairs[@]}"; do
                IFS=':' read -r id ip <<< "$pair"
                ZK_NODES[$id]="$ip"
                log "Nœud $id: $ip (depuis KAFKA_NODES)"
            done
        else
            error_exit "Format KAFKA_NODES invalide: $KAFKA_NODES (attendu: 1:IP,2:IP,3:IP)"
        fi
    else
        # Configuration par défaut
        log "Variable KAFKA_NODES non définie, utilisation configuration par défaut"
        for id in "${!ZK_NODES_DEFAULT[@]}"; do
            ZK_NODES[$id]="${ZK_NODES_DEFAULT[$id]}"
            log "Nœud $id: ${ZK_NODES_DEFAULT[$id]} (défaut)"
        done
    fi
    
    # Validation configuration
    if [[ ${#ZK_NODES[@]} -lt 3 ]]; then
        error_exit "Configuration ZK_NODES insuffisante: ${#ZK_NODES[@]} nœuds (minimum 3 requis)"
    fi
    
    log "Configuration ZK_NODES chargée: ${#ZK_NODES[@]} nœuds"
}

# === VÉRIFICATION PRÉREQUIS KAFKA ===
validate_kafka_prerequisites() {
    log "Vérification prérequis Kafka..."
    
    # Vérification installation Kafka
    if [[ ! -d "$KAFKA_HOME" ]]; then
        error_exit "Kafka non installé: répertoire $KAFKA_HOME manquant"
    fi
    
    if [[ ! -f "$KAFKA_HOME/bin/kafka-run-class.sh" ]]; then
        error_exit "Binaires Kafka manquants: $KAFKA_HOME/bin/kafka-run-class.sh"
    fi
    
    if [[ ! -f "$ZK_CONFIG_FILE" ]]; then
        error_exit "Configuration ZooKeeper manquante: $ZK_CONFIG_FILE"
    fi
    
    # Vérification binaires ZooKeeper dans Kafka
    local zk_binaries=(
        "$KAFKA_HOME/bin/zookeeper-server-start.sh"
        "$KAFKA_HOME/bin/zookeeper-server-stop.sh"
        "$KAFKA_HOME/bin/zookeeper-shell.sh"
    )
    
    for binary in "${zk_binaries[@]}"; do
        if [[ ! -f "$binary" ]]; then
            error_exit "Binaire ZooKeeper manquant: $binary"
        fi
    done
    
    # Vérification utilisateur Kafka
    if ! id kafka &>/dev/null; then
        error_exit "Utilisateur kafka manquant (requis pour cohérence permissions)"
    fi
    
    log "✓ Prérequis Kafka validés"
}

# === VALIDATION INTERACTIVE ===
validate_zk_nodes_interactive() {
    echo ""
    echo "=== VALIDATION CONFIGURATION ZOOKEEPER ==="
    echo "Version du script: $SCRIPT_VERSION"
    echo "Mode: Configuration depuis binaires Kafka existants"
    echo ""
    echo "CONFIGURATION CLUSTER:"
    for node_id in $(printf '%s\n' "${!ZK_NODES[@]}" | sort -n); do
        echo "  Nœud ZooKeeper $node_id: ${ZK_NODES[$node_id]}:2181"
    done
    echo ""
    echo "NŒUD CIBLE: $NODE_ID (${ZK_NODES[$NODE_ID]})"
    echo ""
    echo "RÉPERTOIRES:"
    echo "  Binaires ZooKeeper: $KAFKA_HOME/bin/"
    echo "  Configuration: $ZK_CONFIG_FILE"
    echo "  Données: $ZK_DATA_DIR"
    echo "  Logs: $ZK_LOGS_DIR"
    echo ""
    echo "PRÉREQUIS VÉRIFIÉS:"
    echo "  ✓ Installation Kafka: $KAFKA_HOME"
    echo "  ✓ Binaires ZooKeeper inclus dans Kafka"
    echo "  ✓ Configuration de base: $ZK_CONFIG_FILE"
    
    # Vérification service Kafka
    if [[ -f "/etc/systemd/system/kafka.service" ]]; then
        echo "  ✓ Service Kafka configuré"
    else
        echo "  ⚠️  ATTENTION: Service Kafka non détecté!"
        echo "     Le script install_kafka_cluster.sh doit être exécuté EN PREMIER"
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
                log "Configuration annulée par l'utilisateur"
                exit 0
                ;;
            *)
                echo "Réponse invalide. Veuillez répondre par 'oui' (O) ou 'non' (n)."
                ;;
        esac
    done
    
    echo ""
}

# === CONFIGURATION SYSTÈME ===
configure_system() {
    log "Configuration système pour ZooKeeper..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration système simulée"
        return
    fi
    
    # Création utilisateur zookeeper (séparé de kafka pour sécurité)
    if ! id "$ZK_USER" &>/dev/null; then
        useradd -r -s /sbin/nologin -d "$ZK_DATA_DIR" "$ZK_USER"
        log "Utilisateur $ZK_USER créé"
    else
        log "✓ Utilisateur $ZK_USER déjà existant"
    fi
    
    # Création des répertoires avec permissions sécurisées
    local directories=("$ZK_DATA_DIR" "$ZK_LOGS_DIR" "$KAFKA_DIR/logs")
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
        chown "$ZK_USER:$ZK_GROUP" "$dir"
        chmod 750 "$dir"
    done
    
    # Permissions lecture sur binaires Kafka pour utilisateur zookeeper
    usermod -a -G kafka "$ZK_USER"
    
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

# === CONFIGURATION ZOOKEEPER ===
configure_zookeeper() {
    log "Configuration ZooKeeper node ID $NODE_ID..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration ZooKeeper simulée"
        return
    fi
    
    # Sauvegarde configuration originale Kafka
    if [[ ! -f "$ZK_CONFIG_FILE.kafka-original" ]]; then
        cp "$ZK_CONFIG_FILE" "$ZK_CONFIG_FILE.kafka-original"
        log "Sauvegarde configuration originale: $ZK_CONFIG_FILE.kafka-original"
    fi
    
    # Configuration zoo.cfg avec variables pour cluster bancaire
    cat > "$ZK_CONFIG_FILE" << EOF
# === CONFIGURATION ZOOKEEPER CLUSTER BANCAIRE ===
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# Date: $(date)
# Conformité: PCI-DSS, ANSSI-BP-028
# Source: Configuration depuis binaires Kafka

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
        echo "server.$node_id=${ZK_NODES[$node_id]}:2888:3888" >> "$ZK_CONFIG_FILE"
        log "Ajout serveur cluster: server.$node_id=${ZK_NODES[$node_id]}:2888:3888"
    done
    
    # Création fichier myid
    echo "$NODE_ID" > "$ZK_DATA_DIR/myid"
    chown "$ZK_USER:$ZK_GROUP" "$ZK_DATA_DIR/myid"
    chmod 640 "$ZK_DATA_DIR/myid"
    log "Fichier myid créé: $ZK_DATA_DIR/myid (contenu: $NODE_ID)"
    
    # Permissions sécurisées sur configuration
    chown kafka:kafka "$ZK_CONFIG_FILE"
    chmod 640 "$ZK_CONFIG_FILE"
    
    log "Configuration ZooKeeper appliquée"
}

# === CONFIGURATION SELINUX ===
configure_selinux() {
    log "Configuration SELinux pour ZooKeeper..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration SELinux simulée"
        return
    fi
    
    # Vérification statut SELinux
    if ! command -v getenforce &> /dev/null || [[ "$(getenforce)" == "Disabled" ]]; then
        log "SELinux désactivé ou non installé, configuration ignorée"
        return
    fi
    
    # Contextes SELinux pour répertoires ZooKeeper
    local selinux_contexts=(
        "$ZK_DATA_DIR:admin_home_t"
        "$ZK_LOGS_DIR:admin_home_t"
    )
    
    for context_def in "${selinux_contexts[@]}"; do
        IFS=':' read -r path context <<< "$context_def"
        if [[ -d "$path" ]]; then
            semanage fcontext -a -t "$context" "$path(/.*)?" 2>/dev/null || true
            restorecon -R "$path"
            log "Contexte SELinux appliqué: $path -> $context"
        fi
    done
    
    # Politique SELinux pour ports ZooKeeper
    local zk_ports=("2181" "2888" "3888")
    for port in "${zk_ports[@]}"; do
        if ! semanage port -l | grep -q "$port/tcp.*zookeeper_client_port_t"; then
            semanage port -a -t zookeeper_client_port_t -p tcp "$port" 2>/dev/null || true
            log "Port SELinux configuré: $port/tcp"
        fi
    done
    
    log "Configuration SELinux appliquée"
}

# === CONFIGURATION FIREWALL ===
configure_firewall() {
    log "Configuration firewall pour ZooKeeper..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Configuration firewall simulée"
        return
    fi
    
    # Vérification firewalld
    if ! command -v firewall-cmd &> /dev/null; then
        log "Firewalld non installé, configuration ignorée"
        return
    fi
    
    if ! systemctl is-active --quiet firewalld; then
        log "Firewalld inactif, configuration ignorée"
        return
    fi
    
    # Ouverture ports ZooKeeper
    local zk_ports=("2181" "2888" "3888")
    for port in "${zk_ports[@]}"; do
        if ! firewall-cmd --query-port="$port/tcp" &>/dev/null; then
            firewall-cmd --permanent --add-port="$port/tcp"
            log "Port firewall ouvert: $port/tcp"
        else
            log "✓ Port firewall déjà ouvert: $port/tcp"
        fi
    done
    
    # Application configuration
    firewall-cmd --reload
    log "Configuration firewall appliquée"
}

# === CRÉATION SERVICE SYSTEMD ===
create_systemd_service() {
    log "Création service systemd zookeeper..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Création service systemd simulée"
        return
    fi
    
    # Création service ZooKeeper utilisant binaires Kafka
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
Environment=KAFKA_HOME=$KAFKA_HOME
Environment=ZOO_LOG_DIR=$ZK_LOGS_DIR
Environment=ZOO_LOG4J_PROP=INFO,CONSOLE,ROLLINGFILE
Environment=JVMFLAGS="-Xmx$ZK_HEAP_SIZE -Xms$ZK_HEAP_SIZE"
Environment=KAFKA_JVM_PERFORMANCE_OPTS="-Xlog:gc*:file=$ZK_LOGS_DIR/zookeeper-gc.log:time,tags:filecount=10,filesize=100M"
ExecStart=$KAFKA_HOME/bin/zookeeper-server-start.sh $ZK_CONFIG_FILE
ExecStop=$KAFKA_HOME/bin/zookeeper-server-stop.sh
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
ProtectSystem=full
ReadWritePaths=$ZK_DATA_DIR $ZK_LOGS_DIR $KAFKA_DIR/logs
ReadOnlyPaths=$KAFKA_HOME
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
    log "Validation de la configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Validation configuration simulée"
        return
    fi
    
    # Vérification fichiers critiques
    local required_files=(
        "$KAFKA_HOME/bin/zookeeper-server-start.sh"
        "$ZK_CONFIG_FILE"
        "$ZK_DATA_DIR/myid"
        "/etc/systemd/system/zookeeper.service"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error_exit "Fichier manquant: $file"
        fi
    done
    
    # Vérification permissions
    if [[ "$(stat -c %U:%G "$ZK_DATA_DIR")" != "$ZK_USER:$ZK_GROUP" ]]; then
        error_exit "Permissions incorrectes sur $ZK_DATA_DIR"
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
    
    # Vérification configuration cluster dans zookeeper.properties
    local cluster_servers=$(grep -c "^server\." "$ZK_CONFIG_FILE" || echo "0")
    if [[ "$cluster_servers" -lt 3 ]]; then
        error_exit "Configuration cluster insuffisante: $cluster_servers serveurs (minimum 3)"
    fi
    
    log "✓ Validation configuration réussie"
}

# === VÉRIFICATION FILESYSTEM ===
check_zk_filesystem() {
    log "Vérification filesystems ZooKeeper..."
    
    local fs_checks=(
        "$ZK_DATA_DIR:5G:Données ZooKeeper"
        "$ZK_LOGS_DIR:2G:Logs ZooKeeper"
    )
    
    for fs_check in "${fs_checks[@]}"; do
        IFS=':' read -r path min_size description <<< "$fs_check"
        
        if [[ ! -d "$path" ]]; then
            log "⚠️  Répertoire manquant: $path ($description)"
            continue
        fi
        
        local available=$(df -BG "$path" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
        local required=$(echo "$min_size" | sed 's/G//')
        
        if [[ "$available" -lt "$required" ]]; then
            log "⚠️  Espace insuffisant: $path ($available G disponible, $min_size requis)"
        else
            log "✓ Filesystem OK: $path ($available G disponible)"
        fi
    done
}

# === PARSING ARGUMENTS ===
parse_arguments() {
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
                error_exit "Option inconnue: $1"
                ;;
        esac
    done
    
    # Validation NODE_ID obligatoire (sauf pour check-fs)
    if [[ -z "$NODE_ID" && "$CHECK_FS_ONLY" != "true" ]]; then
        error_exit "NODE_ID obligatoire (-n|--node-id)"
    fi
    
    if [[ -n "$NODE_ID" && ! "$NODE_ID" =~ ^[1-3]$ ]]; then
        error_exit "NODE_ID invalide: $NODE_ID (valeurs autorisées: 1, 2, 3)"
    fi
}

# === HELP FUNCTION ===
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Configuration ZooKeeper depuis binaires Kafka

DESCRIPTION:
    Ce script configure ZooKeeper en utilisant les binaires inclus dans Kafka.
    Il ne télécharge PAS ZooKeeper séparément mais utilise l'installation Kafka existante.

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    -h, --help              Afficher cette aide
    -v, --version           Afficher la version
    -n, --node-id NUM       ID du nœud ZooKeeper (1-3)
    --dry-run              Mode test sans modification
    --check-fs             Vérifier seulement les filesystems
    --skip-validation      Ignorer la validation interactive (mode automatique)
    --force-reinstall      Forcer la reconfiguration même si déjà configuré

EXEMPLES:
    $SCRIPT_NAME -n 1                    # Configuration nœud ZooKeeper ID 1
    $SCRIPT_NAME -n 2 --skip-validation  # Configuration automatique nœud 2
    $SCRIPT_NAME --check-fs              # Vérification filesystems seulement
    $SCRIPT_NAME -n 1 --dry-run          # Test configuration sans modification

PRÉREQUIS:
    ✓ Script install_kafka_cluster.sh exécuté avec succès
    ✓ Kafka installé dans $KAFKA_HOME
    ✓ Binaires ZooKeeper disponibles dans $KAFKA_HOME/bin/
    ✓ Configuration de base dans $ZK_CONFIG_FILE

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

CHANGEMENTS v4.0.0:
    - Utilisation des binaires ZooKeeper inclus dans Kafka
    - Plus de téléchargement/installation séparée de ZooKeeper
    - Configuration basée sur $ZK_CONFIG_FILE existant
    - Service systemd utilisant $KAFKA_HOME/bin/zookeeper-server-start.sh
    - Conservation de toutes les fonctionnalités de sécurité bancaire

FICHIERS GÉNÉRÉS:
    - $ZK_CONFIG_FILE (configuration cluster)
    - $ZK_DATA_DIR/myid (identifiant nœud)
    - /etc/systemd/system/zookeeper.service (service systemd)
    - /etc/security/limits.d/zookeeper.conf (limites système)

PORTS OUVERTS:
    - 2181/tcp (client ZooKeeper)
    - 2888/tcp (communication inter-nœuds)
    - 3888/tcp (élection leader)
EOF
}

# === FONCTION PRINCIPALE ===
main() {
    log "=== DÉBUT CONFIGURATION ZOOKEEPER v$SCRIPT_VERSION ==="
    log "Mode: Configuration depuis binaires Kafka existants"
    
    # Parse des arguments
    parse_arguments "$@"
    
    # Chargement de la configuration ZK_NODES
    load_zk_nodes_configuration
    
    # Mode vérification filesystem seulement
    if [[ "$CHECK_FS_ONLY" == "true" ]]; then
        check_zk_filesystem
        exit 0
    fi
    
    # Validation prérequis Kafka
    validate_kafka_prerequisites
    
    # Validation interactive (sauf si skip-validation)
    if [[ "$SKIP_VALIDATION" != "true" && "$DRY_RUN" != "true" ]]; then
        validate_zk_nodes_interactive
    fi
    
    log "Configuration nœud: $NODE_ID (${ZK_NODES[$NODE_ID]})"
    log "Binaires ZooKeeper: $KAFKA_HOME/bin/"
    
    # Exécution des étapes de configuration
    configure_system
    configure_zookeeper
    configure_selinux
    configure_firewall
    create_systemd_service
    validate_installation
    
    log "=== CONFIGURATION TERMINÉE ==="
    log "ZooKeeper node $NODE_ID configuré depuis binaires Kafka"
    log ""
    log "PROCHAINES ÉTAPES:"
    log "1. Vérifier configuration: cat $ZK_CONFIG_FILE"
    log "2. Démarrer ZooKeeper: systemctl start zookeeper"
    log "3. Vérifier statut: systemctl status zookeeper"
    log "4. Consulter logs: journalctl -u zookeeper -f"
    log ""
    log "VALIDATION CLUSTER:"
    log "  echo stat | nc localhost 2181"
    log "  echo ruok | nc localhost 2181"
    log "  $KAFKA_HOME/bin/zookeeper-shell.sh localhost:2181"
    log ""
    log "VALIDATION RÉSEAU:"
    log "  telnet ${ZK_NODES[1]} 2181"
    log "  telnet ${ZK_NODES[2]} 2181" 
    log "  telnet ${ZK_NODES[3]} 2181"
    log ""
    log "CONFIGURATION UTILISÉE:"
    for node_id in $(printf '%s\n' "${!ZK_NODES[@]}" | sort -n); do
        log "  Nœud $node_id: ${ZK_NODES[$node_id]}:2181"
    done
    log ""
    log "FICHIERS CONFIGURÉS:"
    log "  Configuration: $ZK_CONFIG_FILE"
    log "  Données: $ZK_DATA_DIR"
    log "  Service: /etc/systemd/system/zookeeper.service"
    log "  Sauvegarde: $ZK_CONFIG_FILE.kafka-original"
}

# === EXÉCUTION ===
main "$@"