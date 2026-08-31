# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-08-31

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Security

- **Ghost bumped 5.94 → 6.61.0** (major bump; Ghost migrates its database
  forward on first start — back up before pulling). **Traefik bumped
  3.2 → 3.7** (3.2's Docker client cannot talk to Docker Engine 29).
- **All three images pinned by `tag@sha256:digest`** (`mysql:8.4-oracle`
  digest-pinned).
- **Credentials untracked from git.** The tracked `.env` carried
  generated-looking database passwords published on GitHub — rotate them
  if reused. `.env` is now gitignored; compose fails fast on unset values.

### Changed

- **Image pins live in the compose file as interpolation defaults**
  (`x-images` block); `.env` carries only secrets, hostnames, and
  deliberate overrides. Backup-loop variables escaped (`$$VAR`).
- README rebuilt to the fleet evaluator-first structure.

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; Trivy
  scans of all three pinned images; weekly `check-pin-freshness` (digest
  drift + Ghost and Traefik release lag); deploy-and-test that boots the
  full stack with ephemeral credentials and requires the front page to
  answer 200 through Traefik.

### Fixed

- Shellcheck findings in both restore scripts.

[Unreleased]: https://github.com/heyvaldemar/ghost-traefik-letsencrypt-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/ghost-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
