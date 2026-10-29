# Self-hosted Redis

A framework-neutral, single-node Redis service for Dockerized and host-native projects. Production is private to the `shared-services` Docker network by default; an optional override publishes Redis only on VPS loopback for applications running directly on the host. Each project has an ACL user restricted to its own key and Pub/Sub namespace.

This deployment has no replica or automatic failover. A VPS outage is a Redis outage. Restic backups in Cloudflare R2 provide disaster recovery, not high availability.

## Requirements

- Linux VPS with Docker Engine, Docker Compose v2, and systemd
- 8 GB RAM recommended for the configured 2 GB Redis dataset limit
- OpenSSL on the host for credential generation
- A dedicated Cloudflare R2 bucket and bucket-scoped S3 credentials

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

Development Redis listens only on `127.0.0.1:6379`, uses a 256 MB dataset limit, and stores data in `self-hosted-redis-dev-data`.

## Production deployment

Install the repository at `/opt/self-hosted-redis`, then initialize the private Docker network and credentials:

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

## Cloudflare R2 backup

In Cloudflare, create an R2 S3 API token with **Object Read & Write** access limited to the dedicated Redis backup bucket. Do not use an account-wide token.

Create a temporary mode-`0600` bootstrap file from `.env.example`, fill in the account ID, bucket, Access Key ID, and Secret Access Key, then initialize Restic:

```sh
cp .env.example secrets/production/r2-bootstrap.env
chmod 600 secrets/production/r2-bootstrap.env
set -a
. ./secrets/production/r2-bootstrap.env
set +a
./bin/backup-init
```

After successful initialization, remove `r2-bootstrap.env`. The command writes the required values to ignored `secrets/production/r2.env`; it never prints credentials. Store a separate secure copy of `secrets/production/restic-password` outside the VPS. R2 data cannot be restored without it.

Run and inspect a manual backup:

```sh
./bin/backup
docker compose --env-file secrets/production/r2.env --profile tools run --rm restic snapshots
docker compose --env-file secrets/production/r2.env --profile tools run --rm restic check
```

Backups request a fresh RDB snapshot before uploading. Restic encrypts the snapshot and retains 7 daily, 4 weekly, and 6 monthly versions.

### Daily systemd timer

The supplied unit expects the repository at `/opt/self-hosted-redis`:

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
docker compose --env-file secrets/production/r2.env --profile tools run --rm restic snapshots
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
- Upgrade: update the pinned patch tag, review release notes, run tests, take a backup, pull, and recreate Redis

The `noeviction` policy protects queues, sessions, streams, and other non-disposable data from silent deletion. When the 2 GB dataset limit is reached, writes fail. Alert before `used_memory` approaches the limit and scale or separate workloads rather than changing to an eviction policy blindly.

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

Static and unit tests do not need R2. Docker integration tests use a temporary checkout, unique test-scoped containers, networks, volumes, and an ephemeral loopback port. Test credentials, data, and Docker resources are removed afterward. The R2 integration check is opt-in and uses `secrets/production/r2.env`.
