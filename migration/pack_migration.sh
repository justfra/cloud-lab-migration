#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUTPUT_DIR="$PWD"
LABEL=""
KEEP_WORKDIR=0
CREATE_PORTABLE_KIT=0

CHATWOOT_COMPOSE="/home/frankie/docker-compose.yaml"
SHARED_SERVICES_COMPOSE="/home/frankie/shared-services/docker-compose.yaml"

WORK_DIR=""
BUNDLE_DIR=""
ARCHIVE_PATH=""

CHATWOOT_WAS_RUNNING=0
SHARED_SERVICES_WAS_RUNNING=0
N8N_WAS_RUNNING=0
KESTRA_WAS_RUNNING=0
RESUMED=0

ARCHIVE_CREATED=0
PORTABLE_KIT_CREATED=0
HOST_EXPORT_DONE=0
REDIS_DUMP_DONE=0
VOLUME_EXPORT_COUNT=0
MARIADB_BACKUP_METHOD="none"
MARIADB_PHYSICAL_DATADIR=""
SOURCE_MARIADB_VERSION="unknown"
SOURCE_CLOUDPANEL_VERSION="unknown"
VALIDATION_RESULT="not_run"
PORTABLE_KIT_PATH=""
SUMMARY_ISSUES=()

add_issue() {
  SUMMARY_ISSUES+=("$1")
}

