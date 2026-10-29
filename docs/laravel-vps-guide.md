# VPS deployment and Laravel usage guide

This guide deploys one Redis service on a VPS and connects two kinds of Laravel application:

1. A Laravel application running directly on the VPS with PHP-FPM, Nginx, Supervisor, Forge, or a similar setup.
2. A Laravel application running in Docker on the same VPS.

Each application receives a different Redis ACL user and key prefix. The host application connects through VPS loopback. Dockerized applications connect through a private Docker network. Redis is never exposed on the VPS public interface.

## 1. Install Redis on the VPS

The commands assume this repository is installed at `/opt/self-hosted-redis` and Docker Compose v2 is available.

```sh
cd /opt/self-hosted-redis
sudo sysctl vm.overcommit_memory=1
docker network inspect shared-services >/dev/null 2>&1 || docker network create shared-services
./bin/init production
```

Run `./bin/init production` only once. It refuses to replace an existing ACL file or passwords.

Because at least one Laravel application runs outside Docker, start Redis with the loopback override:

```sh
docker compose -f compose.yaml -f compose.host-access.yaml up -d --wait redis
./bin/check
```

Always include `compose.host-access.yaml` in future `up` or `config` commands. Starting with only `compose.yaml` removes the host port mapping.

Confirm Redis is bound only to VPS loopback:

```sh
docker compose -f compose.yaml -f compose.host-access.yaml port redis 6379
sudo ss -lntp | grep 6379
```

The reported address must be `127.0.0.1:6379`, never `0.0.0.0:6379`. Do not open port 6379 in UFW, firewalld, the VPS provider firewall, or a cloud security group.

## 2. Create one Redis user per Laravel application

Create separate users even when both applications belong to the same organization:

```sh
cd /opt/self-hosted-redis
./bin/project-user add legacy-laravel
./bin/project-user add docker-laravel
```

Each command prints connection values once. Save each result in the corresponding application's secret environment file. Do not reuse one application's password or prefix in another application.

To rotate or remove credentials later:

```sh
./bin/project-user rotate legacy-laravel
./bin/project-user remove legacy-laravel
```

## 3. Scenario A: Laravel is not Dockerized

The Laravel application and Docker Engine are on the same VPS. The application connects to the published loopback socket:

```dotenv
REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_USERNAME=legacy-laravel
REDIS_PASSWORD=<password-from-project-user>
REDIS_DB=0
REDIS_CACHE_DB=0
REDIS_PREFIX=legacy-laravel:

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
```

Older Laravel releases may use `CACHE_DRIVER=redis` instead of `CACHE_STORE=redis`.

Use PhpRedis when it is already installed:

```sh
php -m | grep -i redis
```

If PhpRedis is unavailable and cannot be installed, use Predis:

```sh
composer require predis/predis
```

Then set `REDIS_CLIENT=predis`.

Ensure `config/database.php` reads the ACL username and applies the prefix to every Redis connection:

```php
'redis' => [
    'client' => env('REDIS_CLIENT', 'phpredis'),
    'options' => [
        'prefix' => env('REDIS_PREFIX'),
    ],
    'default' => [
        'host' => env('REDIS_HOST', '127.0.0.1'),
        'username' => env('REDIS_USERNAME'),
        'password' => env('REDIS_PASSWORD'),
        'port' => env('REDIS_PORT', 6379),
        'database' => env('REDIS_DB', 0),
    ],
    'cache' => [
        'host' => env('REDIS_HOST', '127.0.0.1'),
        'username' => env('REDIS_USERNAME'),
        'password' => env('REDIS_PASSWORD'),
        'port' => env('REDIS_PORT', 6379),
        'database' => env('REDIS_CACHE_DB', 0),
    ],
],
```

Refresh Laravel's cached configuration and test the connection:

```sh
cd /path/to/laravel
php artisan config:clear
php artisan tinker --execute="Redis::connection()->set('health', 'ok', 'EX', 30); dump(Redis::connection()->get('health'));"
```

The output should contain `ok`. Restart PHP-FPM and long-running queue, Horizon, Octane, and Pulse workers after changing Redis credentials.

## 4. Scenario B: Laravel is Dockerized

Do not publish another Redis port and do not use `127.0.0.1` inside the Laravel container. In a container, `127.0.0.1` refers to that container itself.

Attach the Laravel service to the existing external network:

```yaml
services:
  app:
    image: your-laravel-image
    environment:
      REDIS_CLIENT: phpredis
      REDIS_HOST: redis
      REDIS_PORT: 6379
      REDIS_USERNAME: docker-laravel
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      REDIS_DB: 0
      REDIS_CACHE_DB: 0
      REDIS_PREFIX: "docker-laravel:"
      CACHE_STORE: redis
      SESSION_DRIVER: redis
      QUEUE_CONNECTION: redis
    networks:
      - app-private
      - shared-services

networks:
  app-private:
  shared-services:
    external: true
```

Store `REDIS_PASSWORD` in the Laravel project's ignored `.env` or deployment secret manager. The effective Laravel values are:

```dotenv
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_USERNAME=docker-laravel
REDIS_PASSWORD=<password-from-project-user>
REDIS_DB=0
REDIS_CACHE_DB=0
REDIS_PREFIX=docker-laravel:
```

Recreate the Laravel service after attaching the network, then clear its cached configuration:

```sh
docker compose up -d --force-recreate app
docker compose exec app php artisan config:clear
docker compose exec app php artisan tinker --execute="Redis::connection()->set('health', 'ok', 'EX', 30); dump(Redis::connection()->get('health'));"
```

The Redis Compose project and Laravel Compose project remain separate. `depends_on` cannot manage services in another Compose project; use application retry/backoff and normal process restarts during Redis maintenance.

## 5. Laravel Pulse, queues, sessions, and cache

Both deployment scenarios use the same project-specific Redis connection.

For Pulse Redis ingest:

```dotenv
PULSE_INGEST_DRIVER=redis
PULSE_REDIS_CONNECTION=default
```

Keep the Pulse worker running under Supervisor, systemd, or the Docker application's process manager:

```sh
php artisan pulse:work
```

During deployment, restart it with:

```sh
php artisan pulse:restart
```

Pulse uses Redis as its ingest stream but stores its aggregated durable records in SQL. Queue workers and Horizon must also be restarted after credential or prefix changes.

## 6. Configure Cloudflare R2 backups

Create an R2 token with Object Read & Write access limited to the dedicated Redis backup bucket. On the VPS:

```sh
cd /opt/self-hosted-redis
cp r2.env.example secrets/production/r2-bootstrap.env
chmod 600 secrets/production/r2-bootstrap.env
```

Edit that ignored file with the R2 account ID, bucket name, Access Key ID, and Secret Access Key. Load it without printing the values:

```sh
set -a
. ./secrets/production/r2-bootstrap.env
set +a
./bin/backup-init
./bin/backup
```

Keep an off-VPS copy of `secrets/production/restic-password`; backups cannot be decrypted without it. Install the daily systemd timer using the commands in the main [README](../README.md#daily-systemd-timer).

## 7. Deployment and maintenance commands

Use the host-access override whenever Redis is recreated or upgraded:

```sh
cd /opt/self-hosted-redis
./bin/backup
docker compose -f compose.yaml -f compose.host-access.yaml pull
docker compose -f compose.yaml -f compose.host-access.yaml up -d --wait redis
./bin/check
```

Useful diagnostics:

```sh
docker compose -f compose.yaml -f compose.host-access.yaml ps
docker compose -f compose.yaml -f compose.host-access.yaml logs --tail=200 redis
docker network inspect shared-services
```

## Troubleshooting

- **Host Laravel gets connection refused:** Redis was probably started without `compose.host-access.yaml`, or it is not healthy. Check the published port and container logs.
- **Docker Laravel cannot resolve `redis`:** Attach its service to the external `shared-services` network and recreate the container.
- **`WRONGPASS` or authentication errors:** Confirm the username and its matching password; rotate the project user if the plaintext password was lost.
- **`NOPERM` errors:** Confirm `REDIS_PREFIX` exactly matches the prefix printed for that project. Custom Lua scripts and Pub/Sub channels must also use the prefix.
- **Laravel still uses old settings:** Run `php artisan config:clear` and restart PHP-FPM and all long-running workers.
- **Never solve connectivity by publishing `0.0.0.0:6379`:** use VPS loopback for host processes and `shared-services` for containers.
