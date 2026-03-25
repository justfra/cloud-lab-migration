#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

STRICT_MODE=0
ARCHIVE_PATH=""
KEEP_STAGING=0
STAGING_DIR=""

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ARCHIVE_STATUS="missing"

usage() {
  cat <<'EOF'
Usage: validate_migration.sh [options]

Options:
  --archive <path>   Archive to validate (default: latest /home/frankie/migration-*.tar.bz2)
  --strict           Treat warnings as failures
  --keep-staging     Keep extracted temporary bundle
  --dry-run          Print checks without executing
  --verbose          Verbose logs
  --help             Show this help
EOF
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log_info "PASS: $*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  log_warn "WARN: $*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log_error "FAIL: $*"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive)
        ARCHIVE_PATH="$2"
        shift 2
        ;;
      --strict)
        STRICT_MODE=1
        shift
        ;;
      --keep-staging)
        KEEP_STAGING=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

pick_latest_archive_if_missing() {
  if [[ -n "$ARCHIVE_PATH" ]]; then
    return 0
  fi

  local latest
  latest="$(ls -1t /home/frankie/migration-*.tar.bz2 2>/dev/null | head -n1 || true)"
  if [[ -z "$latest" ]]; then
    die "No archive provided and none found at /home/frankie/migration-*.tar.bz2"
  fi
  ARCHIVE_PATH="$latest"
}

check_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    pass "$label present"
  else
    fail "$label missing ($path)"
  fi
}

check_archive_integrity() {
  if ((DRY_RUN)); then
    pass "Archive integrity check planned"
    return 0
  fi

  if tar -tjf "$ARCHIVE_PATH" >/dev/null; then
    pass "Archive can be listed"
    ARCHIVE_STATUS="readable"
  else
    fail "Archive cannot be read/listed"
    ARCHIVE_STATUS="unreadable"
  fi
}

verify_sidecar_checksum() {
  local sidecar="${ARCHIVE_PATH}.sha256"

  if [[ ! -f "$sidecar" ]]; then
    warn "Sidecar checksum missing (${sidecar})"
    return 0
  fi

  if ((DRY_RUN)); then
    pass "Sidecar checksum verification planned"
    return 0
  fi

  if sha256sum -c "$sidecar" >/dev/null 2>&1; then
    pass "Sidecar checksum matches"
  else
    fail "Sidecar checksum mismatch"
  fi
}

extract_bundle() {
  STAGING_DIR="$(mktemp -d /tmp/vps-validate-XXXXXX)"

  if ((DRY_RUN)); then
    pass "Bundle extraction planned"
    return 0
  fi

  if tar -xjf "$ARCHIVE_PATH" -C "$STAGING_DIR" bundle; then
    pass "Bundle extracted"
  else
    fail "Failed to extract bundle"
    return 1
  fi
  return 0
}

