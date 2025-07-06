#!/bin/bash
################################################################################
# Script: configure_kafka_cluster.sh
# Version: 1.0.0  
# Description: Configuration et validation cluster Kafka ACM
################################################################################

set -euo pipefail

SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/kafka-cluster-config-$(date +%Y%m%d-%H%M%S).log"
KAFKA_HOME="/opt/kafka"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Configuration topics ACM selon spécifications SironOne
configure_acm_topics() {
    log "Configuration des topics ACM..."
    
    # Topics principaux ACM
    local topics=(
        "acmadapter.0001.events_in:12:3"
        "acmadapter.0001.events_out:12:3"
        "acm.alerts.processing:24:3"
        "acm.cases.management:12:3"
        "acm.audit.trail:6:3"
        "acm.notifications:6:3"
    )
    
    for topic_config in "${topics[@]}"; do
        IFS=':' read -r topic_name partitions replication <<< "$topic_config"
        
        log "Création topic: $topic_name"
        $KAFKA_HOME/bin/kafka-topics.sh \
            --create \
            --bootstrap-server localhost:9092 \
            --topic "$topic_name" \
            --partitions "$partitions" \
            --replication-factor "$replication" \
            --config retention.ms=604800000 \
            --config segment.ms=86400000 \
            --config compression.type=gzip \
            --if-not-exists
    done
}

# Validation cluster
validate_cluster() {
    log "Validation du cluster Kafka..."
    
    # Test connectivité brokers
    local brokers=("172.20.2.113:9092" "172.20.2.114:9092" "172.20.2.115:9092")
    
    for broker in "${brokers[@]}"; do
        if $KAFKA_HOME/bin/kafka-broker-api-versions.sh --bootstrap-server "$broker" > /dev/null 2>&1; then
            log "✓ Broker $broker accessible"
        else
            log "✗ Broker $broker inaccessible"
        fi
    done
    
    # Vérification topics
    log "Liste des topics créés:"
    $KAFKA_HOME/bin/kafka-topics.sh --list --bootstrap-server localhost:9092
    
    # Test de performance
    log "Test de performance..."
    $KAFKA_HOME/bin/kafka-producer-perf-test.sh \
        --topic acm.test.performance \
        --num-records 10000 \
        --record-size 1024 \
        --throughput 1000 \
        --producer-props bootstrap.servers=localhost:9092
}

# Sauvegarde configuration
backup_configuration() {
    log "Sauvegarde de la configuration..."
    
    local backup_dir="/opt/kafka/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    cp -r "$KAFKA_HOME/config" "$backup_dir/"
    tar -czf "$backup_dir/kafka-config-backup.tar.gz" -C "$KAFKA_HOME" config
    
    log "Configuration sauvegardée dans $backup_dir"
}

main() {
    log "=== CONFIGURATION CLUSTER KAFKA ACM ==="
    
    # Attendre que tous les brokers soient disponibles
    sleep 30
    
    configure_acm_topics
    validate_cluster  
    backup_configuration
    
    log "=== CONFIGURATION TERMINÉE ==="
}

main "$@"