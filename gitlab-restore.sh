#!/bin/bash
set -euo pipefail

# =============================================================================
# GitLab Disaster Recovery Restore Script
#
# Restores a self-hosted GitLab instance from a backup volume on a fresh
# Ubuntu LTS instance. Ensures the exact same GitLab version is installed
# before restoring data to prevent version mismatch corruption.
#
# Usage: sudo ./gitlab-restore.sh [--yes] [--debug] [--url <external_url>] [--skip-validation]
#   --yes              Skip interactive confirmations
#   --debug            Enable debug output (set -x)
#   --url <url>        Override external_url (otherwise extracted from backup's gitlab.rb)
#   --skip-validation  Skip post-restore data validation rake tasks (faster)
# =============================================================================

# --- Configuration -----------------------------------------------------------
MOUNT_PATH="${GITLAB_MOUNT_PATH:-/mnt/gitlab-data}"
AUTO_YES=false
DEBUG=false
SKIP_VALIDATION=false
EXTERNAL_URL_OVERRIDE=""

# --- Help text ---------------------------------------------------------------
usage() {
  cat <<'HELP'
GitLab Disaster Recovery Restore Script

Restores a self-hosted GitLab instance from a backup volume on a fresh
Ubuntu LTS instance. Detects and installs the exact GitLab version from
the backup to prevent version mismatch corruption.

USAGE
  sudo ./gitlab-restore.sh [OPTIONS]

OPTIONS
  -h, --help             Show this help message and exit
  --yes                  Skip interactive confirmations (non-interactive mode)
  --debug                Enable debug output (set -x)
  --url <url>            Override external_url for the restored instance
                         (default: extracted from backup's gitlab.rb)
  --skip-validation      Skip post-restore data validation rake tasks
                         (db:migrate:status, git:fsck, artifacts, LFS, uploads)

ENVIRONMENT VARIABLES
  GITLAB_MOUNT_PATH      Path to the mounted backup volume (default: /mnt/gitlab-data)

EXAMPLES
  # Interactive restore from default mount path
  sudo ./gitlab-restore.sh

  # Fully automated restore to a different domain
  sudo ./gitlab-restore.sh --yes --url https://gitlab-dr.example.com

  # Fast restore (skip lengthy integrity checks)
  sudo ./gitlab-restore.sh --yes --skip-validation

  # Custom mount path with debug output
  GITLAB_MOUNT_PATH=/mnt/custom sudo ./gitlab-restore.sh --debug

PHASES
  1. Pre-flight checks     Verifies backup volume, essential files, disk space
  2. Version matching       Installs the exact GitLab version from the backup
  3. Filesystem setup       Symlinks backup volume dirs to standard GitLab paths
  4. Permissions            Fixes ownership on config, data, logs, SSH keys
  5. Reconfigure & start    Kills stale processes, reconfigures, starts services
  6. Post-restore validation  Checks DB migrations, repo integrity, artifacts, LFS, uploads

Run gitlab-restore-prerequisites.sh first to validate the environment.
HELP
}

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --yes)   AUTO_YES=true ;;
    --debug) DEBUG=true ;;
    --skip-validation) SKIP_VALIDATION=true ;;
    --url)
      if [[ -n "${2:-}" ]]; then
        EXTERNAL_URL_OVERRIDE="$2"
        shift
      else
        echo "Error: --url requires a value"; usage; exit 1
      fi
      ;;
    *)       echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

if $DEBUG; then
  set -x
fi

# --- Helper functions --------------------------------------------------------
log()   { echo "[$( date '+%H:%M:%S' )] $*"; }
info()  { log "INFO  $*"; }
warn()  { log "WARN  $*"; }
error() { log "ERROR $*"; }
fatal() { error "$*"; exit 1; }

confirm() {
  if $AUTO_YES; then return 0; fi
  read -rp "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
}

# --- Root check --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  fatal "This script must be run as root (or with sudo)."
fi

# =============================================================================
# PHASE 1: Pre-flight checks
# =============================================================================
info "Starting pre-flight checks..."

# Check backup volume mount
if [[ ! -d "$MOUNT_PATH" ]]; then
  fatal "Backup volume not found at $MOUNT_PATH. Mount the volume first."
fi

# Check expected subdirectories
for subdir in gitlab etc-gitlab var-log-gitlab; do
  if [[ ! -d "$MOUNT_PATH/$subdir" ]]; then
    fatal "Expected directory $MOUNT_PATH/$subdir not found. Is this a valid GitLab backup volume?"
  fi