verify_internal_bundle_checksums() {
  local bundle_dir="$STAGING_DIR/bundle"
  local sums="$bundle_dir/SHA256SUMS"

  if ((DRY_RUN)); then
    pass "Internal checksum verification planned"
    return 0
  fi

  if [[ ! -f "$sums" ]]; then
    fail "Internal checksum file missing (bundle/SHA256SUMS)"
    return 0
  fi

  if (cd "$bundle_dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
    pass "Internal bundle checksums verified"
  else
    fail "Internal bundle checksums failed"
  fi
}

validate_required_payload() {
  local bundle_dir="$STAGING_DIR/bundle"
  local host_tar="$bundle_dir/exports/filesystem/host_paths.tar"
  local host_listing="$STAGING_DIR/host_paths_listing.txt"
  local host_existing="$bundle_dir/metadata/host_paths_existing.txt"
  local db_method_file="$bundle_dir/metadata/db_backup_method.txt"
  local method=""

  if ((DRY_RUN)); then
    pass "Required payload checks planned"
    return 0
  fi

  check_file_exists "$bundle_dir/metadata/manifest.txt" "Manifest"
  check_file_exists "$bundle_dir/metadata/mariadb_version.txt" "MariaDB version metadata"
  check_file_exists "$db_method_file" "DB backup method metadata"
  check_file_exists "$host_tar" "Host paths tar"

  if ! tar -tf "$host_tar" >"$host_listing"; then
    fail "Unable to list host paths tar contents"
    return 0
  fi

  if [[ -f "$db_method_file" ]]; then
    method="$(awk -F'=' '/^mariadb_method=/{print $2}' "$db_method_file" | tail -n1 || true)"
    if [[ -z "$method" ]]; then
      fail "Unable to parse mariadb_method in db_backup_method.txt"
    else
      pass "MariaDB backup method recorded: $method"
    fi
  fi

  case "$method" in
    logical_socket|logical_cloudpanel_decrypted)
      check_file_exists "$bundle_dir/exports/databases/mariadb-all.sql.gz" "MariaDB logical dump"
      ;;
    physical_snapshot)
      check_file_exists "$bundle_dir/exports/databases/mariadb-physical.tar" "MariaDB physical snapshot"
      ;;
    none|"")
      fail "MariaDB backup method is '$method'"
      ;;
    *)
      warn "Unknown MariaDB backup method: $method"
      ;;
  esac

  if [[ -f "$bundle_dir/exports/databases/redis-dump.rdb" ]]; then
    pass "Redis dump present"
  else
    warn "Redis dump missing"
  fi

  local volume_count
  volume_count="$(ls -1 "$bundle_dir/exports/docker-volumes"/*.tar 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$volume_count" -gt 0 ]]; then
    pass "Docker volume archives present ($volume_count)"
  else
    warn "No Docker volume archives found"
  fi

  if [[ -f "$host_existing" ]] && grep -Fxq '/home/frankie/.opencode' "$host_existing"; then
    if grep -Eq '(^|/)home/frankie/\.opencode(/|$)' "$host_listing"; then
      pass ".opencode captured in host paths tar"
    else
      fail ".opencode expected but not found in host paths tar"
    fi
  else
    warn ".opencode was not present on source host at pack time"
  fi

  if [[ -f "$host_existing" ]] && grep -Fxq '/home/frankie/.claude' "$host_existing"; then
    if grep -Eq '(^|/)home/frankie/\.claude(/|$)' "$host_listing"; then
      pass ".claude captured in host paths tar"
    else
      fail ".claude expected but not found in host paths tar"
    fi
  else
    warn ".claude was not present on source host at pack time"
  fi

  if [[ -f "$host_existing" ]] && grep -Fxq '/home/frankie/.claude.json' "$host_existing"; then
    if grep -Eq '(^|/)home/frankie/\.claude\.json$' "$host_listing"; then
      pass ".claude.json captured in host paths tar"
    else
      fail ".claude.json expected but not found in host paths tar"
    fi
  else
    warn ".claude.json was not present on source host at pack time"
  fi

  if [[ -f "$host_existing" ]] && grep -Fxq '/home/frankie/.config/opencode' "$host_existing"; then
    if grep -Eq '(^|/)home/frankie/\.config/opencode(/|$)' "$host_listing"; then
      pass ".config/opencode captured in host paths tar"
    else
      fail ".config/opencode expected but not found in host paths tar"
    fi
  else
    warn ".config/opencode was not present on source host at pack time"
  fi

  if [[ -f "$host_existing" ]] && grep -Fxq '/home/frankie/.ssh' "$host_existing"; then
    if grep -Eq '(^|/)home/frankie/\.ssh(/|$)' "$host_listing"; then
      pass ".ssh captured in host paths tar"
    else
      fail ".ssh expected but not found in host paths tar"
    fi
  else
    warn ".ssh was not present on source host at pack time"
  fi

  if [[ -f "$host_existing" ]] && grep -Fxq '/home/frankie/.local/share/opencode' "$host_existing"; then
    if grep -Eq '(^|/)home/frankie/\.local/share/opencode(/|$)' "$host_listing"; then
      pass ".local/share/opencode captured in host paths tar"
    else
      fail ".local/share/opencode expected but not found in host paths tar"
    fi
  else
    warn ".local/share/opencode was not present on source host at pack time"
  fi

  if grep -Eq '(^|/)home/frankie/migration(/|$)' "$host_listing"; then
    pass "migration toolkit captured in host paths tar"
  else
    warn "migration toolkit not found in host paths tar"
  fi

  if grep -Eq '(^|/)home/frankie/[^/]+\.sh$' "$host_listing"; then
    pass "Top-level /home/frankie .sh scripts captured"
  else
    warn "No top-level /home/frankie .sh scripts found in host paths tar"
  fi
}

print_validation_summary() {
  print_summary_header "Backup Validation Summary"
  case "$ARCHIVE_STATUS" in
    readable)
      print_status_line "OK" "Archive" "$ARCHIVE_PATH"
      ;;
    unreadable)
      print_status_line "FAIL" "Archive" "$ARCHIVE_PATH"
      ;;
    missing)
      print_status_line "FAIL" "Archive" "$ARCHIVE_PATH"
      ;;
    *)
      print_status_line "WARN" "Archive" "$ARCHIVE_PATH"
      ;;
  esac
  print_status_line "OK" "Passed checks" "$PASS_COUNT"

  if ((WARN_COUNT > 0)); then
    print_status_line "WARN" "Warnings" "$WARN_COUNT"
  else
    print_status_line "OK" "Warnings" "0"
  fi

  if ((FAIL_COUNT > 0)); then
    print_status_line "FAIL" "Failures" "$FAIL_COUNT"
  else
    print_status_line "OK" "Failures" "0"
  fi
}

on_exit() {
  local exit_code="$1"

  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" && "$KEEP_STAGING" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    rm -rf "$STAGING_DIR"
  fi

  print_validation_summary

  if [[ "$exit_code" -ne 0 ]]; then
    log_error "Backup validation exited with code $exit_code"
  fi
}

main() {
  parse_args "$@"
  pick_latest_archive_if_missing

  init_logging "/home/frankie/migration_logs/validate-$(timestamp).log"
  trap 'on_exit $?' EXIT

  check_file_exists "$ARCHIVE_PATH" "Archive"

  if [[ ! -f "$ARCHIVE_PATH" ]]; then
    ARCHIVE_STATUS="missing"
    exit 1
  fi

  check_archive_integrity

  if [[ "$ARCHIVE_STATUS" != "readable" ]]; then
    exit 1
  fi

  verify_sidecar_checksum
  if ! extract_bundle; then
    exit 1
  fi

  if ((DRY_RUN == 0)); then
    verify_internal_bundle_checksums
    validate_required_payload
  fi

  if ((FAIL_COUNT > 0)); then
    exit 1
  fi

  if ((STRICT_MODE == 1 && WARN_COUNT > 0)); then
    log_error "Strict mode enabled and warnings were found"
    exit 2
  fi

  exit 0
}

main "$@"
