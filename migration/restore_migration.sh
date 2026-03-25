#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ARCHIVE_PATH=""
TARGET_ROOT="/opt/vps-migration"
SKIP_HOST_RESTORE=0
SKIP_DB_RESTORE=0
START_SERVICES=1
KEEP_STAGING=0

STAGING_DIR=""
BUNDLE_PATH=""

CHECKSUM_OK=0
HOST_RESTORE_DONE=0
DB_RESTORE_METHOD="none"
DOCKER_VOLUME_RESTORE_COUNT=0
SERVICES_START_DONE=0
SUMMARY_ISSUES=()

add_issue() {
  SUMMARY_ISSUES+=("$1")
}

print_restore_summary() {
  print_summary_header "Restore Summary"

  if ((CHECKSUM_OK)); then
    print_status_line "OK" "Archive verification" "Checksum verification passed"
  else
    print_status_line "WARN" "Archive verification" "Checksums not verified or missing"
  fi

  if ((HOST_RESTORE_DONE)); then
    print_status_line "OK" "Host restore" "Host filesystem paths restored"
  else
    print_status_line "WARN" "Host restore" "Skipped or incomplete"
  fi

  case "$DB_RESTORE_METHOD" in
    logical)
      print_status_line "OK" "MariaDB restore" "Logical restore applied"
      ;;
    physical)
      print_status_line "WARN" "MariaDB restore" "Physical snapshot restore applied"
      ;;
    none)
      print_status_line "WARN" "MariaDB restore" "No MariaDB restore performed"
      ;;
    failed)
      print_status_line "FAIL" "MariaDB restore" "Restore failed"
      ;;
  esac

  if ((DOCKER_VOLUME_RESTORE_COUNT > 0)); then
    print_status_line "OK" "Docker volumes" "Restored $DOCKER_VOLUME_RESTORE_COUNT volume(s)"
  else
    print_status_line "WARN" "Docker volumes" "No volume archives restored"
  fi

  if ((SERVICES_START_DONE)); then
    print_status_line "OK" "Service startup" "Docker stacks/services started"
  else
    print_status_line "WARN" "Service startup" "Skipped or incomplete"
  fi

  if [[ ${#SUMMARY_ISSUES[@]} -gt 0 ]]; then
    print_summary_header "Issues"
    local issue
    for issue in "${SUMMARY_ISSUES[@]}"; do
      print_status_line "WARN" "Issue" "$issue"
    done
  fi
}

usage() {
  cat <<'EOF'
Usage: restore_migration.sh --archive <file.tar.bz2> [options]

Options:
  --archive <path>      Migration archive to restore (required)
  --target-root <path>  Persistent restore root (default: /opt/vps-migration)
  --skip-host-restore   Skip restoring host filesystem paths (/etc, /home/clp, etc.)
  --skip-db-restore     Skip host MariaDB/Redis restore
  --no-start            Do not start Docker/Compose services after restore
  --dry-run             Print actions without changing anything
  --verbose             Verbose logs
  --strict              Fail on optional restore warnings
  --keep-staging        Keep temporary extraction directory
  --help                Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive)
        ARCHIVE_PATH="$2"
        shift 2
        ;;
      --target-root)
        TARGET_ROOT="$2"
        shift 2
        ;;
      --skip-host-restore)
        SKIP_HOST_RESTORE=1
        shift
        ;;
      --skip-db-restore)
        SKIP_DB_RESTORE=1
        shift
        ;;
      --no-start)
        START_SERVICES=0
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
      --strict)
        STRICT=1
        shift
        ;;
      --keep-staging)
        KEEP_STAGING=1
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

  [[ -n "$ARCHIVE_PATH" ]] || die "--archive is required"
}

resolve_bundle_from_archive() {
  local nested_backup=""

  run_cmd tar -xjf "$ARCHIVE_PATH" -C "$STAGING_DIR"

  if [[ -d "$STAGING_DIR/bundle" ]]; then
    BUNDLE_PATH="$STAGING_DIR/bundle"
    return 0
  fi

  nested_backup="$(ls -1 "$STAGING_DIR"/migration-*.tar.bz2 2>/dev/null | head -n1 || true)"
  if [[ -n "$nested_backup" ]]; then
    log_info "Detected portable migration kit archive; extracting nested backup $(basename "$nested_backup")"
    run_cmd tar -xjf "$nested_backup" -C "$STAGING_DIR"
    if [[ -d "$STAGING_DIR/bundle" ]]; then
      BUNDLE_PATH="$STAGING_DIR/bundle"
      return 0
    fi
  fi

  die "Invalid archive: missing bundle directory (expected migration backup or migration-kit archive)"
}

container_exists() {
  local name="$1"
  docker container inspect "$name" >/dev/null 2>&1
}

systemd_unit_exists() {
  local unit="$1"
  systemctl cat "$unit" >/dev/null 2>&1
}

