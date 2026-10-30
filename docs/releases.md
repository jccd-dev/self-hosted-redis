# Release installation and updates

For installation, host preparation, connecting applications, and troubleshooting, follow the [getting started guide](getting-started.md). Release downloads use `jccd-dev/self-hosted-redis`.

For a pinned release with host-native access:

```sh
curl -fsSL https://github.com/jccd-dev/self-hosted-redis/releases/download/v0.1.0/install.sh |
  sudo sh -s -- --version v0.1.0 --host-access
```

The default directory is `/opt/self-hosted-redis`; `--prefix /absolute/path` changes it. Existing destinations and production data volumes are rejected. Failed initial installs retain their files for inspection. The installer does not enable backups or install a timer.

## Update and rollback

```sh
sudo -i
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
volumes. After a successful update, the previous code is retained as
`.previous.tar.gz` with private permissions. Requesting the installed version
changes nothing. A failed startup or health check attempts to restore the
previous code and restart Redis, returning failure even when recovery succeeds;
the existing rollback target is kept. If recovery fails, the previous code is in
`.previous.tar.gz.tmp`; check the output and `sudo docker compose logs redis` (include `-f compose.yaml -f compose.host-access.yaml` after `docker compose` if `.host-access` exists). An interrupted process can
leave `.update-lock`; verify no updater is running before removing that empty
directory with `rmdir .update-lock`.

Rollback swaps the current and previous code; it does not restore data. Redis
image upgrades must remain compatible with the existing on-disk format. Review
release notes before upgrading; recover incompatible data through a verified
backup and the documented restore procedure. A code rollback cannot reverse
writes or a Redis data-format migration. Keep off-server backups for server loss.

## Maintainer information

### Release asset contract

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`. It runs the test
suite, builds the assets with `scripts/package-release.sh`, and publishes them
with the matching `CHANGELOG.md` section as release notes. Packaging fails when
the tag differs from `VERSION` or the changelog entry is undated. Each release
publishes:

- `install.sh`: the standalone installer.
- `self-hosted-redis.tar.gz`: one `self-hosted-redis/` directory containing
  `VERSION` (`X.Y.Z`), `LICENSE`, `install.sh`, `bin/`, `lib/`, `config/`, `docs/`, `systemd/`,
  the three Compose files, README, and `.env.example`, `backup.env.example`,
  `r2.env.example`.
- `self-hosted-redis.tar.gz.sha256`: the archive's SHA-256 digest, optionally
  followed by its filename, as emitted by `sha256sum`.

Only files Git tracks or would track are packaged, so ignored operator state,
secrets, and editor files stay out. Packaging rejects symlinks and special files.
Checksums detect corruption; their authenticity depends on the trusted HTTPS
release origin. Release code runs with the operator's Docker authority.

For offline fixtures or a trusted release mirror, set
`SELF_HOSTED_REDIS_RELEASE_URL` to the releases root. HTTPS and local `file://`
URLs are supported; HTTPS redirects must stay on HTTPS. The paths are
`latest/download/<asset>` or `download/vX.Y.Z/<asset>`.

### Verification

`tests/releases.sh` exercises the public CLI with local release archives and a
fake Docker boundary for failure cases. `tests/release-integration.sh` uses a
privileged disposable `docker:29-dind` container with its own daemon, no host
Docker socket, and local release fixtures. It checks fresh installation,
update, data/ACL/configuration/host-port preservation, local Restic backup,
rollback, and recovery from a failed health check. Its containers, nested
volumes, secrets, and fixture data are removed with the disposable daemon.
The test requires network access to pull images and install Linux tools. It
does not test published GitHub assets or a low-memory VPS.