done

# Check essential files
VERSION_FILE="$MOUNT_PATH/gitlab/gitlab-rails/VERSION"
GITLAB_RB="$MOUNT_PATH/etc-gitlab/gitlab.rb"
SECRETS_FILE="$MOUNT_PATH/etc-gitlab/gitlab-secrets.json"

if [[ ! -f "$VERSION_FILE" ]]; then
  fatal "VERSION file not found at $VERSION_FILE. Cannot determine GitLab version from backup."
fi
if [[ ! -f "$GITLAB_RB" ]]; then
  fatal "gitlab.rb not found at $GITLAB_RB. Backup volume may be incomplete."
fi
if [[ ! -f "$SECRETS_FILE" ]]; then
  warn "gitlab-secrets.json not found at $SECRETS_FILE. Encrypted data (CI variables, 2FA, etc.) may be unrecoverable."
fi

# Extract version info from backup
BACKUP_VERSION_RAW=$(cat "$VERSION_FILE" | tr -d '[:space:]')
# e.g. "18.7.0-ee" -> edition=ee, version=18.7.0
if [[ "$BACKUP_VERSION_RAW" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-?(ee|ce)?$ ]]; then
  BACKUP_VERSION="${BASH_REMATCH[1]}"
  BACKUP_EDITION="${BASH_REMATCH[2]:-ee}"
else
  fatal "Could not parse version from VERSION file: '$BACKUP_VERSION_RAW'"
fi

GITLAB_PACKAGE="gitlab-${BACKUP_EDITION}"
# APT package version format: 18.7.0-ee.0
APT_VERSION="${BACKUP_VERSION}-${BACKUP_EDITION}.0"

# Determine external_url: CLI flag > backup gitlab.rb > fallback
if [[ -n "$EXTERNAL_URL_OVERRIDE" ]]; then
  EXTERNAL_URL="$EXTERNAL_URL_OVERRIDE"
  info "Using external_url from --url flag: $EXTERNAL_URL"
else
  EXTERNAL_URL=$(grep -oP "^external_url\s+['\"]?\K[^'\"]*" "$GITLAB_RB" 2>/dev/null | head -1 || true)
  if [[ -n "$EXTERNAL_URL" ]]; then
    info "Detected external_url from backup: $EXTERNAL_URL"
  else
    warn "Could not extract external_url from gitlab.rb. Will use 'http://localhost' as fallback."
    EXTERNAL_URL="http://localhost"
  fi
fi

# PostgreSQL version from backup
BACKUP_PG_VERSION=""
PG_VERSION_FILE="$MOUNT_PATH/gitlab/postgresql/data/PG_VERSION"
if [[ -f "$PG_VERSION_FILE" ]]; then
  BACKUP_PG_VERSION=$(cat "$PG_VERSION_FILE" | tr -d '[:space:]')
fi

# Disk space check
AVAILABLE_GB=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
if [[ "$AVAILABLE_GB" -lt 10 ]]; then
  warn "Low disk space: only ${AVAILABLE_GB}GB available on /. GitLab needs significant disk space."
fi

# --- Print summary -----------------------------------------------------------
echo ""
echo "============================================="
echo "  GitLab Disaster Recovery Restore Summary"
echo "============================================="
echo "  Backup volume:     $MOUNT_PATH"
echo "  GitLab version:    $BACKUP_VERSION ($BACKUP_EDITION)"
echo "  Package to install: $GITLAB_PACKAGE=$APT_VERSION"
echo "  External URL:      $EXTERNAL_URL"
[[ -n "$BACKUP_PG_VERSION" ]] && echo "  PostgreSQL version: $BACKUP_PG_VERSION"
echo "  Available disk:    ${AVAILABLE_GB}GB"
echo "============================================="
echo ""

confirm "Proceed with GitLab restore?"

# =============================================================================
# PHASE 2: Install matching GitLab version
# =============================================================================
info "Checking installed GitLab version..."

INSTALLED_VERSION=""
INSTALLED_PACKAGE=""
if dpkg -s gitlab-ee &>/dev/null; then
  INSTALLED_PACKAGE="gitlab-ee"
  INSTALLED_VERSION=$(dpkg -s gitlab-ee | grep '^Version:' | awk '{print $2}')
elif dpkg -s gitlab-ce &>/dev/null; then
  INSTALLED_PACKAGE="gitlab-ce"
  INSTALLED_VERSION=$(dpkg -s gitlab-ce | grep '^Version:' | awk '{print $2}')
