# Changelog

This project follows [Semantic Versioning](https://semver.org/). Each release
tag `vX.Y.Z` publishes the matching section below as its release notes.

## [0.1.0] - Unreleased

First public release.

- Single-node Redis 8.8 on Docker Compose with AOF and RDB persistence,
  `noeviction`, log rotation, and no published ports by default.
- Optional loopback-only host access for host-native applications.
- Per-project ACL users restricted to their own key and Pub/Sub namespace.
- Configurable memory limits through `.env`, with 1 GB VPS defaults
  (`256mb` dataset, `512m` container).
- Optional Restic backups to any repository (local, S3-compatible, B2, R2),
  restore, and a systemd timer.
- `install.sh` installer, `bin/update` with pre-update backup, automatic
  recovery on failed health checks, and `bin/update --rollback`.