print_pack_summary() {
  print_summary_header "Pack Summary"

  if ((ARCHIVE_CREATED)); then
    print_status_line "OK" "Archive" "$ARCHIVE_PATH"
  else
    print_status_line "FAIL" "Archive" "Archive was not created"
  fi

  if ((PORTABLE_KIT_CREATED)); then
    print_status_line "OK" "Portable kit" "$PORTABLE_KIT_PATH"
  else
    if ((CREATE_PORTABLE_KIT)); then
      print_status_line "WARN" "Portable kit" "Self-contained restore kit was not created"
    else
      print_status_line "OK" "Portable kit" "Skipped (repo-managed workflow)"
    fi
  fi

  if ((HOST_EXPORT_DONE)); then
    print_status_line "OK" "Host config export" "Captured host filesystem bundle"
  else
    print_status_line "WARN" "Host config export" "Host filesystem export incomplete or skipped"
  fi

  case "$MARIADB_BACKUP_METHOD" in
    logical_socket)
      print_status_line "OK" "MariaDB backup" "Logical dump via local auth"
      ;;
    logical_cloudpanel_decrypted)
      print_status_line "OK" "MariaDB backup" "Logical dump via CloudPanel decrypted credentials"
      ;;
    physical_snapshot)
      if [[ -n "$MARIADB_PHYSICAL_DATADIR" ]]; then
        print_status_line "WARN" "MariaDB backup" "Used physical snapshot fallback ($MARIADB_PHYSICAL_DATADIR + /etc/mysql)"
      else
        print_status_line "WARN" "MariaDB backup" "Used physical snapshot fallback (custom datadir + /etc/mysql)"
      fi
      ;;
    none)
      print_status_line "FAIL" "MariaDB backup" "No MariaDB backup was produced"
      ;;
    *)
      print_status_line "WARN" "MariaDB backup" "Method unknown: $MARIADB_BACKUP_METHOD"
      ;;
  esac

  if ((REDIS_DUMP_DONE)); then
    print_status_line "OK" "Redis backup" "Host Redis dump captured"
  else
    print_status_line "WARN" "Redis backup" "Redis dump missing or skipped"
  fi

  if ((VOLUME_EXPORT_COUNT > 0)); then
    print_status_line "OK" "Docker volume export" "Exported $VOLUME_EXPORT_COUNT volume archive(s)"
  else
    print_status_line "WARN" "Docker volume export" "No Docker volumes exported"
  fi

  case "$VALIDATION_RESULT" in
    success)
      print_status_line "OK" "Validation" "Post-pack validation passed"
      ;;
    failed)
      print_status_line "WARN" "Validation" "Validation failed; archive remains usable"
      ;;
    skipped)
      print_status_line "WARN" "Validation" "Validation skipped"
      ;;
    not_run)
      print_status_line "WARN" "Validation" "Validation not run"
      ;;
  esac

  if [[ ${#SUMMARY_ISSUES[@]} -gt 0 ]]; then
    print_summary_header "Issues"
    local issue
    for issue in "${SUMMARY_ISSUES[@]}"; do
      print_status_line "WARN" "Issue" "$issue"
    done
  fi
}

print_restore_prereqs() {
  print_summary_header "Target Host Prerequisites"
  print_status_line "OK" "Install base packages" "sudo apt update && sudo apt -y upgrade && sudo apt -y install curl wget sudo bzip2"
  print_status_line "OK" "Install CloudPanel" "https://www.cloudpanel.io/docs/v2/getting-started/other/"
  print_status_line "OK" "Install Docker Engine" "https://docs.docker.com/engine/install/"
  print_status_line "OK" "Compose plugin note" "Docker Compose plugin is usually installed together with Docker Engine"
  print_status_line "OK" "Source CloudPanel" "${SOURCE_CLOUDPANEL_VERSION}"
  print_status_line "OK" "Source MariaDB" "${SOURCE_MARIADB_VERSION}"
  print_status_line "OK" "After install" "Run restore using scripts from this git repo or from optional migration kit; no manual CloudPanel account setup is required for migrated data"
}

create_portable_kit() {
  local label_part="$1"
  local pack_ts="$2"
  local kit_root="$WORK_DIR/portable-kit"

  PORTABLE_KIT_PATH="$OUTPUT_DIR/migration-kit-${label_part}-${pack_ts}.tar.bz2"

  mkdir -p "$kit_root"
  cp -a "$SCRIPT_DIR" "$kit_root/migration"
  cp -a "$ARCHIVE_PATH" "$kit_root/"
  cp -a "${ARCHIVE_PATH}.sha256" "$kit_root/"

  cat >"$kit_root/run_restore.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="$(ls -1t "$ROOT_DIR"/migration-*.tar.bz2 2>/dev/null | head -n1 || true)"

if [[ -z "$ARCHIVE" ]]; then
  echo "No migration archive found in $ROOT_DIR"
  exit 1
fi

exec "$ROOT_DIR/migration/restore_migration.sh" --archive "$ARCHIVE" "$@"
EOF

  cat >"$kit_root/run_validate.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="$(ls -1t "$ROOT_DIR"/migration-*.tar.bz2 2>/dev/null | head -n1 || true)"

if [[ -z "$ARCHIVE" ]]; then
  echo "No migration archive found in $ROOT_DIR"
  exit 1
fi

exec "$ROOT_DIR/migration/validate_migration.sh" --archive "$ARCHIVE" "$@"
EOF

  chmod 755 "$kit_root/run_restore.sh" "$kit_root/run_validate.sh"

  run_cmd tar -cjf "$PORTABLE_KIT_PATH" -C "$kit_root" .
  run_cmd bash -lc "sha256sum '$PORTABLE_KIT_PATH' > '${PORTABLE_KIT_PATH}.sha256'"

  PORTABLE_KIT_CREATED=1
}

maybe_run_validation() {
  local validator="$SCRIPT_DIR/validate_migration.sh"
  local answer

  if ((DRY_RUN)); then
    return 0
  fi

  if [[ ! -x "$validator" ]]; then
    log_warn "Validation script not found or not executable: $validator"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    log_info "Non-interactive shell detected. Skipping validation prompt."
    log_info "Run manually: sudo $validator --archive '$ARCHIVE_PATH' --verbose"
    return 0
  fi

  read -r -p "Run validation now? [Y/n]: " answer
  answer="${answer:-Y}"

  case "${answer}" in
    y|Y|yes|YES)
      log_info "Running validation script"
      if ! run_cmd "$validator" --archive "$ARCHIVE_PATH" --verbose; then
        log_warn "Validation reported failures. Archive creation already completed successfully."
        VALIDATION_RESULT="failed"
        add_issue "Post-pack validation failed"
      else
        VALIDATION_RESULT="success"
      fi
      ;;
    *)
      log_info "Validation skipped by user"
      VALIDATION_RESULT="skipped"
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: pack_migration.sh [options]

Options:
  --output-dir <path>   Directory where archive will be written (default: current dir)
  --label <name>        Label used in archive filename
  --create-kit          Also create self-contained migration-kit archive
  --dry-run             Print actions without changing anything
  --verbose             Verbose logs
  --strict              Fail on optional export warnings
  --keep-workdir        Do not delete temporary working directory
  --help                Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --label)
        LABEL="$2"
        shift 2
        ;;
      --create-kit)
        CREATE_PORTABLE_KIT=1
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
      --keep-workdir)
        KEEP_WORKDIR=1
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

