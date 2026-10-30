# Self-hosted Redis

A framework-neutral, single-node Redis service for Dockerized and host-native projects. Production is private to the `shared-services` Docker network by default; an optional override publishes Redis only on VPS loopback for applications running directly on the host. Each project has an ACL user restricted to its own key and Pub/Sub namespace.

This deployment has no replica or automatic failover. A VPS outage is a Redis outage. Optional Restic backups provide recovery; an off-server repository is needed for recovery from server loss.

## Quickstart

Install Docker Engine and Compose 2.24.0 or later, prepare the VPS, and choose how applications will connect. Follow the [getting started guide](docs/getting-started.md) for commands, including `vm.overcommit_memory` and Transparent Huge Pages settings. The default release install is:

```sh
curl -fsSL https://github.com/jccd-dev/self-hosted-redis/releases/latest/download/install.sh | sudo sh
```

The installer uses `/opt/self-hosted-redis`. For host-native applications, follow the guide's `--host-access` instructions.

## Local development

```sh
./bin/init development
docker compose -f compose.yaml -f compose.dev.yaml up -d redis
REDIS_ENV=development ./bin/project-user add example
REDIS_ENV=development ./bin/check
```

Development Redis listens only on `127.0.0.1:6379` and stores data in `self-hosted-redis-dev-data`. It uses the same configurable memory defaults as production.

## Sizing and configuration

Defaults work without an operator file. For a release install, enter a root shell and edit the existing ignored `.env`. If `.host-access` exists, add `-f compose.yaml -f compose.host-access.yaml` immediately after `docker compose` in all manual Compose commands in this README:

```sh
sudo -i
cd /opt/self-hosted-redis
sudo nano .env
```

Edit `REDIS_MAXMEMORY` (dataset limit), `REDIS_MEM_LIMIT` (total container memory), and `REDIS_MAXMEMORY_POLICY` (eviction policy). Redis accepts bytes or integer `k`, `kb`, `m`, `mb`, `g`, `gb` sizes; `mb` and `gb` use powers of 1024. Docker container limits use units such as `512m` or `1g`. Keep the dataset limit below the container limit. Shell environment variables override `.env` values, following [Compose interpolation rules](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/).

Suggested starting points, subject to workload testing:

| VPS RAM | `REDIS_MAXMEMORY` | `REDIS_MEM_LIMIT` |
| --- | --- | --- |
| 1 GB | `256mb` | `512m` |
| 2 GB | `512mb` | `1g` |
| 8 GB | `2gb` | `4g` |

The container also needs memory for clients, allocator overhead, and copy-on-write during RDB saves and AOF rewrites. These limits are starting budgets, not guaranteed capacity. Leave RAM for the OS, backups, and applications. Monitor actual usage, especially during write-heavy saves; a container reaching its memory limit can be killed even before Redis reaches its dataset limit. The 1 GB target has not been soak-tested on a real VPS.

Apply changes with `sudo docker compose up -d redis`, then run `sudo ./bin/check` from `/opt/self-hosted-redis` in the root shell. For development, include `-f compose.yaml -f compose.dev.yaml` and use `REDIS_ENV=development ./bin/check`. The check compares live Redis settings with its deployed container configuration; editing `.env` alone does not update a running container.

**Existing deployments:** before recreating Redis, set `.env` to your current limits. The previous defaults were `REDIS_MAXMEMORY=2gb` and `REDIS_MEM_LIMIT=2560m`. Without explicit values, recreation applies the new `256mb` / `512m` defaults. Take a backup and inspect current usage before reducing limits; `noeviction` rejects writes when full, while eviction policies can delete keys.

Production host access remains opt-in: include `-f compose.yaml -f compose.host-access.yaml` in deployment commands to publish only `127.0.0.1:6379`. Omit the host-access override and recreate the service to disable it. See the [host-native guide](docs/laravel-vps-guide.md).

## Production deployment

For release installation, updates, and rollback, see the [getting started guide](docs/getting-started.md).

