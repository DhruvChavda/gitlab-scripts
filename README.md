# GitLab Disaster Recovery Restore

Restores a self-hosted GitLab instance from a backup volume onto a fresh Ubuntu LTS instance. Automatically detects and installs the exact GitLab version from the backup to prevent version mismatch corruption.

## Prerequisites

- Fresh Ubuntu LTS instance (22.04 / 24.04)
- Backup volume mounted (default: `/mnt/gitlab-data/`)
- Root / sudo access
- Internet access (to download GitLab packages)

## Backup volume structure

The mounted volume must contain:

```
/mnt/gitlab-data/
├── gitlab/              -> /var/opt/gitlab (data)
│   ├── gitlab-rails/
│   │   └── VERSION      <- used to detect GitLab version
│   ├── git-data/
│   ├── postgresql/
│   └── ...
├── etc-gitlab/          -> /etc/gitlab (config)
│   ├── gitlab.rb
│   ├── gitlab-secrets.json
│   └── ssl/             <- SSL certs (if using manual certs)
└── var-log-gitlab/      -> /var/log/gitlab (logs)
```

## Usage

Both scripts support `-h` / `--help` for full usage details:

```bash
./gitlab-restore-prerequisites.sh --help
./gitlab-restore.sh --help
```

### Quick start

```bash
# 1. Run prerequisites check first
sudo ./gitlab-restore-prerequisites.sh
sudo ./gitlab-restore-prerequisites.sh --url https://gitlab.example.com

# 2. Run the restore
sudo ./gitlab-restore.sh

# Non-interactive (skip all confirmations)
sudo ./gitlab-restore.sh --yes

# Custom mount path
GITLAB_MOUNT_PATH=/mnt/custom sudo ./gitlab-restore.sh

# Override external_url (e.g. restoring to a different domain)
sudo ./gitlab-restore.sh --url https://gitlab.example.com

# Skip post-restore validation (faster, skips rake integrity checks)
sudo ./gitlab-restore.sh --yes --skip-validation

# Debug mode (verbose output)
sudo ./gitlab-restore.sh --debug --yes
```

## What the scripts do

### `gitlab-restore-prerequisites.sh` (read-only checks)

Validates the environment before restore — does NOT modify anything:
- **System checks** — root, disk space, RAM, internet connectivity
- **Backup volume** — structure, VERSION file, gitlab.rb, secrets, authorized_keys
- **SSL/certificates** — checks for manual certs or Let's Encrypt config, validates cert expiry
- **Network** — DNS resolution, port availability

### `gitlab-restore.sh` (restore)

1. **Pre-flight checks** — verifies the backup volume, essential files, disk space
2. **Version matching** — reads the GitLab version from the backup, installs the exact same version (purges any mismatched version)
3. **Filesystem setup** — symlinks backup volume dirs to standard GitLab paths
4. **Permissions** — fixes ownership on config, data, log, uploads, LFS, pages, and authorized_keys
5. **Reconfigure & start** — kills stale processes, cleans runtime files, runs `gitlab-ctl reconfigure`, starts services, runs health checks
6. **Post-restore validation** — checks database migrations, repository integrity, artifacts, LFS objects, and uploads (skip with `--skip-validation`)

## Important notes

- `gitlab-secrets.json` is critical — without it, encrypted data (CI/CD variables, 2FA keys, runner tokens) cannot be decrypted
- The script auto-detects GitLab edition (EE/CE) from the backup
- `external_url` is extracted from the backup's `gitlab.rb`, or override with `--url` if restoring to a different domain
- When using `--url`, all domain references in `gitlab.rb` (including SAML/OAuth URLs) are updated automatically
- Post-restore validation rake tasks can take a long time on large instances — use `--skip-validation` for faster restores and run them manually later