fi

NEED_INSTALL=false

if [[ -n "$INSTALLED_VERSION" ]]; then
  info "Found installed: $INSTALLED_PACKAGE=$INSTALLED_VERSION"
  if [[ "$INSTALLED_PACKAGE" == "$GITLAB_PACKAGE" && "$INSTALLED_VERSION" == "$APT_VERSION" ]]; then
    info "Installed version matches backup. No reinstall needed."
  else
    warn "Version mismatch! Installed: $INSTALLED_PACKAGE=$INSTALLED_VERSION, Backup needs: $GITLAB_PACKAGE=$APT_VERSION"
    confirm "Purge $INSTALLED_PACKAGE=$INSTALLED_VERSION and install $GITLAB_PACKAGE=$APT_VERSION?"

    info "Stopping GitLab before purge..."
    gitlab-ctl stop 2>/dev/null || true
    sleep 3

    info "Purging $INSTALLED_PACKAGE..."
    GITLAB_SKIP_RECONFIGURE=1 apt-get purge -y "$INSTALLED_PACKAGE" || true
    NEED_INSTALL=true
  fi
else
  info "GitLab is not installed. Will install $GITLAB_PACKAGE=$APT_VERSION."
  NEED_INSTALL=true
fi

if $NEED_INSTALL; then
  # Set up GitLab apt repository if not already configured
  if ! apt-cache policy "$GITLAB_PACKAGE" 2>/dev/null | grep -q packages.gitlab.com; then
    info "Setting up GitLab apt repository..."
    apt-get update -qq
    apt-get install -y -qq curl openssh-server ca-certificates tzdata perl postfix < /dev/null || true

    curl -fsSL "https://packages.gitlab.com/install/repositories/gitlab/${GITLAB_PACKAGE}/script.deb.sh" | bash
  fi

  info "Installing $GITLAB_PACKAGE=$APT_VERSION..."
  EXTERNAL_URL="$EXTERNAL_URL" GITLAB_SKIP_RECONFIGURE=1 apt-get install -y "$GITLAB_PACKAGE=$APT_VERSION"

  if [[ $? -ne 0 ]]; then
    fatal "Failed to install $GITLAB_PACKAGE=$APT_VERSION. Check if this version is available in the repository."
  fi

  info "GitLab package installed successfully."
fi

# Post-install verification
INSTALLED_RAILS_VERSION=""
if [[ -f /opt/gitlab/embedded/service/gitlab-rails/VERSION ]]; then
  INSTALLED_RAILS_VERSION=$(cat /opt/gitlab/embedded/service/gitlab-rails/VERSION | tr -d '[:space:]')
fi

if [[ "$INSTALLED_RAILS_VERSION" != "$BACKUP_VERSION_RAW" ]]; then
  fatal "Version verification failed! Installed: '$INSTALLED_RAILS_VERSION', Expected: '$BACKUP_VERSION_RAW'"
fi
info "Version verified: $INSTALLED_RAILS_VERSION"

# PostgreSQL version check
if [[ -n "$BACKUP_PG_VERSION" ]]; then
  INSTALLED_PG_VERSION=$(/opt/gitlab/embedded/bin/psql --version 2>/dev/null | grep -oP '\d+' | head -1 || true)
  if [[ -n "$INSTALLED_PG_VERSION" && "$INSTALLED_PG_VERSION" != "$BACKUP_PG_VERSION" ]]; then
    fatal "PostgreSQL major version mismatch! Installed: $INSTALLED_PG_VERSION, Backup data: $BACKUP_PG_VERSION. This will cause data corruption."
  fi
  info "PostgreSQL version verified: $INSTALLED_PG_VERSION (matches backup PG_VERSION: $BACKUP_PG_VERSION)"
fi

# =============================================================================
# PHASE 3: Stop GitLab & prepare filesystem
# =============================================================================
timestamp=$(date +%Y%m%d_%H%M%S)

info "Stopping GitLab..."
gitlab-ctl stop 2>/dev/null || true
sleep 5

info "Backing up existing GitLab directories..."
for dir in /var/opt/gitlab /etc/gitlab /var/log/gitlab; do
  if [[ -L "$dir" || -d "$dir" ]]; then
    mv "$dir" "${dir}.bak.${timestamp}"
    info "Moved $dir -> ${dir}.bak.${timestamp}"
  fi
done
sleep 2

