# Install-AIOStreams

> **Looking for a # Install-AIOStreams

0.88/year VPS?** Use my referral links:
>
> DediRock Promo VPS - New York: https://billing.dedirock.com/aff.php?aff=898&pid=264
>
> DediRock Promo VPS - Los Angeles: https://billing.dedirock.com/aff.php?aff=898&pid=265
>
> GreenCloudVPS: https://greencloudvps.com/billing/aff.php?aff=10195&gid=68
>
> These are referral/affiliate links, which may provide me with a referral benefit if you sign up through them. Pricing and stock can change.

Install script for a minimal AIOStreams Docker deployment on a fresh Ubuntu VPS. It configures AIOStreams behind Traefik and Authelia, generates secrets locally, validates the complete Compose model before publishing it, and safely resumes an interrupted deployment.

## Supported systems

- Ubuntu 26.04 (`resolute`)
- Ubuntu 24.04 (`noble`)
- Ubuntu 22.04 (`jammy`)
- A public IPv4 address
- Root or `sudo` access

The installer uses a reviewed, pinned revision of `Viren070/docker-compose-template`. Runtime images are also pinned to explicit versions so a later `latest` image cannot silently change an existing installation recipe. Traefik uses a generated file-provider configuration and has no access to the host Docker socket.

## Before running

1. Start with a fresh supported Ubuntu VPS.
2. Create two distinct DNS A records: one for AIOStreams and one for Authelia.
3. Point both records directly to the VPS public IPv4 address.
4. If using Cloudflare, set both records to **DNS only** while certificates are issued.
5. Ensure TCP ports 80 and 443 are free.
6. Ensure `/opt/docker` does not contain an unrelated deployment.

The installer checks that both names resolve to the detected VPS public IPv4 address. If public-IP detection is unavailable, provide it explicitly with `--public-ip`. `--skip-dns-address-check` is available for unusual network arrangements, but incorrect DNS will normally prevent HTTPS certificate issuance.

## Clone

This repository is public and does not require GitHub authentication:

```bash
git clone https://github.com/marl-exe/install-AIOStreams.git
cd install-AIOStreams
```

## Dry run

The dry run does not install packages or create files, accounts, credentials, or containers:

```bash
sudo bash Install-AIOStreams.sh \
  --domain aio.example.com \
  --auth-host auth.aio.example.com \
  --email you@example.com \
  --public-ip 203.0.113.10 \
  --dry-run
```

The host must already provide `ss`, `getent`, `awk`, `grep`, `sort`, and `curl` for dry-run validation. A normal installation installs its required packages itself.

## Install

```bash
sudo bash Install-AIOStreams.sh \
  --domain aio.example.com \
  --auth-host auth.aio.example.com \
  --email you@example.com
```

The script prompts locally for:

- An AIOStreams proxy/API username
- An AIOStreams proxy/API password
- An Authelia login password

Passwords must contain at least 16 letters, numbers, dots, underscores, or hyphens. They are entered silently.

The Authelia credential protects the web configuration page. The separate `AIOSTREAMS_AUTH` credential protects AIOStreams proxy/API functionality; it is **not** a second dashboard login.

## Interrupted installations

The deployment is prepared in a temporary staging directory. Failures before validation remove that staging directory without publishing an incomplete `/opt/docker` tree.

After validation, an installer marker is written before the deployment is started. If an image pull, container startup, or health check then fails, fix the reported cause and run the same installer command again. An installer-managed `/opt/docker` deployment is detected and resumed without regenerating credentials or secrets.

The installer still refuses to alter an existing `/opt/docker` directory that does not contain its management marker.

## Service account

Containers that support a host UID/GID use a dedicated `aio` service account. The installer prefers UID/GID `1000`, then searches upward for the next number free as both a UID and GID. An existing `aio` account is reused only when it is a non-root `/usr/sbin/nologin` account with a same-named primary group.

Inspect the result with:

```bash
id aio
getent passwd aio
getent group aio
grep -E '^(PUID|PGID)=' /opt/docker/.env
```

## After installation

Open:

```text
https://aio.example.com/stremio/configure
```

Authenticate through Authelia using the Authelia username and password created during installation.

Useful diagnostics:

```bash
cd /opt/docker
docker compose config
docker compose ps -a
docker compose logs --tail=200
```

## Security and reliability

- The upstream template commit and required runtime image versions are pinned.
- Authelia and AIOStreams secrets are generated locally with OpenSSL.
- The Authelia password is stored only as an Argon2id hash.
- Sensitive environment and user files use mode `600`.
- Input values are validated before they are written to environment or YAML files.
- The unused TCP/853 listener and Traefik dashboard route are not published.
- Traefik discovers no containers and has no direct or proxied Docker socket access.
- The Authelia password is hashed through an interactive container terminal and never appears in process arguments.
- Compose configuration is validated before `/opt/docker` is created.
- Container health is checked during startup.
- CI checks shell syntax, ShellCheck findings, the pinned upstream template, and the rendered Compose model.

Protect SSH, TCP/80, and TCP/443 with the VPS provider firewall, and keep backups outside the VPS.

## Help

```bash
sudo bash Install-AIOStreams.sh --help
```

## Upstream template

https://github.com/Viren070/docker-compose-template

---

## Need a VPS?

> DediRock Promo VPS - New York: https://billing.dedirock.com/aff.php?aff=898&pid=264
>
> DediRock Promo VPS - Los Angeles: https://billing.dedirock.com/aff.php?aff=898&pid=265
>
> GreenCloudVPS: https://greencloudvps.com/billing/aff.php?aff=10195&gid=68

These are referral/affiliate links, which may provide me with a referral benefit if you sign up through them. Pricing and stock can change.