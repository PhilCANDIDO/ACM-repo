# README - Scripts d'installation Kafka et ZooKeeper

## 📋 Vue d'ensemble

Ce document présente les scripts d'installation automatisée pour le déploiement d'un cluster Kafka haute disponibilité avec ZooKeeper sur environnement RHEL 9 air-gapped, conforme aux standards bancaires PCI-DSS et ANSSI-BP-028.

### Scripts inclus
- **`install_kafka_cluster.sh`** v2.2.0 - Installation et configuration Kafka 3.9.0
- **`install_zookeeper.sh`** v3.0.0 - Installation et configuration ZooKeeper 3.8.4

---

## 🏗️ Architecture déployée

### Cluster Kafka
- **3 brokers** en haute disponibilité (ID 1, 2, 3)
- **Réplication** : facteur 3 avec minimum 2 replicas synchrones
- **Topics** : auto-création avec 5 partitions par défaut
- **Ports** : 9092 (inter-cluster)

### Cluster ZooKeeper  
- **3 nœuds** en ensemble (quorum majority)
- **Coordination** des brokers Kafka
- **Ports** : 2181 (client), 2888 (peer), 3888 (election)

---

## ⚡ Installation rapide

### Prérequis système
```bash
# Filesystems dédiés requis
/data/kafka     # Minimum 20GB, monté et accessible
/data/zookeeper # Minimum 5GB, accessible en écriture
/var/log/kafka  # Logs Kafka
/var/log/zookeeper # Logs ZooKeeper
```

### Déploiement nœud par nœud

```bash
# === NŒUD 1 (172.20.2.113) ===
# 1. Installation Kafka (EN PREMIER - obligatoire)
./install_kafka_cluster.sh -n 1 -r 172.20.2.109

# 2. Installation ZooKeeper (APRÈS Kafka)
./install_zookeeper.sh -n 1 -r 172.20.2.109

# === NŒUD 2 (172.20.2.114) ===
./install_kafka_cluster.sh -n 2 -r 172.20.2.109
./install_zookeeper.sh -n 2 -r 172.20.2.109

# === NŒUD 3 (172.20.2.115) ===
./install_kafka_cluster.sh -n 3 -r 172.20.2.109
./install_zookeeper.sh -n 3 -r 172.20.2.109
```

### Démarrage du cluster

```bash
# 1. Démarrer ZooKeeper sur tous les nœuds
systemctl start zookeeper

# 2. Vérifier ensemble ZooKeeper
echo ruok | nc localhost 2181

# 3. Démarrer Kafka sur tous les nœuds  
systemctl start kafka

# 4. Vérifier cluster Kafka
kafka-topics.sh --bootstrap-server localhost:9092 --list
```

---

## 📖 Documentation détaillée

## Script: install_kafka_cluster.sh

### Description
Installation automatisée de Kafka 3.9.0 en cluster haute disponibilité pour l'application bancaire ACM.

### Versions et changelog
- **v2.2.0** (actuelle) - Configuration automatique firewall TCP/9092 et TCP/2181
- **v2.1.0** - Validation interactive KAFKA_NODES et support variable système
- **v2.0.0** - Refactorisation avec RPM Java, variables nœuds, vérification filesystem

### Utilisation

```bash
install_kafka_cluster.sh [OPTIONS]

OPTIONS:
  -h, --help              Afficher l'aide
  -v, --version           Afficher la version
  -n, --node-id NUM       ID du nœud Kafka (1-3) [OBLIGATOIRE]
  -r, --repo-server IP    IP du serveur repository (défaut: 172.20.2.109)
  --dry-run              Mode test sans modification
  --check-fs             Vérifier seulement les filesystems
  --skip-validation      Ignorer la validation interactive
```

### Exemples d'utilisation

```bash
# Installation broker ID 1 avec validation interactive
./install_kafka_cluster.sh -n 1

# Installation broker ID 2 avec repository custom
./install_kafka_cluster.sh -n 2 -r 172.20.2.109

# Mode test sans modification
./install_kafka_cluster.sh -n 1 --dry-run

# Vérification filesystem seulement
./install_kafka_cluster.sh --check-fs

# Installation automatique sans validation
./install_kafka_cluster.sh -n 3 --skip-validation
```

### Configuration des nœuds

Le script supporte deux méthodes de configuration :

#### 1. Configuration par défaut (intégrée)
```bash
Node 1: 172.20.2.113
Node 2: 172.20.2.114  
Node 3: 172.20.2.115
```

#### 2. Variable système KAFKA_NODES (prioritaire)
```bash
export KAFKA_NODES="1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
./install_kafka_cluster.sh -n 1
```

### Fonctionnalités de sécurité