info "Creating symlinks to backup volume..."
ln -s "$MOUNT_PATH/gitlab" /var/opt/gitlab
ln -s "$MOUNT_PATH/etc-gitlab" /etc/gitlab
ln -s "$MOUNT_PATH/var-log-gitlab" /var/log/gitlab
info "Symlinks created."

# =============================================================================
# PHASE 4: Fix permissions
# =============================================================================
info "Fixing file permissions..."

# Config and secrets
chown root:root /etc/gitlab/gitlab.rb
chmod 600 /etc/gitlab/gitlab.rb
if [[ -f /etc/gitlab/gitlab-secrets.json ]]; then
  chown root:git /etc/gitlab/gitlab-secrets.json
  chmod 600 /etc/gitlab/gitlab-secrets.json
fi

# Main GitLab data
chown -R git:git /var/opt/gitlab/git-data 2>/dev/null || warn "git-data not found, skipping"
chown -R git:git /var/opt/gitlab/gitlab-rails 2>/dev/null || warn "gitlab-rails not found, skipping"
chown -R gitlab-psql:gitlab-psql /var/opt/gitlab/postgresql 2>/dev/null || warn "postgresql dir not found, skipping"

# Redis (if present)
chown -R gitlab-redis:gitlab-redis /var/opt/gitlab/redis 2>/dev/null || true

# Uploads, shared artifacts, LFS, pages
chown -R git:git /var/opt/gitlab/gitlab-rails/uploads 2>/dev/null || true
chown -R git:git /var/opt/gitlab/gitlab-rails/shared 2>/dev/null || true
chown -R git:gitlab-www /var/opt/gitlab/gitlab-workhorse 2>/dev/null || true
chown -R git:git /var/opt/gitlab/gitlab-pages 2>/dev/null || true

# Registry (optional)
chown -R registry:registry /var/opt/gitlab/registry 2>/dev/null || true

# Logs
chown -R root:root /var/log/gitlab

# Verify git user SSH access
if [[ -f /var/opt/gitlab/.ssh/authorized_keys ]]; then
  chown git:git /var/opt/gitlab/.ssh/authorized_keys
  chmod 600 /var/opt/gitlab/.ssh/authorized_keys
  info "authorized_keys found and permissions set."
else
  warn "authorized_keys not found. Git-over-SSH may not work until first key is added via UI."
fi

info "Permissions fixed."

# =============================================================================
# PHASE 5: Fresh start — kill everything, clean up, reconfigure & start
# =============================================================================

# Nuclear option: kill ALL GitLab processes. Old runsvdir, redis, postgres,
# prometheus, etc. from the previous instance may still be running and will
# interfere with the restore. This guarantees a completely clean slate.
info "Killing all stale GitLab processes..."
gitlab-ctl stop 2>/dev/null || true

# Force kill everything under /opt/gitlab — the old runit supervisor and its
# children often ignore SIGTERM. Use SIGKILL to guarantee they die.
# Note: we kill runsvdir children first, then runsvdir itself.
pkill -9 -P "$(pgrep -f 'runsvdir.*gitlab')" 2>/dev/null || true
pkill -9 -f 'runsvdir.*gitlab' 2>/dev/null || true
sleep 2

# Kill any stragglers (redis-server, postgres, prometheus, etc.)
pkill -9 -f '/opt/gitlab/embedded/bin' 2>/dev/null || true
sleep 2

# Stop the systemd unit (may already be dead, that's fine)
systemctl stop gitlab-runsvdir 2>/dev/null || true
sleep 1

# Verify nothing is left
REMAINING=$(pgrep -cf '/opt/gitlab' 2>/dev/null || echo "0")
if [[ "$REMAINING" -gt 0 ]]; then
  warn "$REMAINING GitLab processes still running, force killing..."
  pkill -9 -f '/opt/gitlab' 2>/dev/null || true
  sleep 3
fi
info "All GitLab processes killed."

