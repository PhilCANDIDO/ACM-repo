#!/usr/bin/env bash

# Changelog:
# v1.4.0 (2025-07-07): Enhanced visual output with dashboard-style reporting and user-friendly interface
# v1.3.0 (2025-07-07): Fix Test 3 to use correct zookeeper-shell.sh invocation and validate count of broker IDs.
# v1.2.0 (2025-07-07): Redirect debug output to stderr and apply exec_cmd to Test 1 & 2.
# v1.1.0 (2025-07-07): Added --debug option to display executed commands for each test.
# v1.0.0 (2025-07-07): Initial release implementing Kafka multibroker diagnostics.

script_name=$(basename "$0")
script_version="v1.4.0"

# Enhanced ANSI color codes and formatting
BLUE='\e[1;34m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
RED='\e[1;31m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
WHITE='\e[1;37m'
GRAY='\e[0;37m'
BOLD='\e[1m'
DIM='\e[2m'
RESET='\e[0m'

# Box drawing characters
TOP_LEFT='╭'
TOP_RIGHT='╮'
BOTTOM_LEFT='╰'
BOTTOM_RIGHT='╯'
HORIZONTAL='─'
VERTICAL='│'
CROSS='┼'
T_DOWN='┬'
T_UP='┴'
T_RIGHT='├'
T_LEFT='┤'

# Icons and symbols
ICON_SUCCESS='✅'
ICON_ERROR='❌'
ICON_WARNING='⚠️ '
ICON_INFO='ℹ️ '
ICON_KAFKA='🔧'
ICON_ZOOKEEPER='🐘'
ICON_CLUSTER='🔗'
ICON_TEST='🧪'
ICON_REPORT='📊'
ICON_TIME='⏱️ '

# Defaults
LOG_FILE="./${script_name}.log"
ZK_PORT=2181
KAFKA_PORT=9092
DEBUG=false
overall_status=0
test_results=()
test_count=0
passed_tests=0
failed_tests=0
warning_tests=0
start_time=$(date +%s)

