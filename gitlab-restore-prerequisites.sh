#!/bin/bash
set -euo pipefail

# =============================================================================
# GitLab Disaster Recovery — Pre-Restore Prerequisites Check
#
# Read-only diagnostic script that validates the environment before running
# gitlab-restore.sh. Checks backup volume integrity, SSL/certificate state,
# system resources, and network readiness.
#
# Usage: sudo ./gitlab-restore-prerequisites.sh [--debug] [--url <external_url>]
#   --debug        Enable debug output (set -x)
#   --url <url>    Override external_url (otherwise extracted from backup's gitlab.rb)
# =============================================================================

# --- Configuration -----------------------------------------------------------
MOUNT_PATH="${GITLAB_MOUNT_PATH:-/mnt/gitlab-data}"
DEBUG=false
EXTERNAL_URL_OVERRIDE=""

# Result tracking
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
VOLUME_OK=true

# Detected values (populated during checks)
BACKUP_VERSION=""
BACKUP_EDITION=""
EXTERNAL_URL=""
SSL_MODE="None"

# --- Help text ---------------------------------------------------------------
usage() {
  cat <<'HELP'
GitLab Disaster Recovery — Pre-Restore Prerequisites Check

Read-only diagnostic script that validates the environment before running
gitlab-restore.sh. Does NOT modify anything on the system.

USAGE
  sudo ./gitlab-restore-prerequisites.sh [OPTIONS]

OPTIONS
  -h, --help          Show this help message and exit
  --debug             Enable debug output (set -x)
  --url <url>         Override external_url (default: extracted from backup's gitlab.rb)

ENVIRONMENT VARIABLES
  GITLAB_MOUNT_PATH   Path to the mounted backup volume (default: /mnt/gitlab-data)

EXAMPLES
  # Basic check with default settings
  sudo ./gitlab-restore-prerequisites.sh

  # Check with a custom domain
  sudo ./gitlab-restore-prerequisites.sh --url https://gitlab-dr.example.com

  # Custom mount path
  GITLAB_MOUNT_PATH=/mnt/custom sudo ./gitlab-restore-prerequisites.sh

CHECKS PERFORMED
  System          Root privileges, disk space, RAM, internet connectivity
  Backup volume   Mount path, directory structure, VERSION, gitlab.rb, secrets,
                  authorized_keys, volume size
  SSL/Certs       Manual certs existence & expiry, Let's Encrypt config
  Network         DNS resolution, DNS-to-VM match, port 80/443 availability

EXIT CODES
  0   All critical checks passed (warnings are OK)
  1   One or more checks FAILED
HELP
}

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --debug) DEBUG=true ;;
    --url)
      if [[ -n "${2:-}" ]]; then
        EXTERNAL_URL_OVERRIDE="$2"
        shift
      else
        echo "Error: --url requires a value"; usage; exit 1
      fi
      ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

if $DEBUG; then
  set -x
fi

# --- Color setup -------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BOLD=''; NC=''
fi

# --- Helper functions --------------------------------------------------------
log()   { echo "[$( date '+%H:%M:%S' )] $*"; }
info()  { log "INFO  $*"; }

check_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo -e "  ${GREEN}[PASS]${NC} $1"
}

check_warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  echo -e "  ${YELLOW}[WARN]${NC} $1"
  [[ -n "${2:-}" ]] && echo -e "         $2"
}

check_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo -e "  ${RED}[FAIL]${NC} $1"
  [[ -n "${2:-}" ]] && echo -e "         $2"
}

section_header() {
  echo ""
  echo -e "${BOLD}=== $1 ===${NC}"
}

# =============================================================================
# SECTION 1: System Checks
# =============================================================================
section_header "System Checks"

# Root check
if [[ $EUID -eq 0 ]]; then
  check_pass "Running as root"
else
  check_fail "Not running as root" "Run with: sudo $0"
fi

# Disk space
AVAILABLE_GB=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
if [[ "$AVAILABLE_GB" -ge 20 ]]; then
  check_pass "Disk space: ${AVAILABLE_GB}GB available"
elif [[ "$AVAILABLE_GB" -ge 10 ]]; then
  check_warn "Disk space: ${AVAILABLE_GB}GB available" "Recommended: 20GB+"
else
  check_fail "Disk space: only ${AVAILABLE_GB}GB available" "GitLab needs at least 10GB free"