#### Conformité PCI-DSS
- Comptes de service dédiés (`kafka:kafka`)
- Permissions restrictives (750) sur les répertoires
- Chiffrement réseau configuré
- Audit trail complet

#### Conformité ANSSI-BP-028
- Configuration SELinux automatique
- Règles firewall pour ports requis (9092, 2181)
- Isolation des processus
- Logs centralisés avec rotation

### Configuration Kafka générée

```properties
# Exemple de configuration générée
broker.id=1
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://172.20.2.113:9092

# ZooKeeper cluster
zookeeper.connect=172.20.2.113:2181,172.20.2.114:2181,172.20.2.115:2181

# Réplication haute disponibilité
default.replication.factor=3
min.insync.replicas=2
offsets.topic.replication.factor=3

# Configuration ACM
num.partitions=5
log.retention.hours=168
compression.type=lz4
```

---

## Script: install_zookeeper.sh

### Description  
Installation automatisée de ZooKeeper 3.8.4 en ensemble pour coordonner le cluster Kafka ACM.

⚠️ **PRÉREQUIS CRITIQUE** : Le script `install_kafka_cluster.sh` DOIT être exécuté EN PREMIER sur chaque nœud.

### Versions et changelog
- **v3.0.0** (actuelle) - Refactorisation complète selon méthode Basher Pro
  - Harmonisation avec install_kafka_cluster.sh
  - Configuration SELinux et firewall complète
  - Support configuration KAFKA_NODES dynamique
  - Modes dry-run et validation interactive
  - Gestion d'idempotence et recovery
- **v1.0.0** - Version initiale basique (obsolète)

### Utilisation

```bash
install_zookeeper.sh [OPTIONS]

OPTIONS:
  -h, --help              Afficher l'aide
  -v, --version           Afficher la version  
  -n, --node-id NUM       ID du nœud ZooKeeper (1-3) [OBLIGATOIRE]
  -r, --repo-server IP    IP du serveur repository (défaut: 172.20.2.109)
  --dry-run              Mode test sans modification
  --check-fs             Vérifier seulement les filesystems
  --skip-validation      Ignorer la validation interactive
  --force-reinstall      Forcer la réinstallation
```

### Exemples d'utilisation

```bash
# Installation nœud ZooKeeper ID 1 (après Kafka)
./install_zookeeper.sh -n 1

# Installation avec repository custom
./install_zookeeper.sh -n 2 -r 172.20.2.109

# Mode test
./install_zookeeper.sh -n 1 --dry-run

# Vérification filesystem
./install_zookeeper.sh --check-fs

# Installation automatique
./install_zookeeper.sh -n 3 --skip-validation

# Réinstallation forcée
./install_zookeeper.sh -n 1 --force-reinstall
```

### Héritage de configuration

ZooKeeper hérite automatiquement de la configuration KAFKA_NODES pour garantir la cohérence :

```bash
# Si KAFKA_NODES est défini, ZooKeeper l'utilise automatiquement
export KAFKA_NODES="1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
./install_kafka_cluster.sh -n 1
./install_zookeeper.sh -n 1  # Hérite de KAFKA_NODES
```

### Configuration ZooKeeper générée

```properties
# Exemple de zoo.cfg généré
tickTime=2000
initLimit=10  
syncLimit=5
dataDir=/data/zookeeper
clientPort=2181

# Ensemble cluster
server.1=172.20.2.113:2888:3888
server.2=172.20.2.114:2888:3888  
server.3=172.20.2.115:2888:3888

# Configuration bancaire
autopurge.snapRetainCount=5
autopurge.purgeInterval=24
maxClientCnxns=60
4lw.commands.whitelist=stat,ruok,conf,isro,srvr,mntr
```

---

## 🔧 Opérations post-installation

### Validation cluster ZooKeeper

```bash
# État du nœud
echo ruok | nc localhost 2181
# Réponse attendue: imok

# Statistiques ensemble
echo stat | nc localhost 2181

# Configuration active
echo conf | nc localhost 2181

# Surveillance continue
echo mntr | nc localhost 2181
```

### Validation cluster Kafka

```bash
# Liste des topics
kafka-topics.sh --bootstrap-server localhost:9092 --list

# Test de connectivité inter-brokers
kafka-broker-api-versions.sh --bootstrap-server 172.20.2.113:9092

# Création topic de test
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic test-acm --partitions 5 --replication-factor 3
```

### Surveillance et logs

```bash
# Logs ZooKeeper
journalctl -u zookeeper -f

# Logs Kafka  
journalctl -u kafka -f

# Métriques système
systemctl status zookeeper kafka
```

---

## 🚨 Résolution de problèmes

### Erreurs courantes

#### "PRÉREQUIS MANQUANT: Le script install_kafka_cluster.sh doit être exécuté EN PREMIER!"
**Solution** : Exécuter `install_kafka_cluster.sh` avant `install_zookeeper.sh` sur chaque nœud.

