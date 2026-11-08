#!/usr/bin/env bash
# Safely stop or purge a private-v2, two-service AIOStreams installation.
set -Eeuo pipefail

readonly INSTALL_DIR='/opt/docker'
readonly MANAGED_MARKER='.aio-installer-managed'
readonly EXPECTED_SCHEMA='private-v2'
PURGE=false

log() { printf '[aio-uninstall] %s\n' "$*"; }
die() { printf '[aio-uninstall] ERROR: %s\n' "$*" >&2; exit 1; }

case "$#" in
  0) ;;
  1)
    case "$1" in
      --purge) PURGE=true ;;
      --help|-h)
        cat <<'EOF'
Usage: sudo bash Uninstall-AIOStreams.sh [--purge]
  No arguments: stop containers and remove project network; preserve /opt/docker.
  --purge: confirm, stop, back up /opt/docker and remove it.
Docker Engine, images, the aio account, and firewall settings are left intact.
EOF
        exit 0 ;;
      *) die 'unknown argument; use --help' ;;
    esac
    ;;
  *) die 'unexpected arguments; use --help' ;;
esac

[[ $EUID -eq 0 ]] || die 'run as root (sudo)'
[[ -d $INSTALL_DIR && ! -L $INSTALL_DIR ]] ||
  die '/opt/docker is missing or is a symbolic link'
[[ -f $INSTALL_DIR/$MANAGED_MARKER ]] ||
  die 'installer management marker is missing'
grep -Fxq "installer_schema=$EXPECTED_SCHEMA" "$INSTALL_DIR/$MANAGED_MARKER" ||
  die 'this uninstaller only supports private-v2 deployments'

command -v docker >/dev/null 2>&1 || die 'Docker is unavailable'
cd "$INSTALL_DIR"
services=$(docker compose config --services | sort) || die 'Compose configuration is invalid'
[[ $services == $'aiostreams\ntraefik' ]] ||
  die 'unexpected services detected; refusing to modify this deployment'

if [[ $PURGE == true ]]; then
  printf 'Type PURGE to back up and delete %s: ' "$INSTALL_DIR"
  read -r confirmation
  [[ $confirmation == PURGE ]] || die 'not confirmed; no changes made'
fi

docker compose down
log 'Stopped both containers and removed the project network.'

if [[ $PURGE == true ]]; then
  umask 077
  install -d -m 0700 /root/aiostreams-backups
  backup="/root/aiostreams-backups/aiostreams-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -C /opt -czf "$backup" docker
  tar -tzf "$backup" >/dev/null || die 'backup verification failed; installation preserved'
  [[ -s $backup && -f $INSTALL_DIR/$MANAGED_MARKER && ! -L $INSTALL_DIR ]] ||
    die 'backup or installer verification failed; installation preserved'
  cd /
  rm -rf -- "$INSTALL_DIR"
  log "Backup saved to $backup (contains private credentials and keys)."
  log 'Removed /opt/docker; Docker Engine and Linux service account retained.'
else
  log "Configuration and data are preserved in $INSTALL_DIR."
fi