# Clean ALL stale runtime files — sockets, pid files, redis cache
info "Cleaning stale runtime files..."
rm -f /var/opt/gitlab/redis/dump.rdb 2>/dev/null || true
rm -f /var/opt/gitlab/redis/redis.socket 2>/dev/null || true
rm -f /var/opt/gitlab/redis/redis.pid 2>/dev/null || true
rm -f /var/opt/gitlab/postgresql/.s.PGSQL.* 2>/dev/null || true
rm -f /var/opt/gitlab/postgresql/postmaster.pid 2>/dev/null || true
rm -f /var/opt/gitlab/gitaly/gitaly.pid 2>/dev/null || true
rm -f /var/opt/gitlab/gitaly/gitaly.socket 2>/dev/null || true
rm -f /var/opt/gitlab/gitlab-workhorse/sockets/*.socket 2>/dev/null || true
info "Stale runtime files cleaned."

# Start fresh: bring up the runit supervisor, then all services
info "Starting runit supervisor..."
systemctl start gitlab-runsvdir
sleep 5

info "Starting all GitLab services..."
gitlab-ctl start
sleep 10

# Wait for Redis to be ready (reconfigure needs it)
info "Waiting for Redis to be ready..."
REDIS_RETRIES=0
while [[ $REDIS_RETRIES -lt 30 ]]; do
  if /opt/gitlab/embedded/bin/redis-cli -s /var/opt/gitlab/redis/redis.socket PING 2>/dev/null | grep -q PONG; then
    info "Redis is ready."
    break
  fi
  REDIS_RETRIES=$((REDIS_RETRIES + 1))
  sleep 2
done
if [[ $REDIS_RETRIES -ge 30 ]]; then
  warn "Redis did not become ready within 60s. Attempting reconfigure anyway..."
fi

# Update domain in gitlab.rb if --url was provided
if [[ -n "$EXTERNAL_URL_OVERRIDE" ]]; then
  OLD_DOMAIN=$(grep -oP "^external_url\s+['\"]https?://\K[^'\":/]+" /etc/gitlab/gitlab.rb || true)
  NEW_DOMAIN=$(echo "$EXTERNAL_URL" | sed 's|https\?://||; s|/.*||')
  if [[ -n "$OLD_DOMAIN" && "$OLD_DOMAIN" != "$NEW_DOMAIN" ]]; then
    cp /etc/gitlab/gitlab.rb "/etc/gitlab/gitlab.rb.pre-restore-${timestamp}"
    info "Backed up gitlab.rb before domain replacement"
    info "Replacing domain $OLD_DOMAIN -> $NEW_DOMAIN in gitlab.rb..."
    sed -i "s|$OLD_DOMAIN|$NEW_DOMAIN|g" /etc/gitlab/gitlab.rb
  else
    info "Domain in gitlab.rb already matches $NEW_DOMAIN."
  fi
fi

info "Reconfiguring GitLab..."
if ! gitlab-ctl reconfigure; then
  warn "Reconfigure exited with errors (e.g. Let's Encrypt cert renewal behind a firewall)."
  warn "GitLab may still be functional. Review the errors above."
fi
sleep 5

info "Restarting all GitLab services..."
gitlab-ctl restart
sleep 10

info "GitLab status:"
gitlab-ctl status

info "Running GitLab health check..."
gitlab-rake gitlab:check SANITIZE=true || warn "Some checks failed. Please review above output."

# =============================================================================
# PHASE 6: Post-restore data validation
# =============================================================================
if $SKIP_VALIDATION; then
  info "Skipping post-restore validation (--skip-validation flag)."
else
  info "Running post-restore data validation..."

  # Database migration check — critical for version consistency
  info "Checking database migration status..."
  PENDING_MIGRATIONS=$(gitlab-rake db:migrate:status 2>/dev/null | grep -c "^\s*down" || echo "0")
  if [[ "$PENDING_MIGRATIONS" -eq 0 ]]; then
    info "All database migrations are up."
  else
    warn "$PENDING_MIGRATIONS pending database migrations detected. Running migrations..."
    gitlab-rake db:migrate || warn "Some migrations failed. Review output above."
  fi

  # Repository integrity (non-blocking, can take a while on large instances)
  info "Checking repository integrity (this may take a while)..."
  gitlab-rake gitlab:git:fsck 2>/dev/null || warn "Some repository integrity checks failed."

  # Artifacts, LFS, uploads checks
  info "Checking artifacts integrity..."
  gitlab-rake gitlab:artifacts:check 2>/dev/null || warn "Some artifact checks failed."

  info "Checking LFS objects..."
  gitlab-rake gitlab:lfs:check 2>/dev/null || warn "Some LFS checks failed."

  info "Checking uploads..."
  gitlab-rake gitlab:uploads:check 2>/dev/null || warn "Some upload checks failed."

  info "Post-restore validation complete."
fi

echo ""
echo "============================================="
echo "  Restore complete!"
echo "  Access GitLab at: $EXTERNAL_URL"
echo "============================================="