fi

# RAM
if [[ -f /proc/meminfo ]]; then
  TOTAL_RAM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
  TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
  if [[ "$TOTAL_RAM_MB" -ge 8192 ]]; then
    check_pass "RAM: ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB)"
  elif [[ "$TOTAL_RAM_MB" -ge 4096 ]]; then
    check_warn "RAM: ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB)" "Recommended: 8GB+"
  else
    check_fail "RAM: ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB)" "GitLab needs at least 4GB RAM"
  fi
else
  check_warn "Could not determine RAM" "/proc/meminfo not available"
fi

# Internet connectivity
if command -v curl &>/dev/null; then
  if curl -fsS --max-time 10 https://packages.gitlab.com > /dev/null 2>&1; then
    check_pass "Internet: packages.gitlab.com reachable"
  else
    check_fail "Internet: packages.gitlab.com unreachable" "GitLab package installation requires internet access"
  fi
else
  check_warn "Internet: cannot check (curl not installed)"
fi

# =============================================================================
# SECTION 2: Backup Volume Checks
# =============================================================================
section_header "Backup Volume Checks"

# Mount path
if [[ -d "$MOUNT_PATH" ]]; then
  check_pass "Backup volume: $MOUNT_PATH exists"
else
  check_fail "Backup volume: $MOUNT_PATH not found" "Mount the backup volume first"
  VOLUME_OK=false
fi

if $VOLUME_OK; then
  # Volume structure
  for subdir in gitlab etc-gitlab var-log-gitlab; do
    if [[ -d "$MOUNT_PATH/$subdir" ]]; then
      check_pass "Directory: $MOUNT_PATH/$subdir"
    else
      check_fail "Directory: $MOUNT_PATH/$subdir missing" "Backup volume is incomplete"
    fi
  done

  # VERSION file
  VERSION_FILE="$MOUNT_PATH/gitlab/gitlab-rails/VERSION"
  if [[ -f "$VERSION_FILE" ]]; then
    VERSION_RAW=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    if [[ "$VERSION_RAW" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-?(ee|ce)?$ ]]; then
      BACKUP_VERSION="${BASH_REMATCH[1]}"
      BACKUP_EDITION="${BASH_REMATCH[2]:-ee}"
      check_pass "VERSION: $BACKUP_VERSION ($BACKUP_EDITION)"
    else
      check_fail "VERSION: unparseable value '$VERSION_RAW'" "Expected format: X.Y.Z-ee or X.Y.Z-ce"
    fi
  else
    check_fail "VERSION file not found at $VERSION_FILE"
  fi

  # gitlab.rb
  GITLAB_RB="$MOUNT_PATH/etc-gitlab/gitlab.rb"
  if [[ -f "$GITLAB_RB" ]]; then
    check_pass "gitlab.rb: found"
  else
    check_fail "gitlab.rb: not found at $GITLAB_RB"
  fi

  # gitlab-secrets.json
  SECRETS_FILE="$MOUNT_PATH/etc-gitlab/gitlab-secrets.json"
  if [[ -f "$SECRETS_FILE" ]]; then
    check_pass "gitlab-secrets.json: found"
  else
    check_warn "gitlab-secrets.json: not found" "Encrypted data (CI vars, 2FA, runner tokens) will be unrecoverable"
  fi

  # PostgreSQL version
  PG_VERSION_FILE="$MOUNT_PATH/gitlab/postgresql/data/PG_VERSION"
  if [[ -f "$PG_VERSION_FILE" ]]; then
    PG_VER=$(cat "$PG_VERSION_FILE" | tr -d '[:space:]')
    check_pass "PostgreSQL data version: $PG_VER"
  fi

  # authorized_keys
  if [[ -f "$MOUNT_PATH/gitlab/.ssh/authorized_keys" ]]; then
    check_pass "authorized_keys: found"
  else
    check_warn "authorized_keys: not found in backup" "Git-over-SSH may need reconfiguration after restore"
  fi

  # Backup volume size sanity check
  if command -v du &>/dev/null; then
    BACKUP_SIZE_GB=$(du -s --block-size=1G "$MOUNT_PATH" 2>/dev/null | awk '{print $1}' || echo "0")
    if [[ "$BACKUP_SIZE_GB" -lt 1 ]]; then
      check_warn "Backup volume suspiciously small: ${BACKUP_SIZE_GB}GB" "Expected at least a few GB for a GitLab instance"
    else
      check_pass "Backup volume size: ${BACKUP_SIZE_GB}GB"
    fi
  fi

  # Extract external_url
  if [[ -n "$EXTERNAL_URL_OVERRIDE" ]]; then
    EXTERNAL_URL="$EXTERNAL_URL_OVERRIDE"
    info "Using external_url from --url flag: $EXTERNAL_URL"
  elif [[ -f "$GITLAB_RB" ]]; then
    EXTERNAL_URL=$(grep -oP "^external_url\s+['\"]?\K[^'\"]*" "$GITLAB_RB" 2>/dev/null | head -1 || true)
    if [[ -n "$EXTERNAL_URL" ]]; then
      info "Detected external_url from backup: $EXTERNAL_URL"
    else
      check_warn "Could not extract external_url from gitlab.rb"
    fi
  fi
