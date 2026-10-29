#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
    file=$1
    pattern=$2
    grep -Eq "$pattern" "$file" || fail "$file does not match: $pattern"
}

for file in \
    compose.yaml \
    compose.dev.yaml \
    compose.host-access.yaml \
    config/redis.conf \
    bin/init \
    bin/project-user \
    bin/check \
    bin/backup-init \
    bin/backup \
    bin/restore \
    systemd/self-hosted-redis-backup.service \
    systemd/self-hosted-redis-backup.timer \
    .env.example \
    r2.env.example \
    backup.env.example \
    .gitignore \
    README.md; do
    assert_file "$file"
done

assert_contains compose.yaml 'redis:8\.8\.0-alpine3\.23'
assert_contains compose.yaml 'restic/restic:0\.19\.0'
assert_contains compose.yaml 'shared-services'
assert_contains compose.yaml 'external: true'
assert_contains compose.yaml 'mem_limit: \$\{REDIS_MEM_LIMIT:-512m\}'
assert_contains compose.yaml 'max-size: "10m"'
assert_contains compose.dev.yaml '127\.0\.0\.1:6379:6379'
assert_contains compose.host-access.yaml '127\.0\.0\.1:6379:6379'
assert_contains config/redis.conf '^appendonly yes$'
assert_contains config/redis.conf '^appendfsync everysec$'
assert_contains config/redis.conf '^aclfile /run/redis/users\.acl$'
assert_contains .gitignore '^secrets/\*$'
assert_contains systemd/self-hosted-redis-backup.timer '^OnCalendar=daily$'

if grep -Eq '^[[:space:]]*ports:' compose.yaml; then
    fail 'production compose must not publish Redis ports'
fi

docker compose -f compose.yaml -f compose.host-access.yaml config | grep -q 'host_ip: 127.0.0.1' ||
    fail 'host-access override must bind Redis to loopback only'

for script in bin/* lib/*.sh tests/*.sh; do
    sh -n "$script"
done
shellcheck -x bin/* lib/*.sh tests/*.sh

docker compose -f compose.yaml config >/dev/null
docker compose -f compose.yaml -f compose.dev.yaml config >/dev/null

printf 'Static checks passed.\n'
