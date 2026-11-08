# Install-AIOStreams

> **Looking for a $10.88/year VPS?** Use my referral links:
>
> DediRock Promo VPS - New York: https://billing.dedirock.com/aff.php?aff=898&pid=264
>
> DediRock Promo VPS - Los Angeles: https://billing.dedirock.com/aff.php?aff=898&pid=265
>
> GreenCloudVPS: https://greencloudvps.com/billing/aff.php?aff=10195&gid=68
>
> These are referral/affiliate links, which may provide me with a referral benefit if you sign up through them. Pricing and stock can change.

Install script for a minimal AIOStreams Docker deployment on a fresh Ubuntu VPS. It installs only AIOStreams and Traefik, protects configuration creation with native AIOStreams login, generates secrets locally, validates the Compose model, and safely resumes interrupted deployment.

## Supported systems

- Ubuntu 26.04 (`resolute`)
- Ubuntu 24.04 (`noble`)
- Ubuntu 22.04 (`jammy`)
- A public IPv4 address
- Root or `sudo` access

The installer uses a reviewed, pinned revision of `Viren070/docker-compose-template`. AIOStreams itself intentionally tracks the upstream `latest` stable container so a fresh installation pulls the newest stable AIOStreams release available at install time. Traefik is pinned to an explicit version. There is no Authelia, Redis or PostgreSQL service. Traefik uses a generated file-provider configuration and has no access to the host Docker socket.

## Before running

1. Start with a fresh supported Ubuntu VPS.
2. Create **one** DNS A record for AIOStreams, pointing directly to the VPS public IPv4 address.
3. If using Cloudflare, keep the A record **DNS only (gray cloud)** for certificate issuance and renewal; this installer uses TLS-ALPN-01, which cannot validate behind orange-cloud.
4. Allow inbound TCP **443** (required for Let's Encrypt) and TCP **80** (HTTP redirects) in the Oracle/provider firewall and Ubuntu firewall. Confirm that 443 is reachable externally.
5. Ensure ports 80/443 are unused and `/opt/docker` does not contain an unrelated deployment.

The installer checks DNS against the VPS public IPv4. Use `--public-ip` when detection is unavailable; `--skip-dns-address-check` is for unusual network setups and can allow broken HTTPS.

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
  --email you@example.com \
  --public-ip 203.0.113.10 \
  --dry-run
```

The host must already provide `ss`, `getent`, `awk`, `grep`, `sort`, and `curl` for dry-run validation. A normal installation installs its required packages itself.

## Install

```bash
sudo bash Install-AIOStreams.sh \
  --domain aio.example.com \
  --email you@example.com
```

The installer prompts for:

- One administrator username of your choice (required; e.g. `user`, no preset default)
- One administrator password, entered silently

The password must be at least 16 characters and contain only letters, numbers, dots, underscores or hyphens. The installer configures `AIOSTREAMS_AUTH` with these credentials, explicitly grants `admin` using `AIOSTREAMS_AUTH_PERMISSIONS`, and sets `AIOSTREAMS_AUTH_REQUIRED=true`.

**No public registration is provided.** Only an authenticated administrator can create configurations and access the dashboard. One admin can create multiple configurations and save separate named profiles.

Credentials are stored in `/opt/docker/apps/aiostreams/.env` with file mode `600`; keep it private. The `--email` parameter is used only for the Let's Encrypt account, not an AIOStreams login email.

## AIOStreams version

Fresh installations use:

```text
ghcr.io/viren070/aiostreams:latest
```

This follows AIOStreams' upstream stable `latest` tag, not the `nightly` development tag. The image version installed depends on the upstream stable `latest` published at installation time.

Because `latest` can move when upstream publishes a new stable release, two fresh installations performed at different times may receive different AIOStreams versions. The installer explicitly writes the required `BASE_URL` and current operator permission format (`AIOSTREAMS_AUTH_PERMISSIONS`) for compatibility with current releases.

## Interrupted installations

The deployment is prepared in a temporary staging directory. Failures before validation remove that staging directory without publishing an incomplete `/opt/docker` tree.

After validation, an installer marker is written before the deployment is started. If an image pull, container startup, or health check then fails, fix the reported cause and run the same installer command again. An installer-managed `/opt/docker` deployment is detected and resumed without regenerating credentials or secrets.

The installer refuses to alter an unrelated `/opt/docker` directory and refuses to resume an older Authelia-based deployment. Back up and remove an older installation before reinstalling private-v2.

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

Open `https://aio.example.com/stremio/configure` (or your configured hostname). Sign in as the administrator and create your configurations. Use **Save as profile** to keep multiple named configurations under one account.

**Privacy:** The hostname is public, but the configuration page requires login, so anonymous visitors cannot create configurations. Stremio endpoints remain available when someone possesses a valid configuration URL, because Stremio needs that access. **Keep installation URLs private**: anyone with a valid URL may be able to use it.

First startup can take several minutes to prepare databases. The installer allows **600 seconds** for health checks.

Useful diagnostics:

```bash
cd /opt/docker
sudo docker compose config --services
sudo docker compose ps -a
sudo docker compose logs --tail=200 aiostreams traefik
```

Only `aiostreams` and `traefik` should appear. Traefik obtains certificates via TLS-ALPN-01, so keep the Cloudflare record DNS-only for renewals unless the deployment is converted to DNS-01.

## Uninstall

For new private-v2 deployments, stop the two containers while preserving all data:

```bash
sudo bash Uninstall-AIOStreams.sh
```

To stop, create and verify a private backup in `/root/aiostreams-backups/`, and remove `/opt/docker` (requires typing `PURGE`):

```bash
sudo bash Uninstall-AIOStreams.sh --purge
```

These commands keep Docker itself, cached images, the `aio` service account, DNS and firewall rules. The uninstaller refuses unexpected Compose services or legacy schema versions. Backups include credentials and TLS private keys; store them securely.

## Security and reliability

- Only AIOStreams and Traefik are included in the generated Compose model. Unused upstream template application directories are removed.
- `AIOSTREAMS_AUTH_REQUIRED=true` protects the configuration page and enables the configuration access-key gate.
- One explicit `admin` operator account has dashboard and configuration-creation permissions; no additional accounts are configured.
- Secrets are generated locally. Sensitive `.env` files use mode `600`.
- Only 80/443 are published; AIOStreams port 3000 remains internal.
- Traefik has no Docker socket, dashboard or TCP/853 listener.
- SQLite persists under `/opt/docker/data/aiostreams`; never rotate `SECRET_KEY` casually.
- CI checks shell syntax, ShellCheck, the pinned upstream template and the two-service Compose model.

Protect SSH, TCP/80, and TCP/443 with the VPS provider firewall, and keep backups outside the VPS.

## Help

```bash
sudo bash Install-AIOStreams.sh --help
sudo bash Uninstall-AIOStreams.sh --help
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