### Advanced: manual Git checkout

For the manual Compose path, install the repository at `/opt/self-hosted-redis`, then initialize the private Docker network and credentials:

```sh
sudo -i
cd /opt/self-hosted-redis
sudo docker network create shared-services
sudo ./bin/init production
sudo docker compose up -d redis
sudo ./bin/check
sudo ./bin/project-user add example
```

Run `docker network create` only once. Other Compose projects connect to Redis by joining `shared-services` and using hostname `redis`. See the recipes in [docs/client-recipes](docs/client-recipes/docker.md).

`project-user add` and `project-user rotate` print the password once. Copy the result directly into that project's secret manager. Redis stores only the password hash in `secrets/production/users.acl`.

```sh
sudo ./bin/project-user add project-name
sudo ./bin/project-user rotate project-name
sudo ./bin/project-user remove project-name
```

Valid project slugs are lowercase, start with a letter, contain only letters, digits, and hyphens, and are at most 32 characters. Every client must use the emitted `<slug>:` prefix for keys and Pub/Sub channels.

Project users cannot read or write other projects' keys or channels, or manage server-wide functions and scripts. `SCAN` and `DBSIZE` stay allowed for client compatibility, so a project can see other projects' key names and the total key count, but not their values. Avoid putting secrets in key names.

## Optional backups

Backups are off by default. In a root shell, from `/opt/self-hosted-redis`, configure a local repository with:

```sh
sudo cp backup.env.example secrets/production/backup.env
sudo chmod 600 secrets/production/backup.env
sudo ./bin/backup-init
sudo ./bin/backup
```

The local `self-hosted-redis-local-restic` volume shares the server's failure risk. Keep a secure copy of `secrets/production/restic-password` outside the VPS; losing it prevents recovery. For an off-server repository, see the [backup guide](docs/backups.md). A Cloudflare R2 token needs Object Read & Write access limited to the dedicated bucket.

### Daily systemd timer

After configuring and testing a backup repository, optionally enable the supplied timer. From a root shell in `/opt/self-hosted-redis`:

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

From a root shell in `/opt/self-hosted-redis`, list snapshots and stop Redis before restoring:

```sh
sudo env RESTIC_ENV_FILE=secrets/production/backup.env docker compose --profile tools run --rm restic snapshots
sudo docker compose stop redis
sudo ./bin/restore <snapshot-id> --confirm
sudo ./bin/check
```

Restore downloads only `dump.rdb` into a staging volume, validates it with `redis-check-rdb`, and copies the current Redis volume into a timestamped safety directory in staging. It loads the restored RDB in a temporary Redis container with AOF disabled, enables AOF, and waits for a successful rewrite before restarting the existing service with its deployed port mappings and settings. Keep the safety copy until application checks pass; later restores preserve earlier safety directories. A restore intentionally discards the old AOF after preserving it because Redis would otherwise replay newer data over the restored RDB.

Perform this drill after initial deployment and periodically thereafter. A backup that has never been restored is not verified recovery.

## Operations

Enter a root shell with `sudo -i`, then `cd /opt/self-hosted-redis`. If `.host-access` exists, add `-f compose.yaml -f compose.host-access.yaml` immediately after `docker compose` in every manual Compose command below and in the sizing, backup, and restore commands above. Project scripts select the override automatically.

- Check service state: `sudo ./bin/check`
- Inspect memory: `sudo docker compose exec redis redis-cli --user admin --askpass INFO memory`
- Inspect persistence: `sudo docker compose exec redis redis-cli --user admin --askpass INFO persistence`
- View logs: `sudo docker compose logs --tail=200 redis`
- Upgrade release installs: `sudo ./bin/update [vX.Y.Z]`; see [updates and rollback](docs/releases.md)

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

Release lifecycle tests also use a privileged disposable Linux Docker daemon, isolated from host production volumes. See [release verification](docs/releases.md#verification). GitHub Actions runs the suite on pushes to `main` and on pull requests.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CHANGELOG.md](CHANGELOG.md). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
