#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ARCHIVE_PATH=""
PASS=0
WARN=0
FAIL=0

usage() {
  cat <<'EOF'
Usage: preflight_target.sh [--archive <migration-*.tar.bz2>] [--verbose]
EOF
}

ok() { PASS=$((PASS + 1)); print_status_line "OK" "$1" "$2"; }
wa() { WARN=$((WARN + 1)); print_status_line "WARN" "$1" "$2"; }
ko() { FAIL=$((FAIL + 1)); print_status_line "FAIL" "$1" "$2"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive) ARCHIVE_PATH="$2"; shift 2 ;;
      --verbose) VERBOSE=1; shift ;;
      --help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

check_cmd() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then
    ok "Command" "$c is installed"
  else
    ko "Command" "$c is missing"
  fi
}

main() {
  parse_args "$@"
  init_logging "/home/frankie/migration_logs/preflight-$(timestamp).log"

  print_summary_header "Target Preflight"
  check_cmd docker
  check_cmd tar
  check_cmd bzip2
  check_cmd sha256sum
  check_cmd mariadb

  if command -v docker >/dev/null 2>&1; then
    if docker --version >/dev/null 2>&1; then
      ok "Docker" "Engine responds"
    else
      ko "Docker" "Engine command failed"
    fi

    if docker compose version >/dev/null 2>&1; then
      ok "Compose" "Plugin available"
    else
      ko "Compose" "Docker compose plugin missing"
    fi
  fi

  if dpkg-query -W -f='${Version}' cloudpanel >/dev/null 2>&1; then
    ok "CloudPanel" "Installed: $(dpkg-query -W -f='${Version}' cloudpanel 2>/dev/null)"
  else
    wa "CloudPanel" "Package not detected"
  fi

  if [[ -n "$ARCHIVE_PATH" && -f "$ARCHIVE_PATH" ]]; then
    local expected installed expected_mm installed_mm
    expected="$(tar -xOf "$ARCHIVE_PATH" bundle/metadata/mariadb_version.txt 2>/dev/null | awk -F'=' '/^MARIADB_VERSION=/{print $2}' || true)"
    installed="$(mariadb --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+-MariaDB|[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [[ -n "$expected" && -n "$installed" ]]; then
      expected_mm="$(printf '%s\n' "$expected" | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/')"
      installed_mm="$(printf '%s\n' "$installed" | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/')"
      if [[ "$expected_mm" == "$installed_mm" ]]; then
        ok "MariaDB compatibility" "Archive requires $expected, target has $installed"
      else
        ko "MariaDB compatibility" "Archive requires $expected, target has $installed"
      fi
    else
      wa "MariaDB compatibility" "Could not compare archive vs target version"
    fi
  fi

  print_summary_header "Preflight Summary"
  print_status_line "OK" "Passed" "$PASS"
  if ((WARN > 0)); then print_status_line "WARN" "Warnings" "$WARN"; else print_status_line "OK" "Warnings" "0"; fi
  if ((FAIL > 0)); then print_status_line "FAIL" "Failures" "$FAIL"; else print_status_line "OK" "Failures" "0"; fi

  if ((FAIL > 0)); then
    exit 1
  fi
}

main "$@"