print_help() {
  cat <<EOF
${BOLD}${CYAN}${TOP_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${TOP_RIGHT}${RESET}
${BOLD}${CYAN}${VERTICAL}${RESET} ${BOLD}${WHITE}Kafka Cluster Diagnostic Tool - Version ${script_version}${RESET}$(printf "%*s" 29 "")${BOLD}${CYAN}${VERTICAL}${RESET}
${BOLD}${CYAN}${VERTICAL}${RESET} ${ICON_KAFKA} ${WHITE}Expert tool for banking infrastructure security specialists${RESET}$(printf "%*s" 18 "")${BOLD}${CYAN}${VERTICAL}${RESET}
${BOLD}${CYAN}${BOTTOM_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${BOTTOM_RIGHT}${RESET}

${BOLD}${WHITE}USAGE:${RESET}
  $script_name --brokers "<id1:ip1,id2:ip2,...>" [OPTIONS]

${BOLD}${WHITE}DESCRIPTION:${RESET}
  This script performs comprehensive diagnostics on a Kafka multibroker cluster
  (Kafka v3.9.1, ZooKeeper). Designed for air-gapped RHEL 9 banking environments
  with PCI-DSS and ANSSI-BP-028 compliance requirements.

${BOLD}${WHITE}REQUIRED PARAMETERS:${RESET}
  ${BOLD}--brokers${RESET}          Comma-separated list of broker_id:broker_ip pairs
                       Example: "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"

${BOLD}${WHITE}OPTIONS:${RESET}
  ${BOLD}-h, --help${RESET}         Show this help message and exit
  ${BOLD}--log-file <path>${RESET}  Log output (with timestamps) to the specified file
                       Default: ./${script_name}.log
  ${BOLD}--debug${RESET}            Display the commands executed for each test

${BOLD}${WHITE}EXAMPLES:${RESET}
  ${DIM}# Standard 3-node cluster diagnostic${RESET}
  $script_name --brokers "1:172.20.2.113,2:172.20.2.114,3:172.20.2.115"
  
  ${DIM}# With custom log file and debug mode${RESET}
  $script_name --brokers "1:172.20.2.113,2:172.20.2.114" --log-file /var/log/kafka-diag.log --debug

${BOLD}${WHITE}TESTS PERFORMED:${RESET}
  ${ICON_TEST} ZooKeeper connectivity and health
  ${ICON_TEST} ZooKeeper ensemble roles validation  
  ${ICON_TEST} Broker registration verification
  ${ICON_TEST} Kafka port accessibility
  ${ICON_TEST} Kafka API functionality
  ${ICON_TEST} Log analysis for critical errors
  ${ICON_TEST} Consumer offsets topic validation
  ${ICON_TEST} Cluster metadata retrieval
  ${ICON_TEST} End-to-end produce/consume test

${BOLD}${WHITE}EXIT CODES:${RESET}
  0  All tests passed successfully
  1  One or more tests failed - requires attention

${DIM}Report bugs to: ACM Infrastructure Team${RESET}
EOF
}

# Enhanced logging with better formatting
log() {
  local level="$1"
  local msg="$2"
  local ts
  ts=$(date +"[%Y-%m-%d %H:%M:%S]")
  echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
}

# Enhanced command execution with better debugging
exec_cmd() {
  local cmd="$1"
  if [ "$DEBUG" = true ]; then
    echo -e "${DIM}${BLUE}[DEBUG]${RESET}${DIM} Executing: $cmd${RESET}" >&2
  fi
  eval "$cmd"
}

# Enhanced message functions with icons and better formatting
print_separator() {
  local width=80
  echo -e "${GRAY}$(printf "%*s" $width "" | tr ' ' '─')${RESET}"
}

print_header() {
  local title="$1"
  local width=80
  local title_len=${#title}
  local padding=$(( (width - title_len - 2) / 2 ))
  
  echo
  echo -e "${BOLD}${CYAN}${TOP_LEFT}$(printf "%*s" $((width-2)) "" | tr ' ' "${HORIZONTAL}")${TOP_RIGHT}${RESET}"
  printf "${BOLD}${CYAN}${VERTICAL}${RESET}%*s${BOLD}${WHITE}%s${RESET}%*s${BOLD}${CYAN}${VERTICAL}${RESET}\n" $padding "" "$title" $padding ""
  echo -e "${BOLD}${CYAN}${BOTTOM_LEFT}$(printf "%*s" $((width-2)) "" | tr ' ' "${HORIZONTAL}")${BOTTOM_RIGHT}${RESET}"
  echo
}

print_test_header() {
  local test_num="$1"
  local test_name="$2"
  echo
  echo -e "${BOLD}${MAGENTA}${T_RIGHT}$(printf "%*s" 3 "" | tr ' ' "${HORIZONTAL}") ${ICON_TEST} Test ${test_num}: ${test_name} $(printf "%*s" $((45 - ${#test_name})) "" | tr ' ' "${HORIZONTAL}")${RESET}"
}

info() {
  echo -e "${BOLD}${BLUE}${ICON_INFO}${RESET} ${BLUE}$1${RESET}"
  log "INFO" "$1"
}

success() {
  echo -e "${BOLD}${GREEN}${ICON_SUCCESS}${RESET} ${GREEN}$1${RESET}"
  log "SUCCESS" "$1"
  ((passed_tests++))
}

warning() {
  echo -e "${BOLD}${YELLOW}${ICON_WARNING}${RESET} ${YELLOW}$1${RESET}"
  log "WARNING" "$1"
  ((warning_tests++))
}

error() {
  echo -e "${BOLD}${RED}${ICON_ERROR}${RESET} ${RED}$1${RESET}"
  log "ERROR" "$1"
  overall_status=1
  ((failed_tests++))
}

# Progress bar function
show_progress() {
  local current="$1"
  local total="$2"
  local width=50
  local percentage=$((current * 100 / total))
  local filled=$((current * width / total))
  local empty=$((width - filled))
  
  printf "\r${BOLD}${CYAN}Progress: ${RESET}["
  printf "%*s" $filled "" | tr ' ' '█'
  printf "%*s" $empty "" | tr ' ' '░'
  printf "] %d%% (%d/%d tests)" $percentage $current $total
}

# Enhanced cluster summary
print_cluster_summary() {
  local broker_count="$1"
  local broker_list="$2"
  
  echo
  echo -e "${BOLD}${CYAN}${TOP_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${TOP_RIGHT}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${ICON_CLUSTER} ${BOLD}${WHITE}CLUSTER CONFIGURATION SUMMARY${RESET}$(printf "%*s" 42 "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${T_RIGHT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${T_LEFT}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Brokers Count:${RESET} ${BOLD}${GREEN}${broker_count}${RESET}$(printf "%*s" $((61 - ${#broker_count})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}ZooKeeper Port:${RESET} ${BOLD}${YELLOW}${ZK_PORT}${RESET}$(printf "%*s" $((58 - ${#ZK_PORT})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Kafka Port:${RESET} ${BOLD}${YELLOW}${KAFKA_PORT}${RESET}$(printf "%*s" $((62 - ${#KAFKA_PORT})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${T_RIGHT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${T_LEFT}${RESET}"
  
  # Print broker details
  IFS=',' read -r -a entries <<< "$broker_list"
  for entry in "${entries[@]}"; do
    local broker_id="${entry%%:*}"
    local broker_ip="${entry#*:}"
    echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Broker ${broker_id}:${RESET} ${BOLD}${MAGENTA}${broker_ip}${RESET}$(printf "%*s" $((65 - ${#broker_ip} - ${#broker_id})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  done
  
  echo -e "${BOLD}${CYAN}${BOTTOM_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${BOTTOM_RIGHT}${RESET}"
}

# Enhanced final report
print_final_report() {
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local status_color="${GREEN}"
  local status_icon="${ICON_SUCCESS}"
  local status_text="HEALTHY"
  
  if [ $overall_status -ne 0 ]; then
    status_color="${RED}"
    status_icon="${ICON_ERROR}"
    status_text="ISSUES DETECTED"
  elif [ $warning_tests -gt 0 ]; then
    status_color="${YELLOW}"
    status_icon="${ICON_WARNING}"
    status_text="WARNINGS PRESENT"
  fi
  
  echo
  echo
  echo -e "${BOLD}${CYAN}${TOP_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${TOP_RIGHT}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${ICON_REPORT} ${BOLD}${WHITE}KAFKA CLUSTER DIAGNOSTIC REPORT${RESET}$(printf "%*s" 40 "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${T_RIGHT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${T_LEFT}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Overall Status:${RESET} ${BOLD}${status_color}${status_icon} ${status_text}${RESET}$(printf "%*s" $((53 - ${#status_text})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${T_RIGHT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${T_LEFT}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Tests Executed:${RESET} ${BOLD}${BLUE}${test_count}${RESET}$(printf "%*s" $((58 - ${#test_count})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Tests Passed:${RESET} ${BOLD}${GREEN}${passed_tests}${RESET}$(printf "%*s" $((60 - ${#passed_tests})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Tests Failed:${RESET} ${BOLD}${RED}${failed_tests}${RESET}$(printf "%*s" $((60 - ${#failed_tests})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Warnings:${RESET} ${BOLD}${YELLOW}${warning_tests}${RESET}$(printf "%*s" $((64 - ${#warning_tests})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${T_RIGHT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${T_LEFT}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${ICON_TIME}${WHITE}Execution Time:${RESET} ${BOLD}${MAGENTA}${duration}s${RESET}$(printf "%*s" $((58 - ${#duration})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${VERTICAL}${RESET} ${WHITE}Log File:${RESET} ${BOLD}${CYAN}${LOG_FILE}${RESET}$(printf "%*s" $((68 - ${#LOG_FILE})) "")${BOLD}${CYAN}${VERTICAL}${RESET}"
  echo -e "${BOLD}${CYAN}${BOTTOM_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${BOTTOM_RIGHT}${RESET}"
  
  # Recommendations section
  if [ $overall_status -ne 0 ] || [ $warning_tests -gt 0 ]; then
    echo
    echo -e "${BOLD}${YELLOW}${TOP_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${TOP_RIGHT}${RESET}"
    echo -e "${BOLD}${YELLOW}${VERTICAL}${RESET} ${ICON_WARNING} ${BOLD}${WHITE}RECOMMENDED ACTIONS${RESET}$(printf "%*s" 52 "")${BOLD}${YELLOW}${VERTICAL}${RESET}"
    echo -e "${BOLD}${YELLOW}${T_RIGHT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${T_LEFT}${RESET}"
    echo -e "${BOLD}${YELLOW}${VERTICAL}${RESET} ${WHITE}1. Review detailed logs:${RESET} ${CYAN}cat ${LOG_FILE}${RESET}$(printf "%*s" $((45 - ${#LOG_FILE})) "")${BOLD}${YELLOW}${VERTICAL}${RESET}"
    echo -e "${BOLD}${YELLOW}${VERTICAL}${RESET} ${WHITE}2. Check Kafka service status:${RESET} ${CYAN}systemctl status kafka${RESET}$(printf "%*s" 25 "")${BOLD}${YELLOW}${VERTICAL}${RESET}"
    echo -e "${BOLD}${YELLOW}${VERTICAL}${RESET} ${WHITE}3. Verify ZooKeeper ensemble:${RESET} ${CYAN}echo stat | nc localhost 2181${RESET}$(printf "%*s" 14 "")${BOLD}${YELLOW}${VERTICAL}${RESET}"
    echo -e "${BOLD}${YELLOW}${VERTICAL}${RESET} ${WHITE}4. Contact ACM Infrastructure Team if issues persist${RESET}$(printf "%*s" 20 "")${BOLD}${YELLOW}${VERTICAL}${RESET}"
    echo -e "${BOLD}${YELLOW}${BOTTOM_LEFT}$(printf "%*s" 78 "" | tr ' ' "${HORIZONTAL}")${BOTTOM_RIGHT}${RESET}"
  fi
}

# Parse arguments
if [ $# -eq 0 ]; then
  print_help
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help; exit 0;;
    --brokers)
      BROKERS_STR="$2"; shift 2;;
    --log-file)
      LOG_FILE="$2"; shift 2;;
    --debug)
      DEBUG=true; shift;;
    *)
      echo -e "${RED}${ICON_ERROR} Unknown argument: $1${RESET}"
      print_help; exit 1;;
  esac
done

if [ -z "${BROKERS_STR:-}" ]; then
  error "Argument --brokers is required"
  print_help
  exit 1
fi

# Initialize log file
: > "$LOG_FILE"

# Welcome banner
clear
print_header "KAFKA CLUSTER DIAGNOSTIC TOOL"

info "Starting Kafka multibroker diagnostic (version ${script_version})"
info "Target environment: Air-gapped RHEL 9 banking infrastructure"
info "Compliance: PCI-DSS, ANSSI-BP-028"

# Parse brokers into arrays
IFS=',' read -r -a entries <<< "$BROKERS_STR"
broker_ids=(); broker_ips=()
for e in "${entries[@]}"; do
  broker_ids+=("${e%%:*}")
  broker_ips+=("${e#*:}")
done
num_brokers=${#broker_ips[@]}
first_broker_ip=${broker_ips[0]}

print_cluster_summary "$num_brokers" "$BROKERS_STR"

# Test execution
total_tests=9
test_count=0

#
# Test 1: ZooKeeper connectivity
#
((test_count++))
print_test_header "$test_count" "ZooKeeper Connectivity Check"
show_progress $test_count $total_tests
echo
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
((test_count++))
print_test_header "$test_count" "ZooKeeper Ensemble Roles"
show_progress $test_count $total_tests
echo
leader_count=0; follower_count=0
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
((test_count++))
print_test_header "$test_count" "Broker Registration Verification"
show_progress $test_count $total_tests
echo
cmd="/opt/kafka/bin/zookeeper-shell.sh ${first_broker_ip}:${ZK_PORT} ls /brokers/ids"
zk_output=$(exec_cmd "$cmd" | tail -n1)
# expected format: [1, 2, 3]
if [[ $zk_output =~ ^\[(.+)\]$ ]]; then
  IFS=',' read -r -a reg_ids <<< "${BASH_REMATCH[1]}"
  # trim whitespace
  for i in "${!reg_ids[@]}"; do
    reg_ids[$i]=$(echo "${reg_ids[$i]}" | xargs)
  done
  # compare counts
  if [ "${#reg_ids[@]}" -eq "$num_brokers" ]; then
    success "Brokers registered: [${reg_ids[*]}]"
  else
    error "Expected ${num_brokers} brokers in ZooKeeper but found ${#reg_ids[@]}: [${reg_ids[*]}]"
  fi
else
  error "Unable to parse broker list from ZooKeeper output"
fi

#
# Test 4: Kafka port open
#
((test_count++))
print_test_header "$test_count" "Kafka Port Accessibility"
show_progress $test_count $total_tests
echo
for ip in "${broker_ips[@]}"; do
  cmd="nc -z -w 5 \"$ip\" \"$KAFKA_PORT\" 2>/dev/null"
  if exec_cmd "$cmd"; then
    success "${ip} is listening on ${KAFKA_PORT}"
  else
    error "Broker ${ip} not listening on ${KAFKA_PORT}"
  fi
done

#
# Test 5: Kafka API accessibility
#
((test_count++))
print_test_header "$test_count" "Kafka API Functionality"
show_progress $test_count $total_tests
echo
cmd="/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" &>/dev/null"
if exec_cmd "$cmd"; then
  success "Kafka API is accessible on ${first_broker_ip}:${KAFKA_PORT}"
else
  error "Kafka API is not reachable"
fi

#
# Test 6: Check Kafka logs for errors
#
((test_count++))
print_test_header "$test_count" "Kafka Log Analysis"
show_progress $test_count $total_tests
echo
if [ -f /var/log/kafka/server.log ]; then
  cmd="tail -n 50 /var/log/kafka/server.log | grep -E 'ERROR|Exception'"
  errors=$(exec_cmd "$cmd" || true)
  if [ -z "$errors" ]; then
    success "No critical errors in last 50 lines of server.log"
  else
    warning "Errors found in server.log - review required"
  fi
else
  warning "Log file not found: /var/log/kafka/server.log"
fi

#
# Test 7: Topic __consumer_offsets
#
((test_count++))
print_test_header "$test_count" "Consumer Offsets Topic"
show_progress $test_count $total_tests
echo
cmd="/opt/kafka/bin/kafka-topics.sh --bootstrap-server \"${first_broker_ip}:${KAFKA_PORT}\" --describe --topic __consumer_offsets &>/dev/null"
if exec_cmd "$cmd"; then
  success "Topic __consumer_offsets is accessible and properly distributed"
else
  error "Topic __consumer_offsets missing or inaccessible"
fi

#
# Test 8: Cluster metadata
#
((test_count++))
print_test_header "$test_count" "Cluster Metadata Retrieval"
show_progress $test_count $total_tests
echo
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
((test_count++))
print_test_header "$test_count" "End-to-End Produce/Consume Test"
show_progress $test_count $total_tests
echo
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

# Complete progress bar
echo
show_progress $total_tests $total_tests
echo
echo

# Final report
print_final_report

exit $overall_status