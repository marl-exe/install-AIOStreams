#!/usr/bin/env bash
# Installs the minimal AIOStreams deployment used by this VPS on Ubuntu.

set -Eeuo pipefail
IFS=$'\n\t'

readonly INSTALL_DIR='/opt/docker'
readonly SERVICE_USER='aio'
readonly PREFERRED_SERVICE_ID='1000'
readonly MAX_SERVICE_ID='60000'
readonly TEMPLATE_REPOSITORY='https://github.com/Viren070/docker-compose-template.git'
readonly TEMPLATE_REF='59137ec0ae7cb4a9bb386d931cda4f327dbc8625'
readonly MANAGED_MARKER='.aio-installer-managed'
readonly COMPLETE_MARKER='.aio-installer-complete'
readonly AIOSTREAMS_IMAGE='ghcr.io/viren070/aiostreams:v2.33.2'
readonly AUTHELIA_IMAGE='authelia/authelia:4.39.20'
readonly REDIS_IMAGE='redis:8.10.1-alpine'
readonly POSTGRES_IMAGE='postgres:17.11-alpine'
readonly TRAEFIK_IMAGE='traefik:v3.7.13'

DOMAIN=''
AUTH_HOST=''
LETSENCRYPT_EMAIL=''
PUBLIC_IP=''
DRY_RUN=false
SKIP_DNS_ADDRESS_CHECK=false
SERVICE_UID=''
SERVICE_GID=''
STAGING_DIR=''

log() { printf '[aio-installer] %s\n' "$*"; }
die() { printf '[aio-installer] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash Install-AIOStreams.sh [options]

Options:
  --domain NAME       Public AIOStreams hostname (prompted when omitted)
  --auth-host NAME    Public Authelia hostname (prompted when omitted)
  --email ADDRESS     Let's Encrypt notification email (prompted when omitted)
  --public-ip ADDRESS Expected public IPv4 address (detected when omitted)
  --skip-dns-address-check
                      Require DNS to resolve, but do not compare it with the VPS IP
  --dry-run           Validate the host and inputs without changing the VPS
  --help              Show this help

Use distinct DNS-only A records for --domain and --auth-host. Both records must
point at the VPS public IPv4 address while Let's Encrypt obtains certificates.
The script can safely resume a deployment that it previously prepared.
EOF
}

