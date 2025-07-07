#!/bin/bash
################################################################################
# Script: kafka_cluster_diagnostic.sh
# Version: 1.0.0
# Description: Diagnostic complet cluster Kafka multibroker pour environnement bancaire ACM
# Author: Philippe Candido (philippe.candido@emerging-it.fr)
# Date: 2025-07-07
#
# Conformité: PCI-DSS, ANSSI-BP-028
# Environment: RHEL 9 Air-gapped, Kafka 3.9.1, ZooKeeper 3.8.4
# Architecture: 3 brokers HA (172.20.2.113-115)
#
# CHANGELOG:
# v1.0.0 - Création script diagnostic multibroker selon méthode Basher Pro
#        - Tests ZooKeeper, Kafka, connectivité, logs, API
#        - Support modes dry-run, couleurs, logging
#        - Validation bout en bout avec topics temporaires
#        - Conformité normes bancaires sécurisées
################################################################################

# === CONFIGURATION BASHER PRO ===
set -euo pipefail
trap 'log_error "ERROR: Ligne $LINENO. Code de sortie: $?"' ERR

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE=""
DEFAULT_LOG_FILE="/var/log/kafka-diagnostic-$(date +%Y%m%d-%H%M%S).log"

# === CONFIGURATION KAFKA/ZOOKEEPER ===
KAFKA_HOME="/opt/kafka"
KAFKA_LOGS_DIR="/var/log/kafka"
ZK_PORT="2181"
KAFKA_PORT="9092"
ZK_PEER_PORT="2888"
ZK_ELECTION_PORT="3888"

# === VARIABLES GLOBALES ===
BROKERS_STRING=""
ENABLE_LOGGING="false"
DRY_RUN="false"
VERBOSE="false"
TEST_TOPIC="diag-test-$$"

# === COULEURS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === FONCTIONS LOGGING ===
log_info() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
    echo -e "${BLUE}${message}${NC}"
    [[ "$ENABLE_LOGGING" == "true" ]] && echo "$message" >> "$LOG_FILE"
}

log_success() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $*"
    echo -e "${GREEN}${message}${NC}"
    [[ "$ENABLE_LOGGING" == "true" ]] && echo "$message" >> "$LOG_FILE"
}

log_warning() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $*"
    echo -e "${YELLOW}${message}${NC}"
    [[ "$ENABLE_LOGGING" == "true" ]] && echo "$message" >> "$LOG_FILE"
}

log_error() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    echo -e "${RED}${message}${NC}" >&2
    [[ "$ENABLE_LOGGING" == "true" ]] && echo "$message" >> "$LOG_FILE"
}

# === FONCTION D'AIDE ===
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Diagnostic complet cluster Kafka multibroker

DESCRIPTION:
    Script de diagnostic automatisé pour valider le fonctionnement d'un cluster
    Kafka/ZooKeeper en environnement bancaire sécurisé. Conçu pour les équipes
    d'exploitation L1/L2.

USAGE:
    $SCRIPT_NAME --brokers "BROKER_CONFIG" [OPTIONS]

ARGUMENTS OBLIGATOIRES:
    --brokers "ID1:IP1,ID2:IP2,..."    Configuration brokers (format: id:ip,...)

OPTIONS:
    -h, --help                         Afficher cette aide
    -v, --version                      Afficher la version
    --log-file <chemin>               Journaliser dans un fichier
    --dry-run                         Mode test sans modification
    --verbose                         Mode verbeux pour debug
    
EXEMPLES:
    # Diagnostic cluster ACM standard
    $SCRIPT_NAME --brokers "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
    
    # Avec logging et mode verbeux
    $SCRIPT_NAME --brokers "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115" \\
                 --log-file /var/log/kafka-diag.log --verbose
    
    # Mode test sans modification
    $SCRIPT_NAME --brokers "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115" --dry-run

TESTS INCLUS:
    1. Connectivité ZooKeeper (port 2181)
    2. Rôles ZooKeeper (leader/follower)
    3. Présence des brokers dans ZooKeeper
    4. Ports Kafka ouverts (9092)
    5. Accessibilité API Kafka
    6. Vérification logs Kafka
    7. Topic __consumer_offsets
    8. Métadonnées cluster
    9. Test bout en bout (production/consommation)

