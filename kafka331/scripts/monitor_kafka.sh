#!/bin/bash
# Monitoring Kafka pour environnement bancaire

check_cluster_health() {
    echo "=== ÉTAT CLUSTER KAFKA ==="
    
    # Vérification brokers
    kafka-broker-api-versions.sh --bootstrap-server localhost:9092 2>/dev/null || {
        echo "CRITICAL: Broker local inaccessible"
        exit 2
    }
    
    # Métriques JMX
    echo "Lag des consumers:"
    kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups
    
    # Utilisation disque
    echo "Utilisation disque:"
    df -h /data/kafka
    
    # Processus Kafka
    echo "Processus Kafka:"
    ps aux | grep kafka | grep -v grep
}

check_cluster_health