fi

# =============================================================================
# SECTION 3: SSL / Certificate Checks
# =============================================================================
section_header "SSL / Certificate Checks"

if ! $VOLUME_OK || [[ -z "$EXTERNAL_URL" ]]; then
  check_warn "Skipping SSL checks" "Backup volume or external_url not available"
else
  DOMAIN=$(echo "$EXTERNAL_URL" | sed 's|https\?://||; s|[:/].*||')

  if [[ "$EXTERNAL_URL" == http://* ]]; then
    check_pass "HTTP external_url — no SSL required"
    SSL_MODE="None (HTTP)"
  else
    # Check for manual certs on backup volume
    CERT_DIR="$MOUNT_PATH/etc-gitlab/ssl"
    CERT_FILE="$CERT_DIR/$DOMAIN.crt"
    KEY_FILE="$CERT_DIR/$DOMAIN.key"
    HAS_CERT=false
    HAS_KEY=false

    if [[ -f "$CERT_FILE" ]]; then HAS_CERT=true; fi
    if [[ -f "$KEY_FILE" ]]; then HAS_KEY=true; fi

    # Check Let's Encrypt config
    LETSENCRYPT_ENABLED=false
    if [[ -f "$GITLAB_RB" ]]; then
      if grep -qP "^\s*letsencrypt\['enable'\]\s*=\s*true" "$GITLAB_RB" 2>/dev/null; then
        LETSENCRYPT_ENABLED=true
      fi
    fi

    # Check for staging certs (informational)
    if [[ -f "$CERT_DIR/$DOMAIN.crt-staging" ]]; then
      info "Staging cert also found: $DOMAIN.crt-staging"
    fi

    if $HAS_CERT && $HAS_KEY; then
      check_pass "SSL certs found: $DOMAIN.crt and $DOMAIN.key"
      SSL_MODE="Manual certs"

      # Validate cert with openssl
      if command -v openssl &>/dev/null; then
        # Check expiry
        if openssl x509 -in "$CERT_FILE" -noout -checkend 0 2>/dev/null; then
          if openssl x509 -in "$CERT_FILE" -noout -checkend 2592000 2>/dev/null; then
            check_pass "SSL cert is valid (not expired)"
          else
            EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            check_warn "SSL cert expiring within 30 days" "Expires: $EXPIRY"
          fi
        else
          EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
          check_fail "SSL cert is EXPIRED" "Expired: $EXPIRY"
        fi

        # Show cert details
        echo ""
        echo "  Certificate details:"
        openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/    /'
        echo ""
      else
        check_warn "openssl not installed — cannot validate cert expiry"
      fi

    elif $HAS_CERT || $HAS_KEY; then
      check_warn "Incomplete SSL certs" "Found $(${HAS_CERT} && echo '.crt' || echo '.key') but missing $(${HAS_CERT} && echo '.key' || echo '.crt')"
      SSL_MODE="Incomplete"

    else
      # No certs on volume
      if $LETSENCRYPT_ENABLED; then
        check_warn "No SSL certs on volume, but Let's Encrypt is enabled" "Ensure DNS points to this VM and port 80 is open for ACME challenge"
        SSL_MODE="Let's Encrypt (auto)"
      else
        # Check if letsencrypt is configured via auto-enable (default for https urls)
        # GitLab auto-enables Let's Encrypt for HTTPS URLs unless explicitly disabled
        LE_DISABLED=false
        if grep -qP "^\s*letsencrypt\['enable'\]\s*=\s*false" "$GITLAB_RB" 2>/dev/null; then
          LE_DISABLED=true
        fi

        if $LE_DISABLED; then
          check_fail "HTTPS URL but no SSL certs and Let's Encrypt is disabled" "Provide certs at /etc/gitlab/ssl/$DOMAIN.{crt,key} or enable Let's Encrypt"
          SSL_MODE="None (MISSING)"
        else
          check_warn "No SSL certs on volume — GitLab will auto-enable Let's Encrypt for HTTPS URLs" "Ensure DNS points to this VM and port 80 is open for ACME challenge"
          SSL_MODE="Let's Encrypt (auto)"
        fi
      fi
    fi
  fi
fi

# =============================================================================
# SECTION 4: Network Checks
# =============================================================================
section_header "Network Checks"

if [[ -z "$EXTERNAL_URL" ]]; then
  check_warn "Skipping network checks" "external_url not available"
else
  DOMAIN=$(echo "$EXTERNAL_URL" | sed 's|https\?://||; s|[:/].*||')

  # DNS resolution
  RESOLVED_IP=""
  if command -v dig &>/dev/null; then
    RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+' | head -1 || true)
  elif command -v host &>/dev/null; then
    RESOLVED_IP=$(host "$DOMAIN" 2>/dev/null | grep -oP 'has address \K[\d.]+' | head -1 || true)
  elif command -v getent &>/dev/null; then
    RESOLVED_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)
  elif command -v nslookup &>/dev/null; then
    RESOLVED_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / {print $2}' | head -1 || true)
  else
    check_warn "DNS: no lookup tool available (dig/host/getent/nslookup)"
  fi

  if [[ -n "$RESOLVED_IP" ]]; then
    check_pass "DNS: $DOMAIN resolves to $RESOLVED_IP"

    # Check if it points to this VM
    MY_IP=""
    if command -v curl &>/dev/null; then
      MY_IP=$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
    fi

    if [[ -n "$MY_IP" ]]; then
      if [[ "$RESOLVED_IP" == "$MY_IP" ]]; then
        check_pass "DNS points to this VM ($MY_IP)"
      else
        check_warn "DNS mismatch: $DOMAIN -> $RESOLVED_IP, this VM -> $MY_IP" "Update DNS if this is the target VM (may be behind a proxy/CDN)"
      fi
    fi
  elif [[ -n "$(command -v dig 2>/dev/null || command -v host 2>/dev/null || command -v getent 2>/dev/null)" ]]; then
    check_warn "DNS: $DOMAIN does not resolve" "Ensure DNS is configured before restore"
  fi

  # Port availability
  for port in 80 443; do
    LISTENING=""
    if command -v ss &>/dev/null; then
      LISTENING=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 || true)
    elif command -v netstat &>/dev/null; then
      LISTENING=$(netstat -tlnp 2>/dev/null | grep ":${port} " | head -1 || true)
    fi

    if [[ -n "$LISTENING" ]]; then
      PROC=$(echo "$LISTENING" | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")
      check_warn "Port $port: already in use by $PROC" "Will be reclaimed by GitLab during restore"
    else
      check_pass "Port $port: available"
    fi
  done
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================="
echo "  GitLab Restore Prerequisites Report"
echo "============================================="
echo "  Backup volume:     $MOUNT_PATH"
[[ -n "$BACKUP_VERSION" ]] && echo "  GitLab version:    $BACKUP_VERSION ($BACKUP_EDITION)"
[[ -n "$EXTERNAL_URL" ]]   && echo "  External URL:      $EXTERNAL_URL"
echo "  SSL:               $SSL_MODE"
echo "---------------------------------------------"
echo -e "  ${GREEN}PASSED:${NC}   $PASS_COUNT"
echo -e "  ${YELLOW}WARNINGS:${NC} $WARN_COUNT"
echo -e "  ${RED}FAILED:${NC}   $FAIL_COUNT"
echo "============================================="
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo -e "${RED}One or more checks FAILED. Fix these before running gitlab-restore.sh.${NC}"
  exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  echo -e "${YELLOW}All critical checks passed. Review warnings above.${NC}"
  exit 0
else
  echo -e "${GREEN}All checks passed. Ready to run gitlab-restore.sh.${NC}"
  exit 0
fi
