# Ghost + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/ghost-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/ghost-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [Why this stack?](#why-this-stack)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [Features](#features)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Backups](#backups)
- [Testing](#testing)
- [Security Notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

This repository deploys **Ghost** behind **Traefik** with automatic **Let's Encrypt TLS**, backed by **MySQL 8.4**, with scheduled **backups** (database + content) and companion **restore scripts**. One `docker compose up` away from a publishing platform at `https://your-domain`.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-ghost-using-docker-compose/](https://www.heyvaldemar.com/install-ghost-using-docker-compose/).

## Why this stack?

| Need | This stack | Manual install | Ghost(Pro) | Other compose examples |
|------|-----------|----------------|-----------|------------------------|
| Ready to deploy in <10 min | ✅ | ❌ ghost-cli + node + nginx | ✅ hosted | Often |
| TLS via Let's Encrypt, auto-renewed | ✅ Traefik ACME built-in | Manual certbot | ✅ | Rare |
| MySQL 8 wired with healthchecks | ✅ | Separate install | Managed | Varies |
| Scheduled DB + content backups + pruning | ✅ | Manual cron | Managed | Rare |
| Restore scripts included | ✅ two scripts | Manual | Support ticket | Rare |
| Upstream images pinned by `sha256` digest | ✅ | N/A | N/A | Rare |
| Weekly pin-freshness check in CI | ✅ | N/A | N/A | Rare |
| CI-verified deployment on every push | ✅ | N/A | N/A | Rare |
| Own your content and your bill | ✅ | ✅ | ❌ subscription | ✅ |

Four moving parts (Traefik + Ghost + MySQL + backups). No Kubernetes prerequisites, no manual certificate management.

## Prerequisites

- **A Linux server** with a public IP. Tested on Ubuntu 22.04 LTS+ and Debian 12+.
- **Docker Engine 24+ and Docker Compose 2.20+.**
- **A domain you control,** with two `A` records pointing at your server's public IP — one for Ghost, one for the Traefik dashboard. DNS must propagate before deploy.
- **Ports 80 and 443 open** on the server's firewall.
- **~1 GB free RAM** for the running stack, plus disk for images/content and backups.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/ghost-traefik-letsencrypt-docker-compose
cd ghost-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create ghost-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: GHOST_DB_PASSWORD, GHOST_DB_ADMIN_PASSWORD, GHOST_HOSTNAME,
#   GHOST_URL, TRAEFIK_HOSTNAME, TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.

# 4. Deploy
docker compose -f ghost-traefik-letsencrypt-docker-compose.yml -p ghost up -d
```

Within a minute `https://${GHOST_HOSTNAME}` serves your blog with a fresh Let's Encrypt certificate. **Create the admin account right away** at `https://${GHOST_HOSTNAME}/ghost` — the setup screen is open until someone claims it.

### What success looks like

```bash
# All services healthy:
docker compose -f ghost-traefik-letsencrypt-docker-compose.yml -p ghost ps

# Front page answers:
curl -fskL -o /dev/null -w "%{http_code}\n" "https://${GHOST_HOSTNAME}/"
# Expected: 200

# Traefik issued a certificate:
docker compose -p ghost logs traefik | grep -i "adding certificate"

# First backup lands after BACKUP_INIT_SLEEP (default 30m):
docker compose -p ghost logs backups | tail -3
```

### Common first-deploy issues

- **Cert issuance fails.** DNS hasn't propagated or port 80 isn't reachable from the internet.
- **`docker compose up` fails with `set in .env`.** A required variable is empty; the error names it.
- **`network ghost-network not found`.** Step 2 was skipped.
- **Redirect loops.** `GHOST_URL` must exactly match the public URL including `https://`.

### Apply `.env` or compose-file changes

```bash
docker compose -f ghost-traefik-letsencrypt-docker-compose.yml -p ghost up -d --force-recreate
```

## Features

- **Ghost 6** — posts, pages, memberships, newsletters, native SEO.
- **MySQL 8.4 LTS** backing store with healthcheck and start-order dependency.
- **Traefik v3** with automatic HTTP→HTTPS redirect and Let's Encrypt TLS-ALPN certificate issuance.
- **Basic-auth protected Traefik dashboard** on a separate hostname.
- **Scheduled backups** of the database (`mysqldump | gzip`) and the content directory (themes, images) with retention pruning, plus restore scripts for both.
- **Credentials required at deploy time** — compose fails fast if `.env` is incomplete.

## Supply chain trust

This repository is a **deployment template**, not a custom Docker image. It orchestrates three upstream images:

- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, Docker Hub official image
- [`ghost`](https://hub.docker.com/_/ghost) — Ghost, Docker Hub official image
- [`mysql`](https://hub.docker.com/_/mysql) — MySQL, Docker Hub official image

All three are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block — `git pull` alone delivers the version combination this repository has tested; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

The daily `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned Ghost and Traefik versions against the latest upstream releases. CI runs on every push, pull request, and every day at 06:00 UTC. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Production checklist

- [ ] **Claim the admin account immediately** at `/ghost` — the setup screen is first-come-first-served.
- [ ] **Strong secrets.** Both database passwords at 24+ random characters; regenerate the Traefik dashboard BCrypt hash per deployment.
- [ ] **Configure mail in Ghost** (Settings → Email newsletter) if you use memberships/newsletters.
- [ ] **Host-mount the backup volumes** for disaster recovery.
- [ ] **Verify Let's Encrypt cert issuance** in the Traefik logs on first start.
- [ ] **Back up before upgrades** — Ghost migrates its schema forward automatically; the way back is a restore.

## Backups

The `backups` container performs a dump → archive → prune → sleep loop: `mysqldump | gzip` of the Ghost database, `tar.gz` of the content directory, pruning by retention windows, then sleeping `BACKUP_INTERVAL` (default 24h).

Each cycle logs `Database backup OK: <file> (<bytes> bytes)` or `Database backup FAILED` (the same for the data archive where there is one). A failed dump is kept as `<file>.failed` for diagnosis and never overwrites a good backup — grep the log for `FAILED` from your monitoring.

**Verify backups are running:**

```bash
docker compose -p ghost logs backups | tail -5
```

**Restore** with the interactive scripts (`chmod +x *.sh` once): `./ghost-restore-database.sh`, then `./ghost-restore-application-data.sh`.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults — the same values CI boots the stack under. Override any of them in `.env` (the knobs and their defaults are listed in `.env.example`, e.g. `TRAEFIK_MEMORY_LIMIT=512m`) and the override survives every `git pull`. If a service is OOM-killed under real load, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so; raise its `_MEMORY_LIMIT` and recreate.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`, so a process cannot gain privileges through setuid binaries even if it escapes its initial capability set. Infrastructure containers (the reverse proxy, databases, caches, backups) run with `cap_drop: [ALL]` and add back only what their entrypoints need: `NET_BIND_SERVICE` for Traefik to bind :80/:443, `CHOWN`/`SETUID`/`SETGID` (and friends) for database images to own their data directory and drop to their service user. Application containers keep the default capability set on purpose: upstream images assume it, and a wrong guess there is a boot loop in production rather than a hardening win. CI boots the stack under exactly these settings on every push, so what ships is what was tested.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/ghost-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC:

1. **Lint** — shellcheck on both restore scripts, actionlint on the workflow.
2. **Trivy scans** of all three pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Pin freshness** (daily/manual) — digest drift plus release-lag checks for Ghost and Traefik.
4. **Deploy-and-test** — boots the full stack with ephemeral credentials and requires the front page to answer 200 through Traefik.

A green run is the authoritative proof that the template deploys end-to-end and that its backups restore.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the HTTPS smoke. The scenario that matters most is the restore roundtrip: insert a marker row, restore the earliest backup, assert the marker is gone — a backup that cannot be restored fails the build. Run it yourself against a running deployment with short intervals in `.env` (`BACKUP_INIT_SLEEP=15s`, `BACKUP_INTERVAL=60s`):

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

It stops the database container briefly to prove failure detection — run it on a staging copy, not on production.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- **Pre-rotation advisory.** Releases before v1.0.0 (2026-08-31) shipped a tracked `.env` with generated-looking database passwords. Rotate them if your deployment reused them.
- MySQL listens only on the internal network.
- Upstream image digests are pinned; the daily freshness job flags drift loudly.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
