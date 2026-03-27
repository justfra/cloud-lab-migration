# VPS Migration Scripts (Option A)

These scripts package and restore your mixed stack with CloudPanel kept host-native.

## Files

- `pack_migration.sh`: creates one `tar.bz2` archive with data/config/state snapshots.
- `restore_migration.sh`: restores the archive on a new VPS.
- `validate_migration.sh`: validates backup archive integrity and required payload contents.
- `lib/common.sh`: shared logging and runtime helpers.

## Configuration

Both `pack_migration.sh` and `restore_migration.sh` use a `BASE_DIR` variable (default: `/home/frankie`) for all user-directory paths. Change this single variable if the deployment moves to a different directory.

## What gets captured

- Docker volumes (if present):
  - `frankie_postgres_data` (Chatwoot PostgreSQL)
  - `frankie_redis_data` (Chatwoot Redis)
  - `frankie_storage_data` (Chatwoot file storage)
  - `shared_postgres_data` (shared PostgreSQL for chatbot, orders, rechago, telnyx voice)
  - `shared_redis_data` (shared Redis for orders, rechago)
  - `n8n_data`
  - `kestra_data`
  - `kestra_app_data` (exported from `kestra:/app/data`)
- Shared PostgreSQL logical backups (pg_dump):
  - `ai_receptionist`, `bella_tavola`, `rechago`, `telnyx_voice_adapter`
  - Saved as `shared-pg-{db}.dump` in `exports/databases/`
- Host filesystem/config snapshots:
  - `/etc/nginx`
  - `/etc/systemd/system`
  - `/usr/lib/systemd/system/clp-agent.service`
  - `/usr/lib/systemd/system/clp-nginx.service`
  - `/usr/lib/systemd/system/nginx.service`
  - `/home/clp`
  - `$BASE_DIR/.claude` (if present)
  - `$BASE_DIR/.claude.json` (if present)
  - `$BASE_DIR/.config/opencode` (if present)
  - `$BASE_DIR/.opencode` (if present)
  - `$BASE_DIR/.local/share/opencode` (if present)
  - `$BASE_DIR/.ssh` (if present)
  - `$BASE_DIR/cloud-lab-migration` (if present)
  - `$BASE_DIR/migration` (legacy compatibility path, if present)
  - `$BASE_DIR/docker-compose.yaml` (Chatwoot)
  - `$BASE_DIR/.env` (Chatwoot)
  - `$BASE_DIR/n8n-config.json`
  - `$BASE_DIR/shared-services/` (shared PostgreSQL + Redis compose)
  - `$BASE_DIR/*.sh` (top-level scripts, if present)
- Project .env files (gitignored, not recoverable from repos):
  - `$BASE_DIR/chatwoot_langgraph_chatbot/.env`
  - `$BASE_DIR/chatwoot_langgraph_chatbot_orders/.env`
  - `$BASE_DIR/chatwoot_telnyx_voice_integration/.env`
  - `$BASE_DIR/rechago/.env`
  - `$BASE_DIR/rechago/apps/public-api/.env`
  - `$BASE_DIR/rechago/apps/webhook-stripe/.env`
  - `$BASE_DIR/rechago/apps/worker-fulfilment/.env`
- Host DB backups (resilient):
  - MariaDB logical dump (socket auth first, then CloudPanel credential decryption fallback)
  - MariaDB physical snapshot fallback (`/var/lib/mysql` + `/etc/mysql`) when logical dump is unavailable
  - Redis host dump (`redis-cli --rdb`)
- Runtime metadata and checksums.
- MariaDB version metadata (`metadata/mariadb_version.txt`) used for restore compatibility checks.
- Backup method metadata (`metadata/db_backup_method.txt`) with selected MariaDB backup mode.

## Requirements

- Run as `root` (or with full `sudo` privileges).
- `docker`, `docker compose`, `tar`, `bzip2`, `sha256sum` installed.
- `php` and `sqlite3` available on source host for CloudPanel password decryption fallback.
- Maintenance window recommended (scripts stop/restart app services for consistency).

## Recommended workflow (Git repo + archive)

1) Clone this repository on both source and target hosts.
2) Run pack on source to generate a migration archive.
3) Transfer only the `migration-*.tar.bz2` (+ `.sha256`) to target.
4) Run restore from the cloned repo on target.

This avoids duplicated script copies and keeps one canonical script source under version control.

Canonical entrypoints from repo root:

- `./pack.sh`
- `./preflight.sh`
- `./validate.sh`
- `./restore.sh`

## Pack on source VPS

```bash
cd /home/frankie/cloud-lab-migration
sudo ./pack.sh --output-dir /home/frankie --label vps1 --verbose
```

Output example:

- `/home/frankie/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2`
- `/home/frankie/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2.sha256`
Optional (only if you want a standalone bundle):

```bash
sudo ./pack.sh --output-dir /home/frankie --label vps1 --create-kit --verbose
```

Then it also creates:

- `/home/frankie/migration-kit-vps1-YYYYMMDD-HHMMSS.tar.bz2`
- `/home/frankie/migration-kit-vps1-YYYYMMDD-HHMMSS.tar.bz2.sha256`

## Restore on target VPS

Before restore, prepare the target host:

```bash
sudo apt update && sudo apt -y upgrade && sudo apt -y install curl wget sudo bzip2
```

Install CloudPanel (use same major version line and match source version when possible):

- CloudPanel docs: `https://www.cloudpanel.io/docs/v2/getting-started/other/`
- Docker Engine docs: `https://docs.docker.com/engine/install/`
- Docker Compose plugin is usually installed as part of Docker Engine packages.
- Source host CloudPanel package: `2.5.3-1+clp-noble`
- Source host MariaDB: `11.4.10-MariaDB`

Docker apt repository note for Ubuntu:

- Use Docker Ubuntu repo (`https://download.docker.com/linux/ubuntu`), not Debian.
- If you see `404 ... docker.com/linux/debian noble Release`, replace the repo with the Ubuntu one.

After CloudPanel installation is complete, you can run migration directly. You do not need to manually initialize/create a permanent CloudPanel account for migrated data; restore brings back the source CloudPanel state. If the installer forces first-run onboarding, use a temporary account and proceed with restore.

Run preflight before restore:

```bash
cd /home/frankie/cloud-lab-migration
sudo ./preflight.sh --archive /path/to/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2
```

```bash
cd /home/frankie/cloud-lab-migration
sudo ./restore.sh --archive /path/to/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2 --verbose
```

You can also pass the portable kit directly (if created):

```bash
sudo ./restore.sh --archive /path/to/migration-kit-vps1-YYYYMMDD-HHMMSS.tar.bz2 --verbose
```

Restore now enforces a MariaDB version match against the source backup metadata before applying changes.
If logical dump restore is not available, restore automatically uses the packaged MariaDB physical snapshot.
Cloud provider and public IP are auto-detected during restore to update CloudPanel runtime identity (`config.cloud`, `config.masquerade_address`).
If detection is wrong, override with `--cloud-provider` and `--public-ip`.

CloudPanel + nginx mode note:

- In some restored environments, `clp-nginx` may handle panel traffic (`8443`) while `nginx.service` handles website vhosts on `80/443`.
- Restore includes fallback logic to start stock `nginx.service` when `80/443` are not listening after `clp-nginx` restart.

By default, payload is persisted under `/opt/vps-migration`.

## Safe testing modes

- Dry-run pack:

```bash
sudo ./pack.sh --dry-run --verbose
```

- Dry-run restore:

```bash
sudo ./restore.sh --archive /path/to/file.tar.bz2 --dry-run --verbose
```

- Validation only (backup archive):

```bash
sudo ./validate.sh --archive /path/to/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2 --verbose
```

## Optional flags

- `--create-kit`: create additional self-contained migration kit archive.
- `--cloud-provider`: override detected CloudPanel provider id (`do|aws|vultr|hetzner|gce`).
- `--public-ip`: override detected public IP used for CloudPanel masquerade address.
- `--strict`: fail on optional warnings.
- `--skip-host-restore`: restore only Docker/data payload, skip host config overwrite.
- `--skip-db-restore`: skip host MariaDB/Redis restore.
- `--no-start`: do not start services after restore.

## Interactive post-pack validation

After a successful non-dry-run pack, `pack_migration.sh` asks:

- `Run validation now? [Y/n]`

If you answer yes, it runs `validate_migration.sh --archive <newly-created-archive> --verbose` automatically.
If no archive is provided, validator uses the latest `/home/frankie/migration-*.tar.bz2`.

## Notes

- Archive contains secrets (`.env`, credentials, tokens). Keep it encrypted and access-limited.
- Host restore overwrites files under captured paths; script takes pre-restore backups in `/var/backups/vps-migration`.
- For DNS-dependent apps, repoint DNS to new VPS before final validation.