CONFORMITÉ:
    - PCI-DSS: Audit trail, permissions restrictives
    - ANSSI-BP-028: Validation sécurisée, logs centralisés
    - Banking Standards: Haute disponibilité, monitoring

SUPPORT: philippe.candido@emerging-it.fr
EOF
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
            --brokers)
                BROKERS_STRING="$2"
                shift 2
                ;;
            --log-file)
                LOG_FILE="$2"
                ENABLE_LOGGING="true"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            *)
                log_error "Argument inconnu: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Validation arguments obligatoires
    if [[ -z "$BROKERS_STRING" ]]; then
        log_error "Argument --brokers obligatoire"
        show_help
        exit 1
    fi

    # Configuration du fichier de log par défaut
    if [[ "$ENABLE_LOGGING" == "true" && -z "$LOG_FILE" ]]; then
        LOG_FILE="$DEFAULT_LOG_FILE"
    fi
}

# === PARSING CONFIGURATION BROKERS ===
declare -A BROKER_IDS
declare -A BROKER_IPS

parse_brokers_config() {
    log_info "Parsing configuration brokers: $BROKERS_STRING"
    
    # Validation format
    if [[ ! "$BROKERS_STRING" =~ ^[0-9]+:[0-9.]+([,][0-9]+:[0-9.]+)*$ ]]; then
        log_error "Format brokers invalide. Attendu: 'id1:ip1,id2:ip2,...'"
        exit 1
    fi
    
    # Parse des paires id:ip
    IFS=',' read -ra BROKER_PAIRS <<< "$BROKERS_STRING"
    for pair in "${BROKER_PAIRS[@]}"; do
        IFS=':' read -ra BROKER_INFO <<< "$pair"
        local broker_id="${BROKER_INFO[0]}"
        local broker_ip="${BROKER_INFO[1]}"
        
        # Validation IP
        if [[ ! "$broker_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_error "IP invalide: $broker_ip"
            exit 1
        fi
        
        BROKER_IDS[$broker_id]="$broker_ip"
        BROKER_IPS[$broker_ip]="$broker_id"
        
        [[ "$VERBOSE" == "true" ]] && log_info "Broker configuré: ID=$broker_id IP=$broker_ip"
    done
    
    log_success "Configuration brokers parsée: ${#BROKER_IDS[@]} nœuds"
}

# === TEST 1: CONNECTIVITÉ ZOOKEEPER ===
test_zookeeper_connectivity() {
    log_info "Test 1/9: Connectivité ZooKeeper (port $ZK_PORT)"
    
    local failed_nodes=()
    
    for broker_ip in "${!BROKER_IPS[@]}"; do
        [[ "$VERBOSE" == "true" ]] && log_info "Test connectivité ZooKeeper: $broker_ip:$ZK_PORT"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Test connectivité ZooKeeper: $broker_ip:$ZK_PORT"
            continue
        fi
        
        # Test avec timeout de 5 secondes
        if timeout 5 bash -c "echo ruok | nc $broker_ip $ZK_PORT" 2>/dev/null | grep -q "imok"; then
            [[ "$VERBOSE" == "true" ]] && log_success "✓ ZooKeeper répond sur $broker_ip:$ZK_PORT"
        else
            log_error "✗ ZooKeeper ne répond pas sur $broker_ip:$ZK_PORT"
            failed_nodes+=("$broker_ip")
        fi
    done
    
    if [[ ${#failed_nodes[@]} -eq 0 ]]; then
        log_success "✓ Test connectivité ZooKeeper: RÉUSSI"
        return 0
    else
        log_error "✗ Test connectivité ZooKeeper: ÉCHEC (${#failed_nodes[@]} nœuds défaillants)"
        return 1
    fi
}

# === TEST 2: RÔLES ZOOKEEPER ===
test_zookeeper_roles() {
    log_info "Test 2/9: Vérification rôles ZooKeeper (leader/follower)"
    
    local leaders=0
    local followers=0
    
    for broker_ip in "${!BROKER_IPS[@]}"; do
        [[ "$VERBOSE" == "true" ]] && log_info "Vérification rôle ZooKeeper: $broker_ip"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Vérification rôle ZooKeeper: $broker_ip"
            continue
        fi
        
        # Récupération du statut avec timeout
        local zk_stat
        if zk_stat=$(timeout 5 bash -c "echo stat | nc $broker_ip $ZK_PORT" 2>/dev/null); then
            local mode=$(echo "$zk_stat" | grep "Mode:" | awk '{print $2}')
            
            case "$mode" in
                "leader")
                    ((leaders++))
                    [[ "$VERBOSE" == "true" ]] && log_success "✓ $broker_ip: leader"
                    ;;
                "follower")
                    ((followers++))
                    [[ "$VERBOSE" == "true" ]] && log_success "✓ $broker_ip: follower"
                    ;;
                *)
                    log_warning "⚠ $broker_ip: rôle inconnu ($mode)"
                    ;;
            esac
        else
            log_error "✗ Impossible de récupérer le statut ZooKeeper: $broker_ip"
        fi
    done
    
    # Validation: 1 leader, N-1 followers
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "✓ Test rôles ZooKeeper: SIMULÉ"
        return 0
    fi
    
    local expected_followers=$((${#BROKER_IDS[@]} - 1))
    if [[ $leaders -eq 1 && $followers -eq $expected_followers ]]; then
        log_success "✓ Test rôles ZooKeeper: RÉUSSI ($leaders leader, $followers followers)"
        return 0
    else
        log_error "✗ Test rôles ZooKeeper: ÉCHEC ($leaders leaders, $followers followers)"
        log_error "  Attendu: 1 leader, $expected_followers followers"
        return 1
    fi
}

# === TEST 3: PRÉSENCE BROKERS DANS ZOOKEEPER ===
test_brokers_in_zookeeper() {
    log_info "Test 3/9: Présence des brokers dans ZooKeeper"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "✓ Test présence brokers: SIMULÉ"
        return 0
    fi
    
    # Sélection du premier broker pour la requête
    local first_broker_ip="${!BROKER_IPS[@]}"
    first_broker_ip=$(echo "$first_broker_ip" | head -n1)
    
    [[ "$VERBOSE" == "true" ]] && log_info "Requête ZooKeeper via: $first_broker_ip"
    
    # Exécution de la commande ZooKeeper shell
    local zk_brokers
    if zk_brokers=$($KAFKA_HOME/bin/zookeeper-shell.sh "$first_broker_ip:$ZK_PORT" <<< "ls /brokers/ids" 2>/dev/null | tail -1); then
        # Extraction des IDs (format: [1, 2, 3])
        local registered_ids=$(echo "$zk_brokers" | sed 's/\[//g; s/\]//g; s/,//g')
        
        [[ "$VERBOSE" == "true" ]] && log_info "Brokers enregistrés dans ZooKeeper: $registered_ids"
        
        # Vérification de chaque broker configuré
        local missing_brokers=()
        for broker_id in "${!BROKER_IDS[@]}"; do
            if echo "$registered_ids" | grep -q "\b$broker_id\b"; then
                [[ "$VERBOSE" == "true" ]] && log_success "✓ Broker $broker_id trouvé dans ZooKeeper"
            else
                log_error "✗ Broker $broker_id manquant dans ZooKeeper"
                missing_brokers+=("$broker_id")
            fi
        done
        
        if [[ ${#missing_brokers[@]} -eq 0 ]]; then
            log_success "✓ Test présence brokers: RÉUSSI (${#BROKER_IDS[@]} brokers enregistrés)"
            return 0
        else
            log_error "✗ Test présence brokers: ÉCHEC (${#missing_brokers[@]} brokers manquants)"
            return 1
        fi
    else
        log_error "✗ Impossible d'interroger ZooKeeper pour les brokers"
        return 1
    fi
}

# === TEST 4: PORTS KAFKA OUVERTS ===
test_kafka_ports() {
    log_info "Test 4/9: Ports Kafka ouverts (port $KAFKA_PORT)"
    
    local failed_ports=()
    
    for broker_ip in "${!BROKER_IPS[@]}"; do
        [[ "$VERBOSE" == "true" ]] && log_info "Test port Kafka: $broker_ip:$KAFKA_PORT"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Test port Kafka: $broker_ip:$KAFKA_PORT"
            continue
        fi
        
        # Test avec nc et timeout
        if timeout 3 nc -z "$broker_ip" "$KAFKA_PORT" 2>/dev/null; then
            [[ "$VERBOSE" == "true" ]] && log_success "✓ Port $KAFKA_PORT ouvert sur $broker_ip"
        else
            log_error "✗ Le broker $broker_ip n'écoute pas sur le port $KAFKA_PORT"
            failed_ports+=("$broker_ip")
        fi
    done
    
    if [[ ${#failed_ports[@]} -eq 0 ]]; then
        log_success "✓ Test ports Kafka: RÉUSSI"
        return 0
    else
        log_error "✗ Test ports Kafka: ÉCHEC (${#failed_ports[@]} ports fermés)"
        return 1
    fi
}

# === TEST 5: ACCESSIBILITÉ API KAFKA ===
test_kafka_api() {
    log_info "Test 5/9: Accessibilité API Kafka"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "✓ Test API Kafka: SIMULÉ"
        return 0
    fi
    
    # Test sur le premier broker
    local first_broker_ip="${!BROKER_IPS[@]}"
    first_broker_ip=$(echo "$first_broker_ip" | head -n1)
    
    [[ "$VERBOSE" == "true" ]] && log_info "Test API Kafka via: $first_broker_ip:$KAFKA_PORT"
    
    # Exécution kafka-broker-api-versions
    if $KAFKA_HOME/bin/kafka-broker-api-versions.sh --bootstrap-server "$first_broker_ip:$KAFKA_PORT" > /dev/null 2>&1; then
        log_success "✓ Test API Kafka: RÉUSSI"
        return 0
    else
        log_error "✗ L'API Kafka n'est pas joignable sur $first_broker_ip:$KAFKA_PORT"
        return 1
    fi
}

# === TEST 6: VÉRIFICATION LOGS KAFKA ===
test_kafka_logs() {
    log_info "Test 6/9: Vérification logs Kafka"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "✓ Test logs Kafka: SIMULÉ"
        return 0
    fi
    
    local error_count=0
    local log_file="$KAFKA_LOGS_DIR/server.log"
    
    # Vérification existence du fichier de log
    if [[ ! -f "$log_file" ]]; then
        log_warning "⚠ Fichier de log Kafka non trouvé: $log_file"
        return 1
    fi
    
    [[ "$VERBOSE" == "true" ]] && log_info "Analyse du fichier: $log_file"
    
    # Recherche d'erreurs dans les 50 dernières lignes
    local recent_errors
    if recent_errors=$(tail -50 "$log_file" | grep -E "(ERROR|Exception|FATAL)" 2>/dev/null); then
        error_count=$(echo "$recent_errors" | wc -l)
        
        if [[ $error_count -gt 0 ]]; then
            log_warning "⚠ $error_count erreur(s) détectée(s) dans server.log"
            [[ "$VERBOSE" == "true" ]] && echo "$recent_errors" | head -5 | while read -r line; do
                log_warning "  $line"
            done
            return 1
        fi
    fi
    
    log_success "✓ Test logs Kafka: RÉUSSI (aucune erreur critique récente)"
    return 0
}

# === TEST 7: TOPIC __consumer_offsets ===
test_consumer_offsets_topic() {
    log_info "Test 7/9: Vérification topic __consumer_offsets"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "✓ Test topic __consumer_offsets: SIMULÉ"
        return 0
    fi
    
    # Sélection du premier broker
    local first_broker_ip="${!BROKER_IPS[@]}"
    first_broker_ip=$(echo "$first_broker_ip" | head -n1)
    
    [[ "$VERBOSE" == "true" ]] && log_info "Vérification topic __consumer_offsets via: $first_broker_ip"
    
    # Description du topic
    if $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$first_broker_ip:$KAFKA_PORT" \
       --describe --topic "__consumer_offsets" > /dev/null 2>&1; then
        log_success "✓ Test topic __consumer_offsets: RÉUSSI"
        return 0
    else
        log_error "✗ Le topic __consumer_offsets est manquant ou inaccessible"
        return 1
    fi
}

# === TEST 8: MÉTADONNÉES CLUSTER ===
test_cluster_metadata() {
    log_info "Test 8/9: Lecture des métadonnées cluster"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "✓ Test métadonnées cluster: SIMULÉ"
        return 0
    fi
    
    # Sélection du premier broker
    local first_broker_ip="${!BROKER_IPS[@]}"
    first_broker_ip=$(echo "$first_broker_ip" | head -n1)
    
    [[ "$VERBOSE" == "true" ]] && log_info "Récupération métadonnées via: $first_broker_ip"
    
    # Liste des topics pour vérifier les métadonnées
    local topics_output
    if topics_output=$($KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$first_broker_ip:$KAFKA_PORT" --list 2>/dev/null); then
        local topic_count=$(echo "$topics_output" | wc -l)
        [[ "$VERBOSE" == "true" ]] && log_info "Topics trouvés: $topic_count"
        log_success "✓ Test métadonnées cluster: RÉUSSI ($topic_count topics)"
        return 0
    else
        log_error "✗ Impossible de récupérer les métadonnées du cluster"
        return 1
    fi
}

# === TEST 9: TEST BOUT EN BOUT ===
test_end_to_end() {
    log_info "Test 9/9: Test bout en bout (production/consommation)"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "✓ Test bout en bout: SIMULÉ"
        return 0
    fi
    
    # Sélection du premier broker
    local first_broker_ip="${!BROKER_IPS[@]}"
    first_broker_ip=$(echo "$first_broker_ip" | head -n1)
    local bootstrap_server="$first_broker_ip:$KAFKA_PORT"
    
    [[ "$VERBOSE" == "true" ]] && log_info "Test bout en bout via: $bootstrap_server"
    
    # Message de test
    local test_message="kafka-diagnostic-test-$(date +%s)"
    
    # Étape 1: Création du topic temporaire
    [[ "$VERBOSE" == "true" ]] && log_info "Création topic temporaire: $TEST_TOPIC"
    if ! $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$bootstrap_server" \
         --create --topic "$TEST_TOPIC" --partitions 1 --replication-factor 1 \
         --if-not-exists > /dev/null 2>&1; then
        log_error "✗ Impossible de créer le topic de test"
        return 1
    fi
    
    # Étape 2: Production du message
    [[ "$VERBOSE" == "true" ]] && log_info "Production du message de test"
    if ! echo "$test_message" | $KAFKA_HOME/bin/kafka-console-producer.sh \
         --bootstrap-server "$bootstrap_server" --topic "$TEST_TOPIC" > /dev/null 2>&1; then
        log_error "✗ Échec de production du message"
        cleanup_test_topic
        return 1
    fi
    
    # Étape 3: Consommation du message
    [[ "$VERBOSE" == "true" ]] && log_info "Consommation du message de test"
    local consumed_message
    if consumed_message=$(timeout 10 $KAFKA_HOME/bin/kafka-console-consumer.sh \
                         --bootstrap-server "$bootstrap_server" --topic "$TEST_TOPIC" \
                         --from-beginning --max-messages 1 2>/dev/null); then
        
        # Vérification du message
        if [[ "$consumed_message" == "$test_message" ]]; then
            log_success "✓ Test bout en bout: RÉUSSI (message produit et consommé)"
            cleanup_test_topic
            return 0
        else
            log_error "✗ Message consommé différent du message produit"
            cleanup_test_topic
            return 1
        fi
    else
        log_error "✗ Échec de consommation du message"
        cleanup_test_topic
        return 1
    fi
}

# === NETTOYAGE TOPIC DE TEST ===
cleanup_test_topic() {
    [[ "$VERBOSE" == "true" ]] && log_info "Suppression topic de test: $TEST_TOPIC"
    
    local first_broker_ip="${!BROKER_IPS[@]}"
    first_broker_ip=$(echo "$first_broker_ip" | head -n1)
    
    $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$first_broker_ip:$KAFKA_PORT" \
     --delete --topic "$TEST_TOPIC" > /dev/null 2>&1 || true
}

# === AFFICHAGE RÉSUMÉ ===
display_summary() {
    echo ""
    echo "=========================================================================="
    echo "                    RÉSUMÉ DIAGNOSTIC CLUSTER KAFKA"
    echo "=========================================================================="
    echo "Script: $SCRIPT_NAME v$SCRIPT_VERSION"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Brokers testés: ${#BROKER_IDS[@]} nœuds"
    for broker_id in $(printf '%s\n' "${!BROKER_IDS[@]}" | sort -n); do
        echo "  - Broker $broker_id: ${BROKER_IDS[$broker_id]}"
    done
    [[ "$ENABLE_LOGGING" == "true" ]] && echo "Log file: $LOG_FILE"
    echo "=========================================================================="
}

# === VALIDATION PRÉREQUIS ===
validate_prerequisites() {
    log_info "Validation des prérequis du diagnostic"
    
    # Vérification Kafka
    if [[ ! -d "$KAFKA_HOME" ]]; then
        log_error "Répertoire Kafka non trouvé: $KAFKA_HOME"
        exit 1
    fi
    
    # Vérification binaires essentiels
    local required_binaries=(
        "$KAFKA_HOME/bin/kafka-topics.sh"
        "$KAFKA_HOME/bin/kafka-console-producer.sh"
        "$KAFKA_HOME/bin/kafka-console-consumer.sh"
        "$KAFKA_HOME/bin/kafka-broker-api-versions.sh"
        "$KAFKA_HOME/bin/zookeeper-shell.sh"
    )
    
    for binary in "${required_binaries[@]}"; do
        if [[ ! -f "$binary" ]]; then
            log_error "Binaire Kafka manquant: $binary"
            exit 1
        fi
    done
    
    # Vérification nc (netcat)
    if ! command -v nc > /dev/null 2>&1; then
        log_error "Commande 'nc' (netcat) requise non disponible"
        exit 1
    fi
    
    log_success "✓ Prérequis validés"
}

# === FONCTION PRINCIPALE ===
main() {
    # Initialisation
    parse_arguments "$@"
    
    # Configuration logging
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        log_info "Diagnostic Kafka démarré - Log: $LOG_FILE"
    fi
    
    # Affichage en-tête
    display_summary
    
    # Validation et parsing
    validate_prerequisites
    parse_brokers_config
    
    # Exécution des tests
    log_info "Début du diagnostic cluster Kafka ($SCRIPT_VERSION)"
    
    local tests_passed=0
    local tests_total=9
    
    # Exécution de chaque test
    test_zookeeper_connectivity && ((tests_passed++)) || true
    test_zookeeper_roles && ((tests_passed++)) || true
    test_brokers_in_zookeeper && ((tests_passed++)) || true
    test_kafka_ports && ((tests_passed++)) || true
    test_kafka_api && ((tests_passed++)) || true
    test_kafka_logs && ((tests_passed++)) || true
    test_consumer_offsets_topic && ((tests_passed++)) || true
    test_cluster_metadata && ((tests_passed++)) || true
    test_end_to_end && ((tests_passed++)) || true
    
    # Résumé final
    echo ""
    echo "=========================================================================="
    echo "                        RÉSULTAT FINAL"
    echo "=========================================================================="
    
    if [[ $tests_passed -eq $tests_total ]]; then
        log_success "🎉 DIAGNOSTIC RÉUSSI: $tests_passed/$tests_total tests passés"
        log_success "✅ Le cluster Kafka est fonctionnel et cohérent"
        exit 0
    else
        local tests_failed=$((tests_total - tests_passed))
        log_error "❌ DIAGNOSTIC ÉCHEC: $tests_passed/$tests_total tests passés ($tests_failed échecs)"
        log_error "⚠️  Le cluster Kafka présente des dysfonctionnements"
        exit 1
    fi
}

# === POINT D'ENTRÉE ===
main "$@"