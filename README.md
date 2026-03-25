# cloud-lab-migration

Portable VPS migration toolkit for moving CloudPanel + Docker workloads between servers with minimal manual steps.

## Repository Layout

- `migration/` - main pack/restore/validate scripts and docs
- `run_chatwoot.sh` - helper launcher
- `run_kestra.sh` - helper launcher
- `run_n8n.sh` - helper launcher
- `chatwoot-n8n-production-guidelines.md` - operational notes

## Quick Start

Create a migration backup + portable kit on source host:

```bash
sudo ./migration/pack_migration.sh --output-dir /home/frankie --label vps1 --verbose
```

On target host, extract the kit and restore:

```bash
tar xjf migration-kit-*.tar.bz2
sudo ./run_validate.sh
sudo ./run_restore.sh --verbose
```

For full details, see `migration/README.md`.
