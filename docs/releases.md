# Release installation and updates

The installer targets Linux with Docker Engine, Docker Compose 2.24.0 or later,
OpenSSL, curl, GNU tar, and sha256sum. Run installation and updates as root
(for example, pipe the downloaded installer to `sudo sh`). Root access keeps
management commands able to read private credentials after ACL ownership is
assigned to the container’s Redis user. Run the installed operation scripts
with `sudo` too. It prints advice for memory
overcommit and Transparent Huge Pages; it does not change host settings.

Release downloads use `jccd-dev/self-hosted-redis`. The repository rename,
published assets, and public curl installation are Phase 5 work. Until those
exist, the following commands describe the release interface and will fail to
download a release.

```sh
curl -fsSL https://github.com/jccd-dev/self-hosted-redis/releases/latest/download/install.sh | sudo sh
```

For a pinned release or host-native clients:

```sh
curl -fsSL https://github.com/jccd-dev/self-hosted-redis/releases/download/v0.1.0/install.sh |
  sudo sh -s -- --version v0.1.0 --host-access
```

The default directory is `/opt/self-hosted-redis`; `--prefix /absolute/path`
changes it. An existing destination or production data volume is rejected to
avoid initializing new credentials over an existing deployment. Failed initial
installs retain their directory and credentials for inspection. Resolve the
reported problem and complete the documented manual startup; do not delete
existing secrets or volumes to retry.

Installation creates `.env` from its example, generates production credentials,
creates the private `shared-services` network if needed, pulls Redis, starts it,
and runs `bin/check`. It does not enable backups or install a systemd timer.
`--host-access` records an ignored `.host-access` marker so operation scripts
and updates keep the supplied loopback override. Manual Docker Compose commands
still need `-f compose.yaml -f compose.host-access.yaml` when using that marker.

## Update and rollback

```sh
cd /opt/self-hosted-redis
sudo ./bin/update             # latest published release
sudo ./bin/update v0.2.0      # pinned release
sudo ./bin/update --rollback  # previous code, same data and credentials
```

Use this command for production release installs. Git checkouts and deployments
with custom Compose overrides require manual updates. The supplied host-access
override is supported and detected on existing containers. Preserve current
sizing in `.env` before adopting lower defaults, as described in the README.

An update verifies the download, checks the current service, and runs a backup
when `backup.env`, legacy `r2.env`, or explicit `RESTIC_ENV_FILE` configures one.
A missing explicit file or failed backup stops the update before service changes.
Unconfigured backups remain off. The staged Compose configuration and image pull
must succeed before Redis is stopped. Updates briefly interrupt service.

The updater replaces shipped code in place and recreates Redis. It preserves
`secrets/`, `.env`, `.host-access`, the installation path, and all Docker data
volumes. The previous code is retained as `.previous.tar.gz` with private
permissions. A failed startup or health check attempts to restore that code and
restart Redis, returning failure even when recovery succeeds. Check the output
and `docker compose logs redis` if recovery fails. An interrupted process can
leave `.update-lock`; verify no updater is running before removing that empty
directory with `rmdir .update-lock`.

Rollback swaps the current and previous code; it does not restore data. Redis
image upgrades must remain compatible with the existing on-disk format. Review
release notes before upgrading; recover incompatible data through a verified
backup and the documented restore procedure. A code rollback cannot reverse
writes or a Redis data-format migration. Keep off-server backups for server loss.

## Release asset contract

Phase 5 packaging must publish these assets for each `vX.Y.Z` tag:

- `install.sh`: the standalone installer.
- `self-hosted-redis.tar.gz`: one `self-hosted-redis/` directory containing
  `VERSION` (`X.Y.Z`), `install.sh`, `bin/`, `lib/`, `config/`, `docs/`, `systemd/`,
  the three Compose files, README, and `.env.example`, `backup.env.example`,
  `r2.env.example`.
- `self-hosted-redis.tar.gz.sha256`: the archive's SHA-256 digest, optionally
  followed by its filename, as emitted by `sha256sum`.

Exclude operator state, secrets, Git metadata, symlinks, and special files.
Checksums detect corruption; their authenticity depends on the trusted HTTPS
release origin. Release code runs with the operator's Docker authority.

For offline fixtures or a trusted release mirror, set
`SELF_HOSTED_REDIS_RELEASE_URL` to the releases root. HTTPS and local `file://`
URLs are supported; HTTPS redirects must stay on HTTPS. The paths are
`latest/download/<asset>` or `download/vX.Y.Z/<asset>`.

## Verification

`tests/releases.sh` exercises the public CLI with local release archives and a
fake Docker boundary for failure cases. `tests/release-integration.sh` uses a
privileged disposable `docker:29-dind` container with its own daemon, no host
Docker socket, and local release fixtures. It checks fresh installation,
update, data/ACL/configuration/host-port preservation, local Restic backup,
rollback, and recovery from a failed health check. Its containers, nested
volumes, secrets, and fixture data are removed with the disposable daemon.
The test requires network access to pull images and install Linux tools. It
does not test published GitHub assets or a low-memory VPS.
