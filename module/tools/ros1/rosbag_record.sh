#!/bin/bash

OUTPUT_NAME="dual_scan_data"
DURATION="30s"

EXACT_TOPICS=(
  "/scan"
  "/scan_b"
)

FUZZY_TOPICS=(
  "/tf.*"
)

rosbag_regex() {
  local final_regex=""
  local topic
  for topic in "${EXACT_TOPICS[@]}"; do
    if [ -n "$final_regex" ]; then
      final_regex+="|"
    fi
    final_regex="${final_regex}^${topic}$"
  done

  for topic in "${FUZZY_TOPICS[@]}"; do
    if [ -n "$final_regex" ]; then
      final_regex+="|"
    fi
    final_regex="${final_regex}${topic}"
  done

  printf "===========================\n"
  printf "Final regex: %s\n" "${final_regex}"
  printf "Recording duration: %s\n" "${DURATION}"
  printf "===========================\n"

  rosbag record \
    -O "${OUTPUT_NAME}_$(date +%Y%m%d-%H%M%S).bag" \
    --duration="${DURATION}" \
    -e "${final_regex}"
}

rosbag_regex
