# Self-hosted Redis

A framework-neutral, single-node Redis service for Dockerized and host-native projects. Production is private to the `shared-services` Docker network by default; an optional override publishes Redis only on VPS loopback for applications running directly on the host. Each project has an ACL user restricted to its own key and Pub/Sub namespace.

This deployment has no replica or automatic failover. A VPS outage is a Redis outage. Optional Restic backups provide recovery; an off-server repository is needed for recovery from server loss.

## Requirements

- Linux VPS with Docker Engine, Docker Compose 2.24.0 or later, and systemd for the optional backup timer
- 1 GB RAM starting target with a 256 MiB dataset limit; size for the other applications sharing the VPS
- OpenSSL on the host for credential generation
- No cloud account is needed to run Redis; backups are optional

On the VPS, enable Redis's required memory-overcommit setting and persist it using your distribution's sysctl configuration:

```sh
sudo sysctl vm.overcommit_memory=1
```

Disable Transparent Huge Pages using the distribution's supported boot or systemd mechanism. Keep TCP port `6379` closed in the VPS firewall; production Compose does not publish it.

## Local development

```sh
./bin/init development
docker compose -f compose.yaml -f compose.dev.yaml up -d redis
REDIS_ENV=development ./bin/project-user add example
REDIS_ENV=development ./bin/check
```

Development Redis listens only on `127.0.0.1:6379` and stores data in `self-hosted-redis-dev-data`. It uses the same configurable memory defaults as production.

## Sizing and configuration

Defaults work without an operator file. To customize them, copy `.env.example` to the ignored `.env` in the repository root:

```sh
cp .env.example .env
```

Edit `REDIS_MAXMEMORY` (dataset limit), `REDIS_MEM_LIMIT` (total container memory), and `REDIS_MAXMEMORY_POLICY` (eviction policy). Redis accepts bytes or integer `k`, `kb`, `m`, `mb`, `g`, `gb` sizes; `mb` and `gb` use powers of 1024. Docker container limits use units such as `512m` or `1g`. Keep the dataset limit below the container limit. Shell environment variables override `.env` values, following [Compose interpolation rules](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/).

Suggested starting points, subject to workload testing:

| VPS RAM | `REDIS_MAXMEMORY` | `REDIS_MEM_LIMIT` |
| --- | --- | --- |
| 1 GB | `256mb` | `512m` |
| 2 GB | `512mb` | `1g` |
| 8 GB | `2gb` | `4g` |

The container also needs memory for clients, allocator overhead, and copy-on-write during RDB saves and AOF rewrites. These limits are starting budgets, not guaranteed capacity. Leave RAM for the OS, backups, and applications. Monitor actual usage, especially during write-heavy saves; a container reaching its memory limit can be killed even before Redis reaches its dataset limit. The 1 GB target has not been soak-tested on a real VPS.

Apply changes with `docker compose up -d redis`, then run `./bin/check`. For development, include `-f compose.yaml -f compose.dev.yaml` and use `REDIS_ENV=development ./bin/check`. The check compares live Redis settings with its deployed container configuration; editing `.env` alone does not update a running container.

**Existing deployments:** before recreating Redis, set `.env` to your current limits. The previous defaults were `REDIS_MAXMEMORY=2gb` and `REDIS_MEM_LIMIT=2560m`. Without explicit values, recreation applies the new `256mb` / `512m` defaults. Take a backup and inspect current usage before reducing limits; `noeviction` rejects writes when full, while eviction policies can delete keys.

Production host access remains opt-in: include `-f compose.yaml -f compose.host-access.yaml` in deployment commands to publish only `127.0.0.1:6379`. Omit the host-access override and recreate the service to disable it. See the [host-native guide](docs/laravel-vps-guide.md).

## Production deployment

For release installation, updates, and rollback, see [the release guide](docs/releases.md). Public release assets are pending Phase 5.

For the manual Compose path, install the repository at `/opt/self-hosted-redis`, then initialize the private Docker network and credentials:

```sh
cd /opt/self-hosted-redis
docker network create shared-services
./bin/init production
docker compose up -d redis
./bin/check
./bin/project-user add example
```

Run `docker network create` only once. Other Compose projects connect to Redis by joining `shared-services` and using hostname `redis`. See the recipes in [docs/client-recipes](docs/client-recipes/docker.md).

`project-user add` and `project-user rotate` print the password once. Copy the result directly into that project's secret manager. Redis stores only the password hash in `secrets/production/users.acl`.

```sh
./bin/project-user add project-name
./bin/project-user rotate project-name
./bin/project-user remove project-name
```

Valid project slugs are lowercase, start with a letter, contain only letters, digits, and hyphens, and are at most 32 characters. Every client must use the emitted `<slug>:` prefix for keys and Pub/Sub channels.

## Optional backups

Backups are off by default: no repository is configured and no timer is installed or enabled automatically. Redis initialization and startup need no cloud credentials. To opt in, create a mode-`0600` `secrets/production/backup.env` with a Restic repository and its provider credentials, then run `./bin/backup-init`. Backup commands fail with an explanation when configuration is missing; they do not contact Docker or a storage provider.

