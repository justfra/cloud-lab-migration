# cloud-lab-migration

Portable VPS migration toolkit for moving CloudPanel + Docker workloads between servers with minimal manual steps.

## Repository Layout

- `migration/` - main pack/restore/validate scripts and docs
- `pack.sh` - root wrapper for pack script
- `preflight.sh` - checks target host prerequisites before restore
- `restore.sh` - root wrapper for restore script
- `validate.sh` - root wrapper for archive validator
- `run_chatwoot.sh` - helper launcher
- `run_kestra.sh` - helper launcher
- `run_n8n.sh` - helper launcher
- `chatwoot-n8n-production-guidelines.md` - operational notes

## Quick Start

Recommended: clone this repo on both source and target hosts, then transfer only backup archives.

Create a migration backup on source host:

```bash
sudo ./pack.sh --output-dir /home/frankie --label vps1 --verbose
```

On target host (from cloned repo), validate and restore:

```bash
sudo ./preflight.sh --archive /home/frankie/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2
sudo ./validate.sh --archive /home/frankie/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2 --verbose
sudo ./restore.sh --archive /home/frankie/migration-vps1-YYYYMMDD-HHMMSS.tar.bz2 --verbose
```

Optional standalone mode:

```bash
sudo ./pack.sh --output-dir /home/frankie --label vps1 --create-kit --verbose
```

This also creates `migration-kit-*.tar.bz2` if you prefer a single self-contained file.

For full details, see `migration/README.md`.