check_mariadb_version_match() {
  local version_file="$1"

  if [[ ! -f "$version_file" ]]; then
    log_warn "MariaDB version metadata not found in archive: $version_file"
    if ((STRICT)); then
      die "Strict mode enabled and MariaDB version metadata is missing"
    fi
    return 0
  fi

  local expected
  expected="$(awk -F'=' '/^MARIADB_VERSION=/{print $2}' "$version_file" || true)"
  if [[ -z "$expected" ]]; then
    die "Invalid MariaDB version metadata in $version_file"
  fi

  local raw_installed installed
  if command -v mariadb >/dev/null 2>&1; then
    raw_installed="$(mariadb --version || true)"
  elif command -v mysql >/dev/null 2>&1; then
    raw_installed="$(mysql --version || true)"
  else
    die "MariaDB/MySQL client not found on target host"
  fi

  installed="$(printf '%s\n' "$raw_installed" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+-MariaDB|[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [[ -z "$installed" ]]; then
    die "Could not parse installed MariaDB version from: $raw_installed"
  fi

  if [[ "$installed" != "$expected" ]]; then
    die "MariaDB version mismatch. Expected '$expected' from backup, found '$installed' on target host."
  fi

  log_info "MariaDB version check passed: $installed"
}

restore_docker_volumes() {
  local volumes_dir="$TARGET_ROOT/exports/docker-volumes"

  if [[ ! -d "$volumes_dir" ]]; then
    log_warn "No docker volume exports directory found: $volumes_dir"
    return 0
  fi

  local tar_file
  shopt -s nullglob
  for tar_file in "$volumes_dir"/*.tar; do
    local vol
    vol="$(basename "$tar_file" .tar)"

    log_info "Restoring Docker volume: $vol"
    run_cmd docker volume create "$vol" >/dev/null

    run_cmd docker run --rm \
      -v "${vol}:/to" \
      -v "${volumes_dir}:/from:ro" \
      alpine sh -c "find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; tar -xpf '/from/${vol}.tar' -C /to"
    DOCKER_VOLUME_RESTORE_COUNT=$((DOCKER_VOLUME_RESTORE_COUNT + 1))
  done
  shopt -u nullglob
}

restore_host_filesystem() {
  local host_tar="$TARGET_ROOT/exports/filesystem/host_paths.tar"
  local existing_list="$TARGET_ROOT/metadata/host_paths_existing.txt"
  local backup_dir="/var/backups/vps-migration/restore-$(timestamp)"

  if [[ ! -f "$host_tar" ]]; then
    log_warn "Host filesystem export not found: $host_tar"
    if ((STRICT)); then
      die "Strict mode enabled and host filesystem export missing"
    fi
    return 0
  fi

  run_cmd mkdir -p "$backup_dir"

  if [[ -f "$existing_list" ]]; then
    mapfile -t existing_paths <"$existing_list"
    if [[ ${#existing_paths[@]} -gt 0 ]]; then
      run_cmd tar -cpf "$backup_dir/host-pre-restore.tar" --absolute-names "${existing_paths[@]}"
    fi
  fi

  run_cmd tar -xpf "$host_tar" --absolute-names
  HOST_RESTORE_DONE=1
}

restore_host_databases() {
  local db_dir="$TARGET_ROOT/exports/databases"
  local mariadb_dump="$db_dir/mariadb-all.sql.gz"
  local mariadb_physical="$db_dir/mariadb-physical.tar"
  local redis_dump="$db_dir/redis-dump.rdb"

  restore_mariadb_logical() {
    if command -v mysql >/dev/null 2>&1 && systemctl is-active --quiet mariadb; then
      run_cmd bash -lc "gunzip -c '$mariadb_dump' | mysql"
      DB_RESTORE_METHOD="logical"
      return 0
    fi

    log_warn "Skipping MariaDB logical restore (mysql missing or mariadb inactive)"
    return 1
  }

  restore_mariadb_physical() {
    local was_active=0
    local backup_dir="/var/backups/vps-migration"
    local backup_tar="$backup_dir/mariadb-pre-restore-$(timestamp).tar"

    if ! systemd_unit_exists mariadb.service; then
      log_warn "MariaDB service not found; cannot restore physical snapshot"
      return 1
    fi

    run_cmd mkdir -p "$backup_dir"

    if systemctl is-active --quiet mariadb; then
      was_active=1
      run_cmd systemctl stop mariadb
    fi

    if [[ -d /var/lib/mysql || -d /etc/mysql ]]; then
      run_cmd tar -cpf "$backup_tar" --absolute-names /var/lib/mysql /etc/mysql
    fi

    run_cmd tar -xpf "$mariadb_physical" --absolute-names
    run_cmd chown -R mysql:mysql /var/lib/mysql

    if ((was_active)); then
      run_cmd systemctl start mariadb
    else
      run_cmd systemctl start mariadb
    fi
    DB_RESTORE_METHOD="physical"
    return 0
  }

  if [[ -f "$mariadb_dump" ]]; then
    if ! restore_mariadb_logical; then
      if [[ -f "$mariadb_physical" ]]; then
        log_warn "Logical MariaDB restore unavailable. Trying physical snapshot restore."
        if ! restore_mariadb_physical; then
          DB_RESTORE_METHOD="failed"
          add_issue "MariaDB physical restore failed after logical restore failure"
          if ((STRICT)); then
            die "Strict mode enabled and MariaDB physical restore failed"
          fi
        fi
      elif ((STRICT)); then
        die "Strict mode enabled and MariaDB restore failed preconditions"
      fi
    fi
  elif [[ -f "$mariadb_physical" ]]; then
    if ! restore_mariadb_physical; then
      DB_RESTORE_METHOD="failed"
      add_issue "MariaDB physical restore failed"
      if ((STRICT)); then
        die "Strict mode enabled and MariaDB physical restore failed"
      fi
    fi
  else
    log_warn "No MariaDB backup payload found (logical or physical)"
    add_issue "No MariaDB backup payload found"
    if ((STRICT)); then
      die "Strict mode enabled and MariaDB backup payload is missing"
    fi
  fi

  if [[ -f "$redis_dump" ]]; then
    if systemd_unit_exists redis-server.service; then
      run_cmd systemctl stop redis-server
      run_cmd mkdir -p /var/lib/redis

      if [[ -f /var/lib/redis/dump.rdb ]]; then
        run_cmd cp -a /var/lib/redis/dump.rdb "/var/backups/vps-migration/redis-dump-before-$(timestamp).rdb"
      fi

      run_cmd cp -f "$redis_dump" /var/lib/redis/dump.rdb
      run_cmd chown redis:redis /var/lib/redis/dump.rdb
      run_cmd chmod 660 /var/lib/redis/dump.rdb
      run_cmd systemctl start redis-server
    else
      log_warn "Skipping Redis host restore (redis-server service not found)"
    fi
  fi
}

start_services() {
  local runtime_dir="$TARGET_ROOT/exports/runtime"

  if [[ -f /home/frankie/docker-compose.yaml ]]; then
    log_info "Starting Chatwoot compose stack"
    run_cmd docker compose -f /home/frankie/docker-compose.yaml up -d
  else
    log_warn "Chatwoot compose file missing at /home/frankie/docker-compose.yaml"
  fi

  if [[ -f "$runtime_dir/n8n.compose.yaml" ]]; then
    log_info "Deploying n8n"
    if container_exists n8n; then
      run_cmd docker rm -f n8n
    fi
    run_cmd docker compose -f "$runtime_dir/n8n.compose.yaml" up -d
  fi

  if [[ -f "$runtime_dir/kestra.compose.yaml" ]]; then
    log_info "Deploying Kestra"
    if container_exists kestra; then
      run_cmd docker rm -f kestra
    fi
    run_cmd docker compose -f "$runtime_dir/kestra.compose.yaml" up -d
  fi
}

on_exit() {
  local exit_code="$1"

  if [[ "$exit_code" -ne 0 ]]; then
    log_error "restore_migration.sh failed with exit code $exit_code"
  fi

  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" && "$KEEP_STAGING" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    rm -rf "$STAGING_DIR"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    log_info "Restore completed successfully"
    log_info "Persistent payload root: $TARGET_ROOT"
  else
    add_issue "Script exited with code $exit_code"
  fi

  print_restore_summary
}

main() {
  parse_args "$@"

  init_logging "/home/frankie/migration_logs/restore-$(timestamp).log"
  trap 'on_exit $?' EXIT

  ensure_root
  require_cmds tar bzip2 sha256sum docker systemctl cp

  [[ -f "$ARCHIVE_PATH" ]] || die "Archive not found: $ARCHIVE_PATH"

  STAGING_DIR="$(mktemp -d /tmp/vps-restore-XXXXXX)"

  run_cmd mkdir -p "$TARGET_ROOT"
  resolve_bundle_from_archive

  local bundle_path="$BUNDLE_PATH"

  check_mariadb_version_match "$bundle_path/metadata/mariadb_version.txt"

  if [[ -f "$bundle_path/SHA256SUMS" ]]; then
    run_cmd bash -lc "cd '$bundle_path' && sha256sum -c SHA256SUMS"
    CHECKSUM_OK=1
  else
    log_warn "Checksum file missing in bundle"
    add_issue "Checksum file missing in bundle"
    if ((STRICT)); then
      die "Strict mode enabled and checksums are missing"
    fi
  fi

  run_cmd cp -a "$bundle_path/." "$TARGET_ROOT/"

  if ((SKIP_HOST_RESTORE == 0)); then
    restore_host_filesystem
  fi

  restore_docker_volumes

  if ((SKIP_DB_RESTORE == 0)); then
    restore_host_databases
  fi

  if ((START_SERVICES)); then
    start_services
    SERVICES_START_DONE=1
  fi

  run_capture "$TARGET_ROOT/metadata/post-restore-docker-ps.txt" docker ps -a
  run_capture "$TARGET_ROOT/metadata/post-restore-services.txt" bash -lc "systemctl list-units --type=service --all --no-pager | egrep -i 'nginx|cloudpanel|clp|docker|mariadb|redis|n8n|kestra|chatwoot' || true"
}

main "$@"
