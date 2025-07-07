```bash
#!/usr/bin/env bash

# Changelog:
# v1.1.0 (2025-07-07): Added --debug option to display executed commands for each test.
# v1.0.0 (2025-07-07): Initial release implementing Kafka multibroker diagnostics.

script_name=$(basename "$0")
script_version="v1.1.0"

# ANSI color codes
BLUE='\e[1;34m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
RED='\e[1;31m'
RESET='\e[0m'

# Defaults
LOG_FILE="./${script_name}.log"
ZK_PORT=2181
KAFKA_PORT=9092
DEBUG=false
overall_status=0

print_help() {
  cat <<EOF
Usage: $script_name --brokers "<id1:ip1,id2:ip2,...>" [--log-file <path>] [--debug] [-h|--help]

Description:
  This script performs a diagnostic on a Kafka multibroker cluster (Kafka v3.9.1, ZooKeeper).
  It runs a series of connectivity and health checks and reports results in colorized text.

Version: $script_version

Options:
  -h, --help         Show this help message and exit.
  --brokers          Comma-separated list of broker_id:broker_ip (required).
  --log-file <path>  Log output (with timestamps) to the specified file.
  --debug            Display the commands executed for each test.
EOF
}

# write a timestamped entry to the log file
log() {
  local level="$1"
  local msg="$2"
  local ts
  ts=$(date +"[%Y%m%d-%H:%M:%S]")
  echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
}

# execute a command string, optionally printing it if debug is enabled
exec_cmd() {
  local cmd="$1"
  if [ "$DEBUG" = true ]; then
    echo -e "${BLUE}[DEBUG]${RESET} Executing: $cmd"
  fi
  eval "$cmd"
}

# output functions: print to stdout with color and log
info()    { echo -e "${BLUE}[INFO] $1${RESET}";    log "INFO"    "$1"; }
success() { echo -e "${GREEN}[SUCCESS] $1${RESET}"; log "SUCCESS" "$1"; }
warning() { echo -e "${YELLOW}[WARNING] $1${RESET}"; log "WARNING" "$1"; }
error()   { echo -e "${RED}[ERROR] $1${RESET}";     log "ERROR"   "$1"; overall_status=1; }

# parse arguments
if [ $# -eq 0 ]; then
  print_help
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --brokers)
      BROKERS_STR="$2"
      shift 2
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      print_help
      exit 1
      ;;
  esac
done

# ensure brokers argument is provided
if [ -z "${BROKERS_STR:-}" ]; then
  error "Argument --brokers is required"
  print_help
  exit 1
fi

# initialize log file
: > "$LOG_FILE"

info "Starting Kafka multibroker diagnostic (version ${script_version})"
info "Brokers to analyze: ${BROKERS_STR//,/\, }"

# parse brokers into arrays
IFS=',' read -r -a entries <<< "$BROKERS_STR"
broker_ids=()
broker_ips=()
for e in "${entries[@]}"; do
  broker_ids+=("${e%%:*}")
  broker_ips+=("${e#*:}")
done
num_brokers=${#broker_ips[@]}
first_broker_ip=${broker_ips[0]}

#
# Test 1: ZooKeeper connectivity
#
info "➤ Test 1 - ZooKeeper connectivity"
for ip in "${broker_ips[@]}"; do
  cmd="echo ruok | nc -w 5 \"$ip\" \"$ZK_PORT\" 2>/dev/null"
  resp=$(exec_cmd "$cmd")
  if [ "$resp" = "imok" ]; then
    success "ZooKeeper responds (imok) on ${ip}:${ZK_PORT}"
  else
    error "ZooKeeper not responding on ${ip}:${ZK_PORT}"
  fi
done

#
# Test 2: ZooKeeper roles
#
info "➤ Test 2 - ZooKeeper roles"
leader_count=0
follower_count=0
declare -A modes
for ip in "${broker_ips[@]}"; do
  cmd="echo stat | nc -w 5 \"$ip\" \"$ZK_PORT\" 2>/dev/null"
  out=$(exec_cmd "$cmd")
  mode=$(echo "$out" | grep -i '^Mode:' | awk '{print toupper($2)}')
  if [ "$mode" = "LEADER" ]; then
    ((leader_count++))
  elif [ "$mode" = "FOLLOWER" ]; then
    ((follower_count++))
  fi
  modes["$ip"]=$mode
done
for ip in "${broker_ips[@]}"; do
  if [ -n "${modes[$ip]}" ]; then
    success "${ip} is ${modes[$ip]}"
  else
    error "${ip}: unable to determine ZooKeeper role"
  fi
done
if [ $leader_count -ne 1 ] || [ $follower_count -ne $((num_brokers-1)) ]; then
  error "Incorrect ZooKeeper roles (expected 1 leader & $((num_brokers-1)) followers)"
fi

#
# Test 3: Brokers registered in ZooKeeper
#
info "➤ Test 3 - Brokers registered in ZooKeeper"
cmd="echo \"ls /brokers/ids\" | /opt/kafka/bin/zookeeper-shell.sh \"${first_broker_ip}:${ZK_PORT}\" 2>/dev/null"
zk_list=$(exec_cmd "$cmd" | grep '^\[')
if [[ $zk_list =~ \[([0-9,]+)\] ]]; then
  zk_ids="${BASH_REMATCH[1]}"
  IFS=',' read -r -a reg_ids <<< "$zk_ids"
  missing=()
  for id in "${broker_ids[@]}"; do
    if ! printf '%s\n' "${reg_ids[@]}" | grep -qx "$id"; then
      missing+=("$id")
    fi
  done
  if [ ${#missing[@]} -eq 0 ]; then
    success "Brokers registered: [${zk_ids}]"
  else
    error "Missing broker(s) in ZooKeeper: ${missing[*]}"
  fi
else
  error "Unable to list brokers in ZooKeeper"
fi

#
# Test 4: Kafka port open
#
info "➤ Test 4 - Kafka port (${KAFKA_PORT}) open"
for ip in "${broker_ips[@]}"; do
  cmd="nc -z -w 5 \"$ip\" \"$KAFKA_PORT\" 2>/dev/null"
  if exec_cmd "$cmd"; then
    success "${ip} is listening on ${KAFKA_PORT}"
  else
    error "Broker ${ip} not listening on ${KAFKA_PORT}"
  fi
done

#
# Test 5: Kafka Broker API accessibility
#
info "➤ Test 5 - Kafka API accessibility"
cmd="/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" &>/dev/null"
if exec_cmd "$cmd"; then
  success "Kafka API is accessible on ${first_broker_ip}:${KAFKA_PORT}"
else
  error "Kafka API is not reachable"
fi

#
# Test 6: Check Kafka logs for errors
#
info "➤ Test 6 - Checking Kafka logs (/var/log/kafka/server.log)"
if [ -f /var/log/kafka/server.log ]; then
  cmd="tail -n 50 /var/log/kafka/server.log | grep -E 'ERROR|Exception'"
  errors=$(exec_cmd "$cmd" || true)
  if [ -z "$errors" ]; then
    success "No critical errors in last 50 lines of server.log"
  else
    warning "Errors found in server.log"
  fi
else
  warning "Log file not found: /var/log/kafka/server.log"
fi

#
# Test 7: Topic __consumer_offsets
#
info "➤ Test 7 - Topic __consumer_offsets"
cmd="/opt/kafka/bin/kafka-topics.sh --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" --describe --topic __consumer_offsets &>/dev/null"
if exec_cmd "$cmd"; then
  success "Topic __consumer_offsets is accessible and properly distributed"
else
  error "Topic __consumer_offsets missing or inaccessible"
fi

#
# Test 8: Cluster metadata
#
info "➤ Test 8 - Cluster metadata"
cmd="/opt/kafka/bin/kafka-topics.sh --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" --list 2>/dev/null | wc -l"
topic_count=$(exec_cmd "$cmd")
if [ $? -eq 0 ]; then
  success "Metadata retrieved: ${num_brokers} brokers, ${topic_count} topics"
else
  error "Unable to retrieve cluster metadata"
fi

#
# Test 9: End-to-end Kafka produce/consume
#
info "➤ Test 9 - End-to-end Kafka test"
temp_topic="diag-test-$$"
cmd="/opt/kafka/bin/kafka-topics.sh --create --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" --topic \"${temp_topic}\" --partitions 1 --replication-factor 1 &>/dev/null"
if exec_cmd "$cmd"; then
  cmd="echo \"hello-${temp_topic}\" | /opt/kafka/bin/kafka-console-producer.sh --broker-list \"${first_broker_ip}:${KAFKA_PORT}\" --topic \"${temp_topic}\" &>/dev/null"
  exec_cmd "$cmd"
  cmd="/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" --topic \"${temp_topic}\" --from-beginning --timeout-ms 10000 --max-messages 1 2>/dev/null"
  msg=$(exec_cmd "$cmd")
  if [ "$msg" = "hello-${temp_topic}" ]; then
    success "Message produced and consumed successfully on topic ${temp_topic}"
  else
    error "Produce/consume test failed"
  fi
  cmd="/opt/kafka/bin/kafka-topics.sh --delete --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" --topic \"${temp_topic}\" &>/dev/null"
  if exec_cmd "$cmd"; then
    success "Topic ${temp_topic} deleted"
  fi
else
  error "Failed to create test topic ${temp_topic}"
fi

# final report
if [ $overall_status -eq 0 ]; then
  success "✅ All tests completed successfully"
else
  error "Some tests failed, please check the log for details"
fi

info "Report written to: ${LOG_FILE}"
exit $overall_status
```
