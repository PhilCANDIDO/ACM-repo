#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# check_mongo_cluster.sh
# Usage:
#   chmod +x check_mongo_cluster.sh
#   ./check_mongo_cluster.sh \\
#     --admin-user myAdmin \\
#     --admin-pwd S3cr3tPwd \\
#     --node-list 10.6.182.130,10.6.182.131,10.6.182.132
#
# Prérequis :
#   • ssh key-based auth ou passwordless sudo sur les nœuds
#   • mongosh installé sur la machine de lancement
#   • jq installé (sinon le script quitte avec erreur)
# ------------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

function usage(){
  cat <<EOF
Usage: $0 --admin-user USER --admin-pwd PWD --node-list IP1,IP2,...
  --admin-user   Nom de l'administrateur MongoDB
  --admin-pwd    Mot de passe de cet administrateur
  --node-list    Liste des nodes au format "ip1,ip2,ip3"
EOF
  exit 1
}

### 1) Parse arguments
ADMIN_USER="" ADMIN_PWD="" NODE_LIST=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --admin-user) ADMIN_USER=$2; shift 2;;
    --admin-pwd)  ADMIN_PWD=$2;  shift 2;;
    --node-list)  NODE_LIST=$2;  shift 2;;
    -h|--help)    usage;;
    *) echo "❗ Unknown argument: $1"; usage;;
  esac
done

# Vérification
if [[ -z "$ADMIN_USER" || -z "$ADMIN_PWD" || -z "$NODE_LIST" ]]; then
  echo "❗ Tous les arguments sont obligatoires." >&2
  usage
fi

### 2) Vérifier que jq est installé
if ! command -v jq &>/dev/null; then
  echo "❗ Erreur : jq n'est pas installé. Veuillez installer jq pour exécuter ce script." >&2
  exit 1
fi

### 3) Construire le tableau des nœuds
IFS=',' read -r -a NODES <<< "$NODE_LIST"

### 4) Préparer la commande mongosh
MONGOSH_CMD=(
  mongosh
  --username "$ADMIN_USER"
  --password "$ADMIN_PWD"
  --authenticationDatabase admin
  --quiet
)

### 5) Couleurs pour lisibilité
RED='\033[0;31m' 
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Audit MongoDB Replica Set ===${NC}"
echo "Admin user: ${ADMIN_USER}"
echo "Nodes: ${NODES[*]}"
echo

### 6) Vérifications OS & Réseau
for host in "${NODES[@]}"; do
  echo -e "${GREEN}-- OS & réseau sur ${host}${NC}"
  ssh "$host" bash -c "'
    echo -n \"Service mongod actif ? \";   systemctl is-active mongod
    echo -n \"SELinux mode       : \";   getenforce
    echo -n \"Port 27017 écoute   : \";   ss -tunlp | grep 27017 || echo none
    echo -n \"Rich-rules firewall : \";   firewall-cmd --list-rich-rules | grep 27017 || echo none
  '"
  echo
done

PRIMARY="${NODES[0]}"
echo -e "${YELLOW}=== Checks MongoDB via mongosh on ${PRIMARY} ===${NC}"

### 7) rs.status() → jq summary
RS_JSON=$("${MONGOSH_CMD[@]}" --host "$PRIMARY" --eval 'rs.status()')
echo -e "${GREEN}* Replica Set Members:${NC}"
echo "$RS_JSON" \
  | jq -r '.members[] 
      | "\(.name)  \tstate:\(.stateStr)  \thealth:\(.health)  \toptime:\(.optimeDate)"'
echo

### 8) rs.conf() → jq summary
CONF_JSON=$("${MONGOSH_CMD[@]}" --host "$PRIMARY" --eval 'rs.conf()')
echo -e "${GREEN}* Replica Set Configuration:${NC}"
echo "$CONF_JSON" \
  | jq -r '.members[] 
      | "\(.name)  \tvotes:\(.votes)  \tpriority:\(.priority)"'
echo

### 9) Latence de réplication
echo -e "${GREEN}* Replication Lag (secondaries):${NC}"
LAG_JSON=$("${MONGOSH_CMD[@]}" --host "$PRIMARY" --eval 'JSON.stringify(rs.printSlaveReplicationInfo())')
# printSlaveReplicationInfo produit du texte, on le laisse brut si pas JSON.
echo "$LAG_JSON"
echo

### 10) serverStatus() → jq summary sur chaque nœud
for host in "${NODES[@]}"; do
  SS_JSON=$("${MONGOSH_CMD[@]}" --host "$host" --eval 'db.adminCommand({ serverStatus:1 })')
  echo -e "${GREEN}-- serverStatus @ ${host}:${NC}"
  echo "$SS_JSON" \
    | jq -r --arg H "$host" '
       . as $s
       | "\($H) — uptime: \(.uptime)s, connections: current=\(.connections.current) / available=\(.connections.available), mem: resident=\(.mem.resident)MB / virtual=\(.mem.virtual)MB"
     '
  echo
done

### 11) Logs MongoDB pour WARN/ERROR (optionnel, à commenter si trop verbeux)
echo -e "${YELLOW}=== Logs MongoDB (WARN & ERROR) ===${NC}"
for host in "${NODES[@]}"; do
  echo -e "${GREEN}-- ${host}:${NC}"
  ssh "$host" "grep -E 'WARNING|ERROR' /var/log/mongodb/mongod.log | tail -n 20 || echo '— Aucun avertissement/erreur récent —'"
done

echo -e "${YELLOW}=== Fin de l’audit ===${NC}"