#### "Filesystem /data/kafka non monté"
**Solution** : Vérifier le montage des filesystems dédiés :
```bash
# Vérification
mountpoint /data/kafka
mountpoint /data/zookeeper

# Correction si nécessaire
mount /data/kafka
mount /data/zookeeper
```

#### "Échec téléchargement depuis repository"
**Solution** : Vérifier connectivité repository :
```bash
# Test connectivité
curl -I http://172.20.2.109/repos/kafka3/

# Vérifier services repository
ssh root@172.20.2.109 "systemctl status httpd"
```

#### Problème de quorum ZooKeeper
**Solution** : Démarrer ZooKeeper sur majorité des nœuds (2/3 minimum) :
```bash
# Vérifier statut sur tous les nœuds
for ip in 172.20.2.113 172.20.2.114 172.20.2.115; do
  echo "=== $ip ==="
  ssh root@$ip "systemctl status zookeeper"
done
```

### Commandes de diagnostic

```bash
# Connectivité réseau inter-nœuds
for port in 2181 2888 3888 9092; do
  for ip in 172.20.2.113 172.20.2.114 172.20.2.115; do
    telnet $ip $port
  done
done

# Validation configuration SELinux
sealert -a /var/log/audit/audit.log

# Vérification règles firewall
firewall-cmd --list-ports
firewall-cmd --list-services
```

---

## 📁 Structure des fichiers

### Arborescence Kafka
```
/opt/kafka/              # Installation Kafka
├── bin/                 # Exécutables
├── config/             # Configurations
│   └── server.properties # Config principale générée
├── libs/               # Librairies JAR
└── logs/               # Logs applicatifs

/data/kafka/            # Données Kafka (filesystem dédié)
├── __consumer_offsets-*/ # Topics système
└── test-acm-*/        # Topics métier

/var/log/kafka/         # Logs système
```

### Arborescence ZooKeeper
```
/opt/zookeeper/         # Installation ZooKeeper
├── bin/               # Exécutables
├── conf/              # Configurations
│   └── zoo.cfg        # Config principale générée
└── lib/               # Librairies JAR

/data/zookeeper/       # Données ZooKeeper (filesystem dédié)
├── myid               # ID du nœud
├── log/               # Transaction logs
└── snapshot/          # Snapshots état

/var/log/zookeeper/    # Logs système
```

---

## 🔒 Sécurité et conformité

### Standards respectés
- **PCI-DSS** : Chiffrement réseau, permissions restrictives, audit trail
- **ANSSI-BP-028** : SELinux, firewall, isolation processus, comptes dédiés
- **Banking Standards** : Haute disponibilité, monitoring, sauvegarde

### Permissions système
```bash
# Comptes de service
kafka:kafka (uid/gid dédiés)
zookeeper:zookeeper (uid/gid dédiés)

# Permissions répertoires
/opt/kafka: 750 kafka:kafka
/opt/zookeeper: 750 zookeeper:zookeeper
/data/kafka: 750 kafka:kafka  
/data/zookeeper: 750 zookeeper:zookeeper
```

### Ports réseau configurés
```bash
# Kafka
9092/tcp - Communication inter-brokers et clients

# ZooKeeper  
2181/tcp - Clients (Kafka)
2888/tcp - Communication peer-to-peer
3888/tcp - Élection leader

# Repository
80/tcp - Téléchargement packages (vers 172.20.2.109)
```

---

## 🧑‍💻 Informations développeur

### Auteur
Philippe Candido (philippe.candido@emerging-it.fr)

### Méthode Basher Pro
Les scripts respectent la méthode Basher Pro avec :
- Gestion d'erreurs stricte (`set -euo pipefail`)
- Logging centralisé avec timestamps
- Modes de fonctionnement multiples (dry-run, check, validation)
- Idempotence et recovery automatique
- Aide et versioning intégrés

### Support et maintenance
- **Versions** : Scripts versionnés avec changelog détaillé
- **Logs** : `/var/log/*-install-*.log` pour chaque exécution
- **Idempotence** : Réexécution sûre des scripts
- **Recovery** : Détection automatique installations existantes

---

## 📞 Support

Pour tout problème technique ou question sur le déploiement :

1. **Vérifier les logs** : `/var/log/kafka-install-*.log` et `/var/log/zookeeper-install-*.log`
2. **Consulter la documentation** : Ce README et commentaires dans les scripts
3. **Utiliser les modes de diagnostic** : `--dry-run`, `--check-fs`, `-v`
4. **Contacter l'équipe** : philippe.candido@emerging-it.fr

---

*Dernière mise à jour : 2025-07-06*  
*Compatible : RHEL 9, Kafka 3.9.0, ZooKeeper 3.8.4*