For a local repository with no cloud account:

```sh
cp backup.env.example secrets/production/backup.env
chmod 600 secrets/production/backup.env
./bin/backup-init
./bin/backup
```

The example stores encrypted backups in the persistent `self-hosted-redis-local-restic` Docker volume at `/local-backup/repository` inside the tool container. Local backups share the server's failure risk. See [backup configuration and provider recipes](docs/backups.md) for S3, B2, R2, development use, and existing repositories. Keep a secure copy of `secrets/production/restic-password` outside the VPS; losing it prevents recovery.

### Cloudflare R2 recipe

In Cloudflare, create an R2 S3 API token with **Object Read & Write** access limited to the dedicated Redis backup bucket. Do not use an account-wide token.

Create a temporary mode-`0600` bootstrap file from `r2.env.example`, fill in the account ID, bucket, Access Key ID, and Secret Access Key, then initialize Restic:

```sh
cp r2.env.example secrets/production/r2-bootstrap.env
chmod 600 secrets/production/r2-bootstrap.env
set -a
. ./secrets/production/r2-bootstrap.env
set +a
./bin/backup-init
```

After successful initialization, remove `r2-bootstrap.env` and unset the exported R2 variables. The command writes the required values to ignored `secrets/production/backup.env`; it never prints credentials. Existing `r2.env` configurations remain supported when `backup.env` is absent, and are updated in place when using this bootstrap recipe.

Run and inspect a manual backup:

```sh
./bin/backup
RESTIC_ENV_FILE=secrets/production/backup.env docker compose --profile tools run --rm restic snapshots
RESTIC_ENV_FILE=secrets/production/backup.env docker compose --profile tools run --rm restic check
```

Backups request a fresh RDB snapshot before uploading. Restic encrypts the snapshot and retains 7 daily, 4 weekly, and 6 monthly versions.

### Daily systemd timer

After configuring and testing a backup repository, optionally enable the supplied timer. It expects the repository at `/opt/self-hosted-redis`:

```sh
sudo cp systemd/self-hosted-redis-backup.service /etc/systemd/system/
sudo cp systemd/self-hosted-redis-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now self-hosted-redis-backup.timer
sudo systemctl start self-hosted-redis-backup.service
sudo journalctl -u self-hosted-redis-backup.service
```

The timer runs daily with up to one hour of randomized delay and catches up after downtime.

## Restore drill

List snapshots and stop Redis before restoring:

```sh
RESTIC_ENV_FILE=secrets/production/backup.env docker compose --profile tools run --rm restic snapshots
docker compose stop redis
./bin/restore <snapshot-id> --confirm
./bin/check
```

Restore downloads only `dump.rdb` into a staging volume, validates it with `redis-check-rdb`, and copies the current Redis volume into a timestamped safety directory in staging. It loads the restored RDB in a temporary Redis container with AOF disabled, enables AOF, and waits for a successful rewrite before restarting the existing service with its deployed port mappings and settings. Keep the safety copy until application checks pass; later restores preserve earlier safety directories. A restore intentionally discards the old AOF after preserving it because Redis would otherwise replay newer data over the restored RDB.

Perform this drill after initial deployment and periodically thereafter. A backup that has never been restored is not verified recovery.

## Operations

- Check service state: `./bin/check`
- Inspect memory: `docker compose exec redis redis-cli --user admin --askpass INFO memory`
- Inspect persistence: `docker compose exec redis redis-cli --user admin --askpass INFO persistence`
- View logs: `docker compose logs --tail=200 redis`
- Upgrade release installs: `./bin/update [vX.Y.Z]`; see [updates and rollback](docs/releases.md)

The default `noeviction` policy protects queues, sessions, streams, and other non-disposable data from silent deletion. When the configured dataset limit is reached, writes fail. Alert before `used_memory` approaches the limit and scale or separate workloads rather than changing to an eviction policy blindly.

## Client recipes

- [Generic Docker](docs/client-recipes/docker.md)
- [Node.js / ioredis](docs/client-recipes/node.md)
- [Python / redis-py](docs/client-recipes/python.md)
- [Laravel and Pulse](docs/client-recipes/laravel.md)
- [Complete Laravel VPS guide: host-native and Dockerized](docs/laravel-vps-guide.md)

## Tests

Install [ShellCheck](https://www.shellcheck.net/) and Docker Compose v2 before running the suite.

```sh
./tests/run.sh
```

Static and unit tests do not need R2. Docker integration tests use a temporary checkout, unique test-scoped containers, networks, volumes, and an ephemeral loopback port. They verify startup without backup configuration and a local backup/restore without cloud credentials. Test credentials, data, and Docker resources are removed afterward. The R2 integration check is opt-in and uses `RESTIC_ENV_FILE` or the production backup configuration (including legacy `r2.env`).

Release lifecycle tests also use a privileged disposable Linux Docker daemon, isolated from host production volumes. See [release verification](docs/releases.md#verification).
