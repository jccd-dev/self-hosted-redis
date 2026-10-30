# Getting started on a VPS

This guide installs the published release at `/opt/self-hosted-redis`. The commands assume an Ubuntu or Debian VPS with systemd and a user who can run `sudo`. Redis is a single service without automatic failover. Backups are optional; use an off-server repository to recover from server loss.

## Prerequisites

Install Docker Engine and its Compose plugin using Docker's instructions for [Ubuntu](https://docs.docker.com/engine/install/ubuntu/) or [Debian](https://docs.docker.com/engine/install/debian/). Install `curl`, `openssl`, GNU `tar`, and `sha256sum` if they are missing. Verify Docker and Compose:

```sh
sudo docker info
sudo docker compose version
```

Compose must be version 2.24.0 or later. A 1 GB VPS with a 256 MiB Redis dataset limit is a starting target; leave memory for the OS and other apps. This target has not been soak-tested on a real VPS.

## Prepare the host

Persist Redis's memory overcommit setting and apply it:

```sh
printf 'vm.overcommit_memory = 1\n' | sudo tee /etc/sysctl.d/99-self-hosted-redis.conf
sudo sysctl --system
sysctl vm.overcommit_memory
```

The last command should report `vm.overcommit_memory = 1`. Disable Transparent Huge Pages (THP) now and on future boots with a systemd service. The [Linux kernel documentation](https://docs.kernel.org/admin-guide/mm/transhuge.html) describes the `enabled` setting:

```sh
sudo tee /etc/systemd/system/disable-transparent-hugepages.service > /dev/null <<'UNIT'
[Unit]
Description=Disable Transparent Huge Pages
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now disable-transparent-hugepages.service
cat /sys/kernel/mm/transparent_hugepage/enabled
```

The last command should show `[never]`. If the file is absent or the service fails, consult your VPS provider's instructions. Check again after a reboot. Keep TCP port 6379 closed in both the VPS firewall and provider firewall.

## Choose access and install

Choose one command. Docker applications on this VPS use the default private `shared-services` network and hostname `redis`:

```sh
curl -fsSL https://github.com/jccd-dev/self-hosted-redis/releases/latest/download/install.sh | sudo sh
```

If any application runs directly on the VPS, such as PHP-FPM, pm2, or a systemd service, enable loopback access. Docker applications can still use the shared network:

```sh
curl -fsSL https://github.com/jccd-dev/self-hosted-redis/releases/latest/download/install.sh | sudo sh -s -- --host-access
```

The installer downloads and checks the release, creates credentials, starts Redis, and runs a check. It does not configure backups. If it fails, see [troubleshooting](#troubleshooting) before retrying.

For the remaining Redis operator commands, enter a root shell first. The installer creates the directory with private permissions, so a regular user cannot `cd` into it. Leave the shell with `exit` when finished.

```sh
sudo -i
cd /opt/self-hosted-redis
```

The commands below use `sudo` explicitly in that shell. If you installed with `--host-access`, the `.host-access` marker makes the project scripts use the loopback override. For every manual `docker compose` command in this guide, add `-f compose.yaml -f compose.host-access.yaml` immediately after `docker compose`. For example:

```sh
sudo docker compose -f compose.yaml -f compose.host-access.yaml logs redis
```

With `--host-access`, confirm Redis listens only on the VPS itself:

```sh
sudo docker compose -f compose.yaml -f compose.host-access.yaml port redis 6379
sudo ss -lntp | grep 6379
```

Both should show `127.0.0.1:6379`. If you see `0.0.0.0:6379`, stop and fix that before adding apps.

## Add and connect an app

Create a separate user for each application. Replace `my-app` with a lowercase slug starting with a letter and containing at most 32 letters, digits, and hyphens:

```sh
sudo ./bin/project-user add my-app
```

The command prints connection settings and the password once. Copy them into the app's `.env` or secret manager. For a Docker app, attach its service to the external `shared-services` network and use host `redis`; the [Docker recipe](client-recipes/docker.md) shows the Compose configuration. For a host-native app, change `REDIS_HOST` to `127.0.0.1` and, if using `REDIS_URL`, replace its `redis` hostname with `127.0.0.1`; keep port `6379`. See the [Laravel VPS guide](laravel-vps-guide.md) for both cases, or the [Node](client-recipes/node.md), [Python](client-recipes/python.md), and [Laravel](client-recipes/laravel.md) recipes.

Use the printed `my-app:` prefix for every Redis key and Pub/Sub channel. Each user is restricted to its own prefix. Avoid secrets in key names: users can see other projects' key names through `SCAN`.

## Day-to-day checks

From the root shell in `/opt/self-hosted-redis`:

```sh
sudo ./bin/check
sudo docker compose logs --tail=200 redis
```

Add the two Compose files shown above to the logs command when `.host-access` exists. See the [README operations section](../README.md#operations) for memory and persistence checks, and the [backup guide](backups.md) to configure and test backups.

## Update and rollback

Check the installed version and read the notes on the [GitHub releases page](https://github.com/jccd-dev/self-hosted-redis/releases) before updating:

```sh
sudo cat /opt/self-hosted-redis/VERSION
cd /opt/self-hosted-redis
sudo ./bin/update
```

The update briefly interrupts Redis. It runs `bin/check` automatically and runs a backup first if one is configured. Running it again for the installed version makes no changes. See [updates and rollback](releases.md#update-and-rollback) for details and pinned versions.

If an update fails, read its output and check Redis with `sudo ./bin/check` and the logs command above. If the new release fails to start or pass its check, the updater attempts to restore the previous code. If it reports recovery failed, keep the files and volumes, inspect the logs, and follow the recovery notes in the release guide before retrying.

After a successful update, you can return to the previous code:

```sh
sudo ./bin/update --rollback
```

Rollback needs a previous successful update. It swaps release code but does not restore data or undo writes or an incompatible data-format change. Use a verified backup and the [restore drill](../README.md#restore-drill) when data recovery is needed.

## Troubleshooting

For a failed first install, read the error. If the install directory exists, enter a root shell and inspect the service and credentials without deleting them:

```sh
sudo -i
cd /opt/self-hosted-redis
sudo docker compose logs redis
sudo ./bin/check
```

Use the two Compose files above if `.host-access` exists. A `missing ... run ./bin/init first` error may also mean the command lacked access to the private secrets; run it from the root shell with `sudo` before assuming credentials are missing. If the directory was never created, inspect the installer error and Docker status instead. The installer refuses to overwrite an existing directory or production data volume.

If this was a first install and you have confirmed it never held data you need, follow [uninstall](#uninstall), remove the directory and any production data volume left by the failed attempt, then rerun your chosen install command. Otherwise preserve the directory, secrets, and volumes and investigate before retrying.

## Uninstall

**Data loss warning:** removing volumes deletes their contents, including the Redis dataset, restore safety copies, and any local Restic repository. Removing the install directory deletes credentials and configuration. If backups are used, first keep a secure copy of `secrets/production/restic-password` outside the VPS; without it you cannot decrypt the backups. Verify any data and backups you need before proceeding.

From the root shell in `/opt/self-hosted-redis`, stop and remove this deployment's containers. This leaves the volumes intact:

```sh
sudo systemctl disable --now self-hosted-redis-backup.timer  # if enabled
sudo docker compose down
```

Add `-f compose.yaml -f compose.host-access.yaml` to the Compose command if `.host-access` exists. The timer command can report that the timer is absent when it was never installed. If you installed the timer, also remove its two unit files from `/etc/systemd/system/` and run `sudo systemctl daemon-reload`.

Only if you intend to delete the data, remove the volumes that exist:

```sh
sudo docker volume rm self-hosted-redis-data self-hosted-redis-restore-staging self-hosted-redis-local-restic
```

Remove the shared network only after confirming no other apps use it (`sudo docker network inspect shared-services`):

```sh
sudo docker network rm shared-services
```

The host-wide sysctl setting and THP service from host preparation remain in place; other applications may use them.

Finally, leave the directory and remove the installation and its secrets only if they are no longer needed:

```sh
cd /opt
sudo rm -rf /opt/self-hosted-redis
exit
```
