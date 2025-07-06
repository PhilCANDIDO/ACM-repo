#!/bin/bash
################################################################################
# Script: install_zookeeper.sh  
# Version: 1.0.0
# Description: Installation ZooKeeper pour cluster Kafka ACM
################################################################################

set -euo pipefail

SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/zookeeper-install-$(date +%Y%m%d-%H%M%S).log"
ZK_VERSION="3.8.4"
NODE_ID=""
REPO_SERVER="172.20.2.109"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

show_help() {
    cat << EOF
Installation ZooKeeper pour Kafka Cluster

USAGE: $0 -n NODE_ID [-r REPO_SERVER]

OPTIONS:
    -n, --node-id NUM       ID du nœud ZooKeeper (1-3)
    -r, --repo-server IP    IP du serveur repository
    -h, --help              Afficher cette aide
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--node-id) NODE_ID="$2"; shift 2 ;;
        -r|--repo-server) REPO_SERVER="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Option inconnue: $1"; exit 1 ;;
    esac
done

if [[ -z "$NODE_ID" ]] || [[ ! "$NODE_ID" =~ ^[1-3]$ ]]; then
    echo "ERROR: ID nœud requis (1-3)"
    exit 1
fi

install_zookeeper() {
    log "Installation ZooKeeper..."
    
    # Création utilisateur
    useradd -r -s /bin/false zookeeper 2>/dev/null || true
    
    # Répertoires
    mkdir -p /opt/zookeeper /data/zookeeper /var/log/zookeeper
    
    # Téléchargement
    cd /tmp
    curl -O "http://$REPO_SERVER/kafka/apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
    tar -xzf "apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
    cp -r "apache-zookeeper-${ZK_VERSION}-bin"/* /opt/zookeeper/
    
    # Configuration
    cat > /opt/zookeeper/conf/zoo.cfg << EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/data/zookeeper
clientPort=2181
maxClientCnxns=60
autopurge.snapRetainCount=3
autopurge.purgeInterval=24

# Cluster Configuration
server.1=172.20.2.113:2888:3888
server.2=172.20.2.114:2888:3888  
server.3=172.20.2.115:2888:3888
EOF
    
    # ID du nœud
    echo "$NODE_ID" > /data/zookeeper/myid
    
    # Permissions
    chown -R zookeeper:zookeeper /opt/zookeeper /data/zookeeper /var/log/zookeeper
    
    # Service systemd
    cat > /etc/systemd/system/zookeeper.service << EOF
[Unit]
Description=Apache ZooKeeper
After=network.target

[Service]
Type=simple
User=zookeeper
Group=zookeeper
Environment=JAVA_HOME=/opt/java
ExecStart=/opt/zookeeper/bin/zkServer.sh start-foreground
ExecStop=/opt/zookeeper/bin/zkServer.sh stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable zookeeper
    
    log "ZooKeeper installé et configuré"
}

install_zookeeper