cleanup_staging() {
  if [[ -n ${STAGING_DIR:-} && -d $STAGING_DIR && $STAGING_DIR == /opt/aio-install.* ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}

on_error() {
  local line=$1 status=$2
  trap - ERR
  printf '[aio-installer] ERROR: installation stopped at line %s (exit %s).\n' "$line" "$status" >&2
  if [[ -d $INSTALL_DIR && -f $INSTALL_DIR/$MANAGED_MARKER && ! -f $INSTALL_DIR/$COMPLETE_MARKER ]]; then
    printf '[aio-installer] Re-run this installer to resume the prepared deployment.\n' >&2
  fi
  exit "$status"
}

is_valid_hostname() {
  local hostname=$1
  ((${#hostname} <= 253)) &&
    [[ $hostname =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

is_valid_ipv4() {
  local address=$1 octet
  local -a octets
  IFS=. read -r -a octets <<<"$address"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
  done
}

set_env_value() {
  local file=$1 key=$2 value=$3 temporary line found=false
  temporary=$(mktemp "${file}.tmp.XXXXXX")
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^[#[:space:]]*$key= ]]; then
      if [[ $found == false ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$temporary"
        found=true
      fi
    else
      printf '%s\n' "$line" >>"$temporary"
    fi
  done <"$file"
  [[ $found == true ]] || printf '%s=%s\n' "$key" "$value" >>"$temporary"
  chmod --reference="$file" "$temporary"
  mv -- "$temporary" "$file"
}

replace_exact_line() {
  local file=$1 expected=$2 replacement=$3 temporary
  temporary=$(mktemp "${file}.tmp.XXXXXX")
  if ! awk -v expected="$expected" -v replacement="$replacement" '
    BEGIN { found = 0 }
    $0 == expected { print replacement; found = 1; next }
    { print }
    END { if (!found) exit 42 }
  ' "$file" >"$temporary"; then
    rm -f -- "$temporary"
    die "the pinned template changed unexpectedly in $file"
  fi
  chmod --reference="$file" "$temporary"
  mv -- "$temporary" "$file"
}

insert_after_exact_line() {
  local file=$1 expected=$2 addition=$3 temporary
  temporary=$(mktemp "${file}.tmp.XXXXXX")
  if ! awk -v expected="$expected" -v addition="$addition" '
    BEGIN { found = 0 }
    $0 == expected { print; print addition; found++; next }
    { print }
    END { if (found != 1) exit 42 }
  ' "$file" >"$temporary"; then
    rm -f -- "$temporary"
    die "the pinned template changed unexpectedly in $file"
  fi
  chmod --reference="$file" "$temporary"
  mv -- "$temporary" "$file"
}

remove_exact_line() {
  local file=$1 expected=$2 temporary
  temporary=$(mktemp "${file}.tmp.XXXXXX")
  if ! awk -v expected="$expected" '
    BEGIN { found = 0 }
    $0 == expected { found++; next }
    { print }
    END { if (found != 1) exit 42 }
  ' "$file" >"$temporary"; then
    rm -f -- "$temporary"
    die "the pinned template changed unexpectedly in $file"
  fi
  chmod --reference="$file" "$temporary"
  mv -- "$temporary" "$file"
}

remove_exact_block() {
  local file=$1 first=$2 last=$3 temporary
  temporary=$(mktemp "${file}.tmp.XXXXXX")
  if ! awk -v first="$first" -v last="$last" '
    BEGIN { removing = 0; starts = 0; ends = 0 }
    $0 == first && !removing { removing = 1; starts++; next }
    $0 == last && removing { removing = 0; ends++; print; next }
    !removing { print }
    END { if (removing || starts != 1 || ends != 1) exit 42 }
  ' "$file" >"$temporary"; then
    rm -f -- "$temporary"
    die "the pinned template changed unexpectedly in $file"
  fi
  chmod --reference="$file" "$temporary"
  mv -- "$temporary" "$file"
}

install_docker() {
  log 'Installing required host packages.'
  apt-get update
  apt-get install -y ca-certificates curl git openssl iproute2 util-linux
  if command -v docker >/dev/null 2>&1; then
    docker compose version >/dev/null 2>&1 ||
      die 'Docker is already installed without the Compose plugin; install a compatible docker-compose-plugin first'
    if ! docker info >/dev/null 2>&1; then
      systemctl enable --now docker
      docker info >/dev/null || die 'Docker is installed, but its daemon is unavailable'
    fi
    return
  fi
  log "Installing Docker Engine and the Compose plugin from Docker's Ubuntu repository."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker compose version >/dev/null || die 'Docker Compose plugin installation failed'
  docker info >/dev/null || die 'Docker daemon is unavailable after installation'
}

find_available_service_id() {
  local candidate=$PREFERRED_SERVICE_ID
  while ((candidate <= MAX_SERVICE_ID)); do
    if ! getent passwd "$candidate" >/dev/null && ! getent group "$candidate" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
    ((candidate++))
  done
  return 1
}

create_service_account() {
  local existing_shell existing_group service_id
  if getent passwd "$SERVICE_USER" >/dev/null; then
    SERVICE_UID=$(id -u "$SERVICE_USER")
    SERVICE_GID=$(id -g "$SERVICE_USER")
    existing_shell=$(getent passwd "$SERVICE_USER" | cut -d: -f7)
    existing_group=$(getent group "$SERVICE_GID" | cut -d: -f1)
    [[ $SERVICE_UID -ne 0 && $SERVICE_GID -ne 0 ]] || die "existing $SERVICE_USER account uses UID or GID 0"
    [[ $existing_shell == '/usr/sbin/nologin' ]] || die "existing $SERVICE_USER account is not a nologin service account"
    [[ $existing_group == "$SERVICE_USER" ]] || die "existing $SERVICE_USER account does not use a same-named primary group"
    log "Reusing $SERVICE_USER (UID $SERVICE_UID, GID $SERVICE_GID)."
    return
  fi
  getent group "$SERVICE_USER" >/dev/null && die "group $SERVICE_USER exists without a matching user"
  service_id=$(find_available_service_id) || die "no free UID/GID found between $PREFERRED_SERVICE_ID and $MAX_SERVICE_ID"
  groupadd --gid "$service_id" "$SERVICE_USER"
  if ! useradd --uid "$service_id" --gid "$service_id" --create-home --shell /usr/sbin/nologin "$SERVICE_USER"; then
    groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
    die "failed to create $SERVICE_USER service account"
  fi
  SERVICE_UID=$service_id
  SERVICE_GID=$service_id
  log "Created $SERVICE_USER with UID/GID $service_id."
}

validate_dns() {
  local hostname address public_ip matched
  local -a resolved_addresses
  if [[ $SKIP_DNS_ADDRESS_CHECK == false ]]; then
    public_ip=$PUBLIC_IP
    if [[ -z $public_ip ]]; then
      public_ip=$(curl -4 --connect-timeout 5 --max-time 10 -fsS https://api.ipify.org) ||
        die 'could not detect the VPS public IPv4 address; use --public-ip or --skip-dns-address-check'
    fi
    is_valid_ipv4 "$public_ip" || die "invalid public IPv4 address: $public_ip"
    log "Expected public IPv4 address: $public_ip"
  fi
  for hostname in "$DOMAIN" "$AUTH_HOST"; do
    mapfile -t resolved_addresses < <(getent ahostsv4 "$hostname" | awk '{print $1}' | sort -u)
    ((${#resolved_addresses[@]} > 0)) || die "$hostname has no IPv4 DNS record"
    if [[ $SKIP_DNS_ADDRESS_CHECK == false ]]; then
      matched=false
      for address in "${resolved_addresses[@]}"; do
        [[ $address == "$public_ip" ]] && matched=true
      done
      [[ $matched == true ]] || die "$hostname does not resolve to the VPS public IPv4 address $public_ip"
    fi
  done
}

validate_new_install() {
  [[ -n $DOMAIN ]] || die 'AIOStreams public domain is required'
  [[ -n $AUTH_HOST ]] || die 'Authelia public domain is required'
  [[ -n $LETSENCRYPT_EMAIL ]] || die "Let's Encrypt notification email is required"
  is_valid_hostname "$DOMAIN" || die '--domain is not a valid fully qualified hostname'
  is_valid_hostname "$AUTH_HOST" || die '--auth-host is not a valid fully qualified hostname'
  [[ $DOMAIN != "$AUTH_HOST" ]] || die '--domain and --auth-host must be different hostnames'
  [[ $LETSENCRYPT_EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die '--email is not a valid email address'
  [[ -z $PUBLIC_IP ]] || is_valid_ipv4 "$PUBLIC_IP" || die '--public-ip is not a valid IPv4 address'
  if ss -ltnH | awk '{print $4}' | grep -Eq '(:80|:443)$'; then
    die 'TCP port 80 or 443 is already in use'
  fi
  validate_dns
}

configure_template() {
  local directory=$1 username=$2 proxy_password=$3 authelia_hash=$4
  local session_secret storage_secret jwt_secret traefik_compose
  session_secret=$(openssl rand -hex 32)
  storage_secret=$(openssl rand -hex 32)
  jwt_secret=$(openssl rand -hex 32)
  set_env_value "$directory/.env" 'TZ' 'Asia/Manila'
  set_env_value "$directory/.env" 'PUID' "$SERVICE_UID"
  set_env_value "$directory/.env" 'PGID' "$SERVICE_GID"
  set_env_value "$directory/.env" 'COMPOSE_PROFILES' '"required,aiostreams"'
  set_env_value "$directory/.env" 'LETSENCRYPT_EMAIL' "$LETSENCRYPT_EMAIL"
  set_env_value "$directory/.env" 'DOMAIN' "$DOMAIN"
  set_env_value "$directory/.env" 'AIOSTREAMS_HOSTNAME' "$DOMAIN"
  set_env_value "$directory/.env" 'AUTHELIA_HOSTNAME' "$AUTH_HOST"
  set_env_value "$directory/.env" 'COMPOSE_REMOVE_ORPHANS' 'false'
  set_env_value "$directory/.env" 'AUTHELIA_SESSION_SECRET' "\"$session_secret\""
  set_env_value "$directory/.env" 'AUTHELIA_STORAGE_ENCRYPTION_KEY' "\"$storage_secret\""
  set_env_value "$directory/.env" 'AUTHELIA_JWT_SECRET' "\"$jwt_secret\""
  set_env_value "$directory/apps/aiostreams/.env" 'SECRET_KEY' "$(openssl rand -hex 32)"
  set_env_value "$directory/apps/aiostreams/.env" 'AIOSTREAMS_AUTH' "$username:$proxy_password"
  set_env_value "$directory/apps/aiostreams/.env" 'AIOSTREAMS_AUTH_ADMINS' "$username"
  set_env_value "$directory/apps/aiostreams/.env" 'LOG_SENSITIVE_INFO' 'false'
  replace_exact_line "$directory/apps/aiostreams/compose.yaml" \
    "    image: ghcr.io/viren070/aiostreams:\${AIOSTREAMS_TAG:-latest}" "    image: $AIOSTREAMS_IMAGE"
  replace_exact_line "$directory/apps/authelia/compose.yaml" \
    "    image: 'authelia/authelia'" "    image: '$AUTHELIA_IMAGE'"
  replace_exact_line "$directory/apps/authelia/compose.yaml" \
    '    image: redis:latest' "    image: $REDIS_IMAGE"
  replace_exact_line "$directory/apps/authelia/compose.yaml" \
    '    image: postgres:17-alpine' "    image: $POSTGRES_IMAGE"
  replace_exact_line "$directory/apps/traefik/compose.yaml" \
    '    image: traefik:v3' "    image: $TRAEFIK_IMAGE"

  traefik_compose="$directory/apps/traefik/compose.yaml"
  remove_exact_line "$traefik_compose" '      - 853:853'
  remove_exact_line "$traefik_compose" '      - "--entryPoints.dot.address=:853"'
  remove_exact_line "$traefik_compose" "      - '--api=true'"
  remove_exact_line "$traefik_compose" "      - '--api.dashboard=true'"
  remove_exact_line "$traefik_compose" "      - '--api.insecure=false'"
  remove_exact_line "$traefik_compose" '      - "--providers.docker=true"'
  remove_exact_line "$traefik_compose" '      - "--providers.docker.exposedbydefault=false"'
  remove_exact_line "$traefik_compose" '      - "--providers.docker.network=${DOCKER_NETWORK?}"'
  remove_exact_line "$traefik_compose" '      - "/var/run/docker.sock:/var/run/docker.sock"'
  insert_after_exact_line "$traefik_compose" \
    "      - '--global.checkNewVersion=false'" \
    $'      - "--providers.file.directory=/etc/traefik/dynamic"\n      - "--providers.file.watch=true"'
  insert_after_exact_line "$traefik_compose" \
    '      - "${DOCKER_DATA_DIR}/traefik:/data"' \
    '      - "${DOCKER_APP_DIR}/traefik/dynamic:/etc/traefik/dynamic:ro"'
  remove_exact_block "$traefik_compose" '    labels:' '    healthcheck:'
  remove_exact_block "$directory/apps/authelia/compose.yaml" '    labels:' '    volumes:'
  remove_exact_block "$directory/apps/aiostreams/compose.yaml" '    labels:' '    volumes:'

  install -d -m 0750 "$directory/apps/traefik/dynamic"
  cat >"$directory/apps/traefik/dynamic/routes.yml" <<EOF
---
http:
  routers:
    aiostreams:
      rule: 'Host(\`$DOMAIN\`)'
      entryPoints:
        - websecure
      middlewares:
        - authelia
      service: aiostreams
      tls:
        certResolver: letsencrypt
    authelia:
      rule: 'Host(\`$AUTH_HOST\`)'
      entryPoints:
        - websecure
      service: authelia
      tls:
        certResolver: letsencrypt
  middlewares:
    authelia:
      forwardAuth:
        address: 'http://authelia:9091/api/authz/forward-auth'
        trustForwardHeader: true
        authResponseHeaders:
          - Remote-User
          - Remote-Groups
          - Remote-Email
          - Remote-Name
  services:
    aiostreams:
      loadBalancer:
        servers:
          - url: 'http://aiostreams:3000'
    authelia:
      loadBalancer:
        servers:
          - url: 'http://authelia:9091'
EOF
  chmod 0644 "$directory/apps/traefik/dynamic/routes.yml"
  install -d -m 0750 "$directory/data/aiostreams"
  cat >"$directory/apps/authelia/config/users.yml" <<EOF
---
users:
  $username:
    disabled: false
    displayname: "$username"
    password: "$authelia_hash"
    email: "$LETSENCRYPT_EMAIL"
    groups:
      - admins
...
EOF
  chmod 600 "$directory/.env" "$directory/apps/aiostreams/.env" \
    "$directory/apps/authelia/config/users.yml"
}

generate_authelia_hash() {
  local password=$1 digest
  digest=$(
    printf '%s\n' "$password" |
      script --quiet --return --command \
        "docker run --rm --interactive --tty $AUTHELIA_IMAGE authelia crypto hash generate argon2 --no-confirm" \
        /dev/null |
      tr -d '\r' |
      awk '/^Digest: / { digest = $2 } END { if (digest) print digest }'
  )
  [[ $digest == "\$argon2id\$"* ]] || die 'Authelia password hash generation failed'
  printf '%s\n' "$digest"
}

start_deployment() {
  cd "$INSTALL_DIR"
  docker compose config --quiet
  docker compose pull
  docker compose up -d --wait --wait-timeout 180
  printf 'template_ref=%s\n' "$TEMPLATE_REF" >"$INSTALL_DIR/$COMPLETE_MARKER"
}

resume_installation() {
  grep -Fxq "template_ref=$TEMPLATE_REF" "$INSTALL_DIR/$MANAGED_MARKER" ||
    die "$INSTALL_DIR was prepared by an incompatible installer version"
  log 'Resuming the installer-managed deployment.'
  install_docker
  start_deployment
  log 'Deployment resumed successfully.'
}

main() {
  local aio_username aio_proxy_password authelia_password authelia_hash
  while (($#)); do
    case "$1" in
      --domain|--auth-host|--email|--public-ip)
        (($# >= 2)) || die "missing value for $1"
        case "$1" in
          --domain) DOMAIN=$2 ;;
          --auth-host) AUTH_HOST=$2 ;;
          --email) LETSENCRYPT_EMAIL=$2 ;;
          --public-ip) PUBLIC_IP=$2 ;;
        esac
        shift 2
        ;;
      --skip-dns-address-check) SKIP_DNS_ADDRESS_CHECK=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ $EUID -eq 0 ]] || die 'run this script as root (for example: sudo bash ...)'
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ ${ID:-} == 'ubuntu' ]] || die 'only Ubuntu is supported'
  case ${VERSION_CODENAME:-} in
    resolute|noble|jammy) ;;
    *) die "Ubuntu ${VERSION_CODENAME:-unknown} is not supported" ;;
  esac
  if [[ -e $INSTALL_DIR ]]; then
    [[ -d $INSTALL_DIR && -f $INSTALL_DIR/$MANAGED_MARKER ]] ||
      die "$INSTALL_DIR already exists and is not managed by this installer"
    [[ $DRY_RUN == false ]] || die 'dry-run is not available while resuming an installation'
    resume_installation
    exit 0
  fi
  if [[ -z $DOMAIN ]]; then read -r -p 'AIOStreams public domain: ' DOMAIN; fi
  if [[ -z $AUTH_HOST ]]; then read -r -p 'Authelia public domain: ' AUTH_HOST; fi
  if [[ -z $LETSENCRYPT_EMAIL ]]; then read -r -p "Let's Encrypt notification email: " LETSENCRYPT_EMAIL; fi
  if [[ $DRY_RUN == true ]]; then
    require_commands ss getent awk grep sort curl
  else
    install_docker
    require_commands ss getent awk grep sort curl openssl git docker script tr
  fi
  validate_new_install
  if [[ $DRY_RUN == true ]]; then
    log 'Dry run passed. No packages, files, containers, accounts, or credentials were changed.'
    exit 0
  fi
  read -r -p 'AIOStreams proxy/API username [marl]: ' aio_username
  aio_username=${aio_username:-marl}
  [[ $aio_username =~ ^[A-Za-z0-9._-]+$ ]] || die 'proxy/API username contains unsupported characters'
  read -r -s -p 'Choose AIOStreams proxy/API password (16+ letters/numbers/._-): ' aio_proxy_password
  printf '\n'
  [[ $aio_proxy_password =~ ^[A-Za-z0-9._-]{16,}$ ]] || die 'proxy/API password is invalid'
  read -r -s -p 'Choose Authelia login password (16+ letters/numbers/._-): ' authelia_password
  printf '\n'
  [[ $authelia_password =~ ^[A-Za-z0-9._-]{16,}$ ]] || die 'Authelia password is invalid'
  create_service_account
  log "Generating an Authelia password hash with $AUTHELIA_IMAGE."
  docker pull "$AUTHELIA_IMAGE" >/dev/null
  authelia_hash=$(generate_authelia_hash "$authelia_password")
  STAGING_DIR=$(mktemp -d /opt/aio-install.XXXXXX)
  log "Cloning reviewed template revision $TEMPLATE_REF into a staging directory."
  git clone --no-checkout "$TEMPLATE_REPOSITORY" "$STAGING_DIR"
  git -C "$STAGING_DIR" checkout --detach "$TEMPLATE_REF"
  configure_template "$STAGING_DIR" "$aio_username" "$aio_proxy_password" "$authelia_hash"
  docker compose --env-file "$STAGING_DIR/.env" -f "$STAGING_DIR/compose.yaml" config --quiet
  chown -R "$SERVICE_USER:$SERVICE_USER" "$STAGING_DIR/apps/authelia/config" "$STAGING_DIR/data/aiostreams"
  printf 'template_ref=%s\n' "$TEMPLATE_REF" >"$STAGING_DIR/$MANAGED_MARKER"
  mv -- "$STAGING_DIR" "$INSTALL_DIR"
  STAGING_DIR=''
  unset aio_proxy_password authelia_password authelia_hash
  start_deployment
  log 'Deployment complete.'
  log "Open https://$DOMAIN/stremio/configure and authenticate through Authelia as $aio_username."
  log 'The AIOStreams proxy/API credential is separate and is not a dashboard login.'
  log 'Protect SSH, TCP/80, and TCP/443 with your VPS-provider firewall. Store backups off the VPS.'
}

trap cleanup_staging EXIT
trap 'on_error "$LINENO" "$?"' ERR

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
