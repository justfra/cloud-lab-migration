#!/usr/bin/env bash

set -Eeuo pipefail

: "${DRY_RUN:=0}"
: "${VERBOSE:=0}"
: "${STRICT:=0}"

LOG_FILE=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
  C_CYAN=''
fi

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$level" "$*"
}

log_info() {
  log "INFO" "$@"
}

log_warn() {
  log "WARN" "$@"
}

log_error() {
  log "ERROR" "$@"
}

die() {
  log_error "$*"
  exit 1
}

init_logging() {
  local log_path="$1"
  local log_dir
  log_dir="$(dirname "$log_path")"

  if ! mkdir -p "$log_dir" 2>/dev/null; then
    log_dir="/tmp/migration_logs"
    mkdir -p "$log_dir"
    log_path="$log_dir/$(basename "$log_path")"
  fi

  if ! touch "$log_path" 2>/dev/null; then
    log_dir="/tmp/migration_logs"
    mkdir -p "$log_dir"
    log_path="$log_dir/$(basename "$log_path")"
    touch "$log_path"
  fi

  LOG_FILE="$log_path"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    require_cmd "$cmd"
  done
}

optional_cmd_warn() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_warn "Optional command not found: $cmd"
    return 1
  fi
  return 0
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root (or with sudo)."
  fi
}

run_cmd() {
  if ((DRY_RUN)); then
    log_info "DRY-RUN: $*"
    return 0
  fi
  if ((VERBOSE)); then
    log_info "RUN: $*"
  fi
  "$@"
}

run_capture() {
  local output_file="$1"
  shift

  mkdir -p "$(dirname "$output_file")"
  if ((DRY_RUN)); then
    log_info "DRY-RUN: capture '$*' -> $output_file"
    return 0
  fi

  if ((VERBOSE)); then
    log_info "CAPTURE: $* -> $output_file"
  fi
  "$@" >"$output_file"
}

print_summary_header() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

print_status_line() {
  local status="$1"
  local label="$2"
  local details="$3"
  local color="$C_CYAN"

  case "$status" in
    OK) color="$C_GREEN" ;;
    WARN) color="$C_YELLOW" ;;
    FAIL) color="$C_RED" ;;
  esac

  printf '%b%-5s%b %s - %s\n' "$color" "$status" "$C_RESET" "$label" "$details"
}
