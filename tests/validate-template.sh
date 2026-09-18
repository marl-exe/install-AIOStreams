#!/usr/bin/env bash

set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repository_root/Install-AIOStreams.sh"

is_valid_hostname 'aio.example.com'
if is_valid_hostname '.example.com'; then exit 1; fi
if is_valid_hostname 'example.com.'; then exit 1; fi
if is_valid_hostname 'example'; then exit 1; fi
is_valid_ipv4 '203.0.113.10'
if is_valid_ipv4 '203.0.113.999'; then exit 1; fi

fixture=$(mktemp -d)
cleanup_fixture() {
  rm -rf -- "$fixture"
}
trap cleanup_fixture EXIT

git clone --filter=blob:none --no-checkout "$TEMPLATE_REPOSITORY" "$fixture"
git -C "$fixture" checkout --detach "$TEMPLATE_REF"

DOMAIN='aio.example.com'
AUTH_HOST='auth.aio.example.com'
LETSENCRYPT_EMAIL='test+ci@example.com'
SERVICE_UID='1001'
SERVICE_GID='1001'
configure_template "$fixture" 'test-user' 'abcdefghijklmnop' \
  "\$argon2id\$v=19\$m=65536,t=3,p=4\$test\$safedigest"

grep -Fxq "    image: $AIOSTREAMS_IMAGE" "$fixture/apps/aiostreams/compose.yaml"
grep -Fxq "    image: '$AUTHELIA_IMAGE'" "$fixture/apps/authelia/compose.yaml"
grep -Fxq "    image: $REDIS_IMAGE" "$fixture/apps/authelia/compose.yaml"
grep -Fxq "    image: $POSTGRES_IMAGE" "$fixture/apps/authelia/compose.yaml"
grep -Fxq "    image: $TRAEFIK_IMAGE" "$fixture/apps/traefik/compose.yaml"
grep -Fxq 'AIOSTREAMS_AUTH=test-user:abcdefghijklmnop' "$fixture/apps/aiostreams/.env"
grep -Eq '^SECRET_KEY=[0-9a-f]{64}$' "$fixture/apps/aiostreams/.env"
if grep -Fq '853:853' "$fixture/apps/traefik/compose.yaml"; then exit 1; fi
if grep -RFq '/var/run/docker.sock' \
  "$fixture/apps/aiostreams" "$fixture/apps/authelia" "$fixture/apps/traefik"; then exit 1; fi
if grep -Fq -- '--providers.docker' "$fixture/apps/traefik/compose.yaml"; then exit 1; fi
if grep -Fq -- '--api.' "$fixture/apps/traefik/compose.yaml"; then exit 1; fi
grep -Fxq '      - "--providers.file.directory=/etc/traefik/dynamic"' "$fixture/apps/traefik/compose.yaml"
# shellcheck disable=SC2016 # Assert the literal Compose interpolation.
grep -Fxq '      - "${DOCKER_APP_DIR}/traefik/dynamic:/etc/traefik/dynamic:ro"' "$fixture/apps/traefik/compose.yaml"
grep -Fxq "      rule: 'Host(\`aio.example.com\`)'" "$fixture/apps/traefik/dynamic/routes.yml"
grep -Fxq "      rule: 'Host(\`auth.aio.example.com\`)'" "$fixture/apps/traefik/dynamic/routes.yml"
grep -Fxq "        address: 'http://authelia:9091/api/authz/forward-auth'" "$fixture/apps/traefik/dynamic/routes.yml"
if grep -RFq 'traefik.enable=true' "$fixture/apps/aiostreams" "$fixture/apps/authelia" "$fixture/apps/traefik"; then exit 1; fi
# shellcheck disable=SC2016 # Assert that the literal secret-bearing command was removed.
if grep -Fq -- '--password "$authelia_password"' "$repository_root/Install-AIOStreams.sh"; then exit 1; fi

docker compose --env-file "$fixture/.env" -f "$fixture/compose.yaml" config --quiet

docker pull "$AUTHELIA_IMAGE" >/dev/null
generated_hash=$(generate_authelia_hash 'abcdefghijklmnop')
[[ $generated_hash == "\$argon2id\$"* ]]
