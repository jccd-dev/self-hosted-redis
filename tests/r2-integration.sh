#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[ "${RUN_R2_INTEGRATION:-0}" = 1 ] || {
    printf 'Skipping Cloudflare R2 integration; set RUN_R2_INTEGRATION=1 to enable it.\n'
    exit 0
}

[ -f secrets/production/r2.env ] || {
    printf 'Missing secrets/production/r2.env; run ./bin/backup-init first.\n' >&2
    exit 1
}

docker compose --profile tools run --rm --no-deps redis-tools -c \
    'mkdir -p /restore/r2-smoke && printf verified > /restore/r2-smoke/payload'
docker compose --env-file secrets/production/r2.env --profile tools run --rm --no-deps restic \
    backup /restore/r2-smoke/payload --host self-hosted-redis-r2-check --tag r2-integration
docker compose --env-file secrets/production/r2.env --profile tools run --rm --no-deps restic \
    snapshots --host self-hosted-redis-r2-check --tag r2-integration
docker compose --env-file secrets/production/r2.env --profile tools run --rm --no-deps restic check
docker compose --profile tools run --rm --no-deps redis-tools -c \
    'find /restore/r2-smoke-restored -mindepth 1 -delete 2>/dev/null || true; mkdir -p /restore/r2-smoke-restored'
docker compose --env-file secrets/production/r2.env --profile tools run --rm --no-deps restic \
    restore latest --host self-hosted-redis-r2-check --tag r2-integration --target /restore/r2-smoke-restored
docker compose --profile tools run --rm --no-deps redis-tools -c \
    'test "$(cat /restore/r2-smoke-restored/restore/r2-smoke/payload)" = verified'

printf 'Cloudflare R2 integration checks passed.\n'
