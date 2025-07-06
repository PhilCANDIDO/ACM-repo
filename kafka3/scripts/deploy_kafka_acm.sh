#!/bin/bash
################################################################################
# Script: deploy_kafka_acm.sh
# Description: Déploiement automatisé cluster Kafka ACM sur 3 nœuds
################################################################################

set -euo pipefail

NODES=("172.20.2.113" "172.20.2.114" "172.20.2.115")
REPO_SERVER="172.20.2.109"

deploy_node() {
    local node_ip="$1"
    local node_id="$2"
    
    echo "=== DÉPLOIEMENT NŒUD $node_id ($node_ip) ==="
    
    # Copie des scripts
    scp install_*.sh root@"$node_ip":/tmp/
    
    # Installation ZooKeeper
    ssh root@"$node_ip" "bash /tmp/install_zookeeper.sh -n $node_id -r $REPO_SERVER"
    
    # Installation Kafka
    ssh root@"$node_ip" "bash /tmp/install_kafka_cluster.sh -n $node_id -r $REPO_SERVER"
    
    echo "Nœud $node_id déployé avec succès"
}

# Déploiement séquentiel
for i in "${!NODES[@]}"; do
    node_id=$((i + 1))
    deploy_node "${NODES[$i]}" "$node_id"
done

echo "=== DÉPLOIEMENT CLUSTER TERMINÉ ==="
echo "Démarrage des services:"
echo "  Étape 1: Démarrer ZooKeeper sur tous les nœuds"
echo "  Étape 2: Démarrer Kafka sur tous les nœuds"  
echo "  Étape 3: Configurer les topics ACM"