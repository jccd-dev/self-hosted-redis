# Generic Docker client

Every project receives a Redis username, password, database `0`, and a unique prefix. Keep the generated values in that project's secret manager. The password is shown only when the user is added or rotated.

```dotenv
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_USERNAME=example
REDIS_PASSWORD=<generated-password>
REDIS_DATABASE=0
REDIS_PREFIX=example:
REDIS_URL=redis://example:<generated-password>@redis:6379/0
```

Attach the project service to the same external network without publishing Redis:

```yaml
services:
  app:
    image: your-application-image
    environment:
      REDIS_URL: ${REDIS_URL}
      REDIS_PREFIX: ${REDIS_PREFIX}
    networks:
      - shared-services

networks:
  shared-services:
    external: true
```

The application must prefix every Redis key and Pub/Sub channel with `REDIS_PREFIX`. ACL enforcement rejects unprefixed and cross-project access. Lua scripts must receive fully prefixed keys through `KEYS`; they must not construct undeclared keys internally.

For a direct check from a root shell in `/opt/self-hosted-redis`, add `-f compose.yaml -f compose.host-access.yaml` after `docker compose` if `.host-access` exists:

```sh
sudo docker compose exec redis redis-cli --user example --askpass SET example:health ok EX 30
```