is_container_running() {
  local name="$1"
  docker ps --filter "name=^/${name}$" --filter status=running --quiet | grep -q .
}

container_exists() {
  local name="$1"
  docker container inspect "$name" >/dev/null 2>&1
}

volume_exists() {
  local name="$1"
  docker volume inspect "$name" >/dev/null 2>&1
}

systemd_unit_exists() {
  local unit="$1"
  systemctl cat "$unit" >/dev/null 2>&1
}

detect_mariadb_datadir() {
  local datadir=""
  local candidate

  for candidate in /etc/mysql/mariadb.conf.d/*.cnf /etc/mysql/conf.d/*.cnf /etc/mysql/my.cnf /etc/mysql/mariadb.cnf; do
    [[ -f "$candidate" ]] || continue
    datadir="$(awk -F'=' '
      /^[[:space:]]*datadir[[:space:]]*=/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        gsub(/["\047]/, "", $2)
        print $2
      }
    ' "$candidate" | tail -n1)"
    if [[ -n "$datadir" ]]; then
      printf '%s\n' "$datadir"
      return 0
    fi
  done

  printf '/var/lib/mysql\n'
  return 0
}

resume_n8n_if_needed() {
  local runtime_compose="$BUNDLE_DIR/exports/runtime/n8n.compose.yaml"

  if ! ((N8N_WAS_RUNNING)); then
    return 0
  fi

  if container_exists n8n; then
    run_cmd docker start n8n || true
    return 0
  fi

  if [[ -f "$runtime_compose" ]]; then
    log_warn "n8n container was removed (likely --rm). Recreating from captured runtime compose."
    run_cmd docker compose -f "$runtime_compose" up -d || true
    return 0
  fi

  log_warn "n8n was running but cannot be resumed: missing container and runtime compose."
}

resume_services() {
  if ((RESUMED)); then
    return 0
  fi

  log_info "Resuming services that were previously running"

  if ((SHARED_SERVICES_WAS_RUNNING)) && [[ -f "$SHARED_SERVICES_COMPOSE" ]]; then
    run_cmd docker compose -f "$SHARED_SERVICES_COMPOSE" up -d --quiet-pull || true
  fi

  if ((CHATWOOT_WAS_RUNNING)) && [[ -f "$CHATWOOT_COMPOSE" ]]; then
    run_cmd docker compose -f "$CHATWOOT_COMPOSE" up -d --quiet-pull || true
  fi

  resume_n8n_if_needed

  if ((KESTRA_WAS_RUNNING)) && container_exists kestra; then
    run_cmd docker start kestra || true
  fi

  RESUMED=1
}

on_exit() {
  local exit_code="$1"

  if [[ "$exit_code" -ne 0 ]]; then
    log_error "pack_migration.sh failed with exit code $exit_code"
  fi

  resume_services

  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && "$KEEP_WORKDIR" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    rm -rf "$WORK_DIR"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    log_info "Pack completed successfully"
    log_info "Archive: $ARCHIVE_PATH"
    log_info "SHA256:  ${ARCHIVE_PATH}.sha256"
  else
    add_issue "Script exited with code $exit_code"
  fi

  print_pack_summary

  if [[ "$exit_code" -eq 0 ]]; then
    print_restore_prereqs
  fi
}

export_volume() {
  local volume_name="$1"
  local out_dir="$BUNDLE_DIR/exports/docker-volumes"

  if ! volume_exists "$volume_name"; then
    log_warn "Volume not found (skipping): $volume_name"
    if ((STRICT)); then
      die "Strict mode enabled and volume missing: $volume_name"
    fi
    return 0
  fi

  mkdir -p "$out_dir"
  run_cmd docker run --rm \
    -v "${volume_name}:/source:ro" \
    -v "${out_dir}:/backup" \
    alpine sh -c "cd /source && tar -cpf /backup/${volume_name}.tar ."
  VOLUME_EXPORT_COUNT=$((VOLUME_EXPORT_COUNT + 1))
}

export_kestra_app_data() {
  if ! container_exists kestra; then
    log_warn "Kestra container not found, skipping /app/data export"
    if ((STRICT)); then
      die "Strict mode enabled and kestra container missing"
    fi
    return 0
  fi

  local tmp_kestra_dir="$WORK_DIR/kestra-app-data"
  mkdir -p "$tmp_kestra_dir"

  run_cmd docker cp "kestra:/app/data" "$tmp_kestra_dir/app_data"
  run_cmd tar -cpf "$BUNDLE_DIR/exports/docker-volumes/kestra_app_data.tar" -C "$tmp_kestra_dir/app_data" .
}

capture_host_filesystem() {
  local host_tar="$BUNDLE_DIR/exports/filesystem/host_paths.tar"
  local req_list="$BUNDLE_DIR/metadata/host_paths_requested.txt"
  local existing_list="$BUNDLE_DIR/metadata/host_paths_existing.txt"

  mkdir -p "$(dirname "$host_tar")" "$BUNDLE_DIR/metadata"

  local host_paths=(
    "/etc/nginx"
    "/etc/systemd/system"
    "/usr/lib/systemd/system/clp-agent.service"
    "/usr/lib/systemd/system/clp-nginx.service"
    "/usr/lib/systemd/system/nginx.service"
    "/home/clp"
    "/home/frankie/.claude"
    "/home/frankie/.claude.json"
    "/home/frankie/.config/opencode"
    "/home/frankie/.opencode"
    "/home/frankie/.local/share/opencode"
    "/home/frankie/.ssh"
    "/home/frankie/cloud-lab-migration"
    "/home/frankie/migration"
    "/home/frankie/docker-compose.yaml"
    "/home/frankie/.env"
    "/home/frankie/n8n-config.json"
    "/home/frankie/shared-services"
  )

  local script_path
  for script_path in /home/frankie/*.sh; do
    [[ -e "$script_path" ]] || continue
    host_paths+=("$script_path")
  done

  : >"$req_list"
  : >"$existing_list"

  local existing=()
  local p
  for p in "${host_paths[@]}"; do
    printf '%s\n' "$p" >>"$req_list"
    if [[ -e "$p" ]]; then
      existing+=("$p")
      printf '%s\n' "$p" >>"$existing_list"
    else
      log_warn "Path missing (skipping): $p"
    fi
  done

  if [[ ${#existing[@]} -eq 0 ]]; then
    log_warn "No host filesystem paths available for export"
    if ((STRICT)); then
      die "Strict mode enabled and no host filesystem path could be exported"
    fi
    return 0
  fi

  run_cmd tar -cpf "$host_tar" --absolute-names "${existing[@]}"
  HOST_EXPORT_DONE=1
}

capture_metadata() {
  local md="$BUNDLE_DIR/metadata"
  mkdir -p "$md"

  run_capture "$md/uname.txt" uname -a
  run_capture "$md/os-release.txt" bash -lc "cat /etc/os-release"
  run_capture "$md/date-utc.txt" date -u
  run_capture "$md/docker-version.txt" docker --version
  run_capture "$md/docker-compose-version.txt" docker compose version
  run_capture "$md/docker-ps-a.txt" docker ps -a
  run_capture "$md/docker-volume-ls.txt" docker volume ls
  run_capture "$md/docker-network-ls.txt" docker network ls
  run_capture "$md/docker-system-df-v.txt" docker system df -v
  run_capture "$md/systemctl-relevant.txt" bash -lc "systemctl list-units --type=service --all --no-pager | egrep -i 'nginx|cloudpanel|clp|docker|mariadb|redis|n8n|kestra|chatwoot' || true"
  run_capture "$md/ss-tulpn.txt" ss -tulpn

  if container_exists n8n; then
    run_capture "$md/n8n.inspect.json" docker inspect n8n
    run_capture "$md/n8n.env" docker inspect n8n --format "{{range .Config.Env}}{{println .}}{{end}}"
  fi

  if container_exists kestra; then
    run_capture "$md/kestra.inspect.json" docker inspect kestra
    run_capture "$md/kestra.env" docker inspect kestra --format "{{range .Config.Env}}{{println .}}{{end}}"
  fi
}

cloudpanel_decrypt_db_password() {
  local encrypted_password="$1"
  local app_secret="$2"
  local autoload_file="$3"

  php -r '
require $argv[3];
use Defuse\Crypto\Crypto;
try {
  echo Crypto::decryptWithPassword($argv[1], $argv[2]);
} catch (Throwable $e) {
  fwrite(STDERR, $e->getMessage());
  exit(1);
}
' "$encrypted_password" "$app_secret" "$autoload_file"
}

build_cloudpanel_mariadb_defaults_file() {
  local defaults_file="$1"
  local cp_root="/home/clp/htdocs/app"
  local sqlite_db="$cp_root/data/db.sq3"
  local app_env="$cp_root/files/.env"
  local autoload_file=""

  if [[ -f "$cp_root/vendor/autoload.php" ]]; then
    autoload_file="$cp_root/vendor/autoload.php"
  elif [[ -f "$cp_root/files/vendor/autoload.php" ]]; then
    autoload_file="$cp_root/files/vendor/autoload.php"
  fi

  if [[ ! -f "$sqlite_db" || ! -f "$app_env" || -z "$autoload_file" ]]; then
    log_warn "CloudPanel credential sources not fully available (expected $sqlite_db, $app_env, and vendor/autoload.php in app or app/files)"
    return 1
  fi

  if ! command -v sqlite3 >/dev/null 2>&1 || ! command -v php >/dev/null 2>&1; then
    log_warn "sqlite3 or php missing; cannot decrypt CloudPanel DB credentials"
    return 1
  fi

  local row host port user encrypted app_secret decrypted
  row="$(sqlite3 "$sqlite_db" "SELECT host,port,[user],password FROM database_server ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)"
  if [[ -z "$row" ]]; then
    row="$(sqlite3 "$sqlite_db" "SELECT host,port,username,password FROM database_server ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)"
  fi
  if [[ -n "$row" ]]; then
    IFS='|' read -r host port user encrypted <<<"$row"
    if [[ -z "$user" || "$user" == "user" ]]; then
      row="$(sqlite3 "$sqlite_db" "SELECT host,port,username,password FROM database_server ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$row" ]]; then
    local raw_row
    raw_row="$(sqlite3 "$sqlite_db" "SELECT * FROM database_server ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$raw_row" ]]; then
      host="$(printf '%s' "$raw_row" | awk -F'|' '{print $8}')"
      user="$(printf '%s' "$raw_row" | awk -F'|' '{print $9}')"
      encrypted="$(printf '%s' "$raw_row" | awk -F'|' '{print $10}')"
      port="$(printf '%s' "$raw_row" | awk -F'|' '{print $11}')"
      row="$host|$port|$user|$encrypted"
    fi
  fi
  if [[ -z "$row" ]]; then
    log_warn "No database_server entry found in CloudPanel SQLite"
    add_issue "CloudPanel SQLite query returned no usable database_server row"
    return 1
  fi

  IFS='|' read -r host port user encrypted <<<"$row"
  app_secret="$(grep -E '^APP_SECRET=' "$app_env" | head -n1 | cut -d'=' -f2- || true)"

  if [[ -z "$host" || -z "$port" || -z "$user" || -z "$encrypted" || -z "$app_secret" ]]; then
    log_warn "Incomplete CloudPanel DB credential material; cannot build defaults file"
    return 1
  fi

  if ! decrypted="$(cloudpanel_decrypt_db_password "$encrypted" "$app_secret" "$autoload_file" 2>/dev/null)"; then
    log_warn "Failed to decrypt CloudPanel DB password"
    return 1
  fi

  cat >"$defaults_file" <<EOF
[client]
host=$host
port=$port
user=$user
password=$decrypted
protocol=tcp
EOF
  chmod 600 "$defaults_file"
  return 0
}

capture_mariadb_physical_snapshot() {
  local db_dir="$1"
  local physical_tar="$db_dir/mariadb-physical.tar"
  local was_active=0
  local datadir

  if ! systemd_unit_exists mariadb.service; then
    log_warn "MariaDB service not found; cannot create physical snapshot"
    add_issue "mariadb.service unit not found for physical snapshot"
    return 1
  fi

  datadir="$(detect_mariadb_datadir)"
  if [[ -z "$datadir" ]]; then
    datadir="/var/lib/mysql"
  fi
  MARIADB_PHYSICAL_DATADIR="$datadir"
  log_info "Using MariaDB datadir for physical snapshot: $datadir"

  if systemctl is-active --quiet mariadb; then
    was_active=1
    log_info "Stopping mariadb service for physical snapshot consistency"
    run_cmd systemctl stop mariadb
  fi

  if [[ ! -d "$datadir" ]]; then
    log_warn "MariaDB datadir not found at $datadir"
    add_issue "MariaDB datadir missing at $datadir"
    if ((was_active)); then
      log_info "Restarting mariadb service after physical snapshot failure"
      run_cmd systemctl start mariadb
    fi
    return 1
  fi

  run_cmd tar -cpf "$physical_tar" --absolute-names "$datadir" /etc/mysql

  if ((was_active)); then
    log_info "Restarting mariadb service after physical snapshot"
    run_cmd systemctl start mariadb
  fi

  return 0
}

capture_database_dumps() {
  local db_dir="$BUNDLE_DIR/exports/databases"
  local db_md="$BUNDLE_DIR/metadata/db_backup_method.txt"
  local cp_defaults="$WORK_DIR/cloudpanel-mariadb.defaults.cnf"
  local logical_dump_ok=0
  mkdir -p "$db_dir"
  : >"$db_md"

  if optional_cmd_warn mariadb-dump && systemctl is-active --quiet mariadb; then
    if run_cmd bash -lc "set -o pipefail; mariadb-dump --all-databases --single-transaction --routines --events --triggers | gzip -1 > '$db_dir/mariadb-all.sql.gz'"; then
      logical_dump_ok=1
      printf 'mariadb_method=logical_socket\n' >>"$db_md"
      MARIADB_BACKUP_METHOD="logical_socket"
    else
      log_warn "MariaDB socket/auth dump failed. Trying CloudPanel decrypted credentials."
      add_issue "MariaDB local-auth logical dump failed"
    fi
  elif optional_cmd_warn mysqldump && systemctl is-active --quiet mariadb; then
    if run_cmd bash -lc "set -o pipefail; mysqldump --all-databases --single-transaction --routines --events --triggers | gzip -1 > '$db_dir/mariadb-all.sql.gz'"; then
      logical_dump_ok=1
      printf 'mariadb_method=logical_socket\n' >>"$db_md"
      MARIADB_BACKUP_METHOD="logical_socket"
    else
      log_warn "mysqldump socket/auth dump failed. Trying CloudPanel decrypted credentials."
      add_issue "MariaDB mysqldump local-auth failed"
    fi
  fi

  if ((logical_dump_ok == 0)) && systemctl is-active --quiet mariadb; then
    if build_cloudpanel_mariadb_defaults_file "$cp_defaults"; then
      if optional_cmd_warn mariadb-dump; then
        if run_cmd bash -lc "set -o pipefail; mariadb-dump --defaults-extra-file='$cp_defaults' --all-databases --single-transaction --routines --events --triggers | gzip -1 > '$db_dir/mariadb-all.sql.gz'"; then
          logical_dump_ok=1
          printf 'mariadb_method=logical_cloudpanel_decrypted\n' >>"$db_md"
          MARIADB_BACKUP_METHOD="logical_cloudpanel_decrypted"
        fi
      elif optional_cmd_warn mysqldump; then
        if run_cmd bash -lc "set -o pipefail; mysqldump --defaults-extra-file='$cp_defaults' --all-databases --single-transaction --routines --events --triggers | gzip -1 > '$db_dir/mariadb-all.sql.gz'"; then
          logical_dump_ok=1
          printf 'mariadb_method=logical_cloudpanel_decrypted\n' >>"$db_md"
          MARIADB_BACKUP_METHOD="logical_cloudpanel_decrypted"
        fi
      fi
    fi
  fi

  if ((logical_dump_ok == 0)); then
    log_warn "Logical MariaDB dump unavailable. Falling back to physical snapshot (/var/lib/mysql + /etc/mysql)."
    if capture_mariadb_physical_snapshot "$db_dir"; then
      printf 'mariadb_method=physical_snapshot\n' >>"$db_md"
      MARIADB_BACKUP_METHOD="physical_snapshot"
    else
      printf 'mariadb_method=none\n' >>"$db_md"
      MARIADB_BACKUP_METHOD="none"
      add_issue "MariaDB physical snapshot fallback failed"
      if ((STRICT)); then
        die "Strict mode enabled and no MariaDB backup method succeeded"
      fi
    fi
  fi

  if [[ -f "$cp_defaults" && "$DRY_RUN" -eq 0 ]]; then
    rm -f "$cp_defaults"
  fi

  if optional_cmd_warn redis-cli && systemctl is-active --quiet redis-server; then
    if run_cmd redis-cli --rdb "$db_dir/redis-dump.rdb"; then
      REDIS_DUMP_DONE=1
    else
      add_issue "Redis dump command failed"
    fi
  else
    log_warn "Skipping Redis host dump (redis-cli missing or redis-server inactive)"
    add_issue "Redis dump skipped (redis-cli missing or redis-server inactive)"
  fi
}

capture_shared_postgres_dumps() {
  local db_dir="$BUNDLE_DIR/exports/databases"
  mkdir -p "$db_dir"

  if [[ ! -f "$SHARED_SERVICES_COMPOSE" ]]; then
    log_warn "Shared postgres compose file not found at $SHARED_SERVICES_COMPOSE"
    return 0
  fi

  local container_name
  container_name="$(docker compose -f "$SHARED_SERVICES_COMPOSE" ps -q shared-postgres 2>/dev/null || true)"
  if [[ -z "$container_name" ]]; then
    log_warn "Shared postgres container not running; skipping logical dumps"
    add_issue "Shared postgres logical dumps skipped (container not running)"
    return 0
  fi

  local db
  for db in ai_receptionist bella_tavola rechago telnyx_voice_adapter; do
    log_info "Dumping shared-postgres database: $db"
    if docker exec "$container_name" pg_dump -U postgres -d "$db" -Fc -f "/tmp/${db}.dump" 2>/dev/null; then
      if docker cp "${container_name}:/tmp/${db}.dump" "$db_dir/shared-pg-${db}.dump"; then
        log_info "  → shared-pg-${db}.dump captured"
      else
        log_warn "  → docker cp failed for $db"
        add_issue "Shared postgres docker cp failed for $db"
      fi
    else
      log_warn "  → pg_dump failed for $db"
      add_issue "Shared postgres pg_dump failed for $db"
    fi
  done
}

capture_database_version_metadata() {
  local md="$BUNDLE_DIR/metadata"
  mkdir -p "$md"

  local raw_version_file="$md/mariadb_version_raw.txt"
  local parsed_version_file="$md/mariadb_version.txt"

  if command -v mariadb >/dev/null 2>&1; then
    run_capture "$raw_version_file" mariadb --version
  elif command -v mysql >/dev/null 2>&1; then
    run_capture "$raw_version_file" mysql --version
  else
    log_warn "MariaDB/MySQL client not found; cannot store DB version metadata"
    if ((STRICT)); then
      die "Strict mode enabled and DB version metadata could not be captured"
    fi
    return 0
  fi

  if ((DRY_RUN)); then
    return 0
  fi

  local parsed
  parsed="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+-MariaDB|[0-9]+\.[0-9]+\.[0-9]+' "$raw_version_file" | head -n1 || true)"

  if [[ -z "$parsed" ]]; then
    log_warn "Could not parse MariaDB version from client output"
    if ((STRICT)); then
      die "Strict mode enabled and DB version parsing failed"
    fi
    return 0
  fi

  printf 'MARIADB_VERSION=%s\n' "$parsed" >"$parsed_version_file"
  log_info "Stored MariaDB version metadata: $parsed"
  SOURCE_MARIADB_VERSION="$parsed"
}

write_runtime_compose_files() {
  local rt_dir="$BUNDLE_DIR/exports/runtime"
  mkdir -p "$rt_dir"

  if container_exists n8n; then
    local n8n_image
    n8n_image="$(docker inspect n8n --format '{{.Config.Image}}')"
    run_capture "$rt_dir/n8n.env" docker inspect n8n --format "{{range .Config.Env}}{{println .}}{{end}}"

    cat >"$rt_dir/n8n.compose.yaml" <<EOF
services:
  n8n:
    image: ${n8n_image}
    container_name: n8n
    restart: unless-stopped
    env_file:
      - ./n8n.env
    ports:
      - "5678:5678"
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
    external: true
EOF
  fi

  if container_exists kestra; then
    local kestra_image
    kestra_image="$(docker inspect kestra --format '{{.Config.Image}}')"

    cat >"$rt_dir/kestra.compose.yaml" <<EOF
services:
  kestra:
    image: ${kestra_image}
    container_name: kestra
    restart: unless-stopped
    user: "root"
    command: ["server", "local"]
    ports:
      - "8080:8080"
    volumes:
      - kestra_data:/app/storage
      - kestra_app_data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
      - /tmp:/tmp

volumes:
  kestra_data:
    external: true
  kestra_app_data:
    external: true
EOF
  fi
}

write_manifest_and_checksums() {
  local md="$BUNDLE_DIR/metadata"

  cat >"$md/manifest.txt" <<EOF
created_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
hostname=$(hostname)
source_user=$(whoami)
source_path=$SCRIPT_DIR
strict_mode=$STRICT
dry_run=$DRY_RUN
EOF

  if ((DRY_RUN)); then
    return 0
  fi

  run_cmd bash -lc "cd '$BUNDLE_DIR' && find . -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS"
}

main() {
  parse_args "$@"

  init_logging "/home/frankie/migration_logs/pack-$(timestamp).log"
  trap 'on_exit $?' EXIT

  ensure_root
  require_cmds tar bzip2 sha256sum docker systemctl gzip find xargs sort

  if command -v dpkg-query >/dev/null 2>&1; then
    SOURCE_CLOUDPANEL_VERSION="$(dpkg-query -W -f='${Version}' cloudpanel 2>/dev/null || true)"
    if [[ -z "$SOURCE_CLOUDPANEL_VERSION" ]]; then
      SOURCE_CLOUDPANEL_VERSION="unknown"
    fi
  fi

  mkdir -p "$OUTPUT_DIR"

  WORK_DIR="$(mktemp -d /tmp/vps-pack-XXXXXX)"
  BUNDLE_DIR="$WORK_DIR/bundle"

  mkdir -p "$BUNDLE_DIR/exports/docker-volumes" "$BUNDLE_DIR/exports/filesystem" "$BUNDLE_DIR/exports/databases" "$BUNDLE_DIR/exports/runtime" "$BUNDLE_DIR/metadata"

  log_info "Detecting currently running workloads"

  if [[ -f "$CHATWOOT_COMPOSE" ]] && docker compose -f "$CHATWOOT_COMPOSE" ps --status running --quiet | grep -q .; then
    CHATWOOT_WAS_RUNNING=1
  fi

  if [[ -f "$SHARED_SERVICES_COMPOSE" ]] && docker compose -f "$SHARED_SERVICES_COMPOSE" ps --status running --quiet | grep -q .; then
    SHARED_SERVICES_WAS_RUNNING=1
  fi

  if is_container_running n8n; then
    N8N_WAS_RUNNING=1
  fi

  if is_container_running kestra; then
    KESTRA_WAS_RUNNING=1
  fi

  write_runtime_compose_files

  # Capture shared postgres logical dumps BEFORE stopping (container must be running)
  capture_shared_postgres_dumps

  log_info "Stopping app services for consistent snapshot"
  if ((CHATWOOT_WAS_RUNNING)); then
    run_cmd docker compose -f "$CHATWOOT_COMPOSE" stop
  fi
  if ((SHARED_SERVICES_WAS_RUNNING)); then
    run_cmd docker compose -f "$SHARED_SERVICES_COMPOSE" stop
  fi
  if ((N8N_WAS_RUNNING)); then
    run_cmd docker stop n8n
  fi
  if ((KESTRA_WAS_RUNNING)); then
    run_cmd docker stop kestra
  fi

  capture_metadata
  capture_host_filesystem
  capture_database_version_metadata
  capture_database_dumps

  export_volume frankie_postgres_data
  export_volume frankie_redis_data
  export_volume frankie_storage_data
  export_volume n8n_data
  export_volume kestra_data
  export_volume shared_postgres_data
  export_volume shared_redis_data
  export_kestra_app_data

  write_manifest_and_checksums

  local label_part
  if [[ -n "$LABEL" ]]; then
    label_part="$LABEL"
  else
    label_part="$(hostname)"
  fi

  local pack_ts
  pack_ts="$(timestamp)"
  ARCHIVE_PATH="$OUTPUT_DIR/migration-${label_part}-${pack_ts}.tar.bz2"

  if ((DRY_RUN)); then
    log_info "DRY-RUN complete. Archive would be created at: $ARCHIVE_PATH"
    return 0
  fi

  run_cmd tar -cjf "$ARCHIVE_PATH" -C "$WORK_DIR" bundle
  run_cmd bash -lc "sha256sum '$ARCHIVE_PATH' > '${ARCHIVE_PATH}.sha256'"
  ARCHIVE_CREATED=1

  if ((CREATE_PORTABLE_KIT)); then
    if ! create_portable_kit "$label_part" "$pack_ts"; then
      add_issue "Portable kit creation failed"
      log_warn "Portable kit creation failed; main archive is still valid"
    fi
  fi

  resume_services
  maybe_run_validation
}

main "$@"
