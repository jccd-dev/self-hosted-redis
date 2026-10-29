#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[ "${RUN_R2_INTEGRATION:-0}" = 1 ] || {
    printf 'Skipping Cloudflare R2 integration; set RUN_R2_INTEGRATION=1 to enable it.\n'
    exit 0
}

. "$ROOT/lib/common.sh"
validate_environment
require_backup_config

docker compose --profile tools run --rm --no-deps redis-tools -c \
    'mkdir -p /restore/r2-smoke && printf verified > /restore/r2-smoke/payload'
restic_run backup /restore/r2-smoke/payload --host self-hosted-redis-r2-check --tag r2-integration
restic_run snapshots --host self-hosted-redis-r2-check --tag r2-integration
restic_run check
docker compose --profile tools run --rm --no-deps redis-tools -c \
    'find /restore/r2-smoke-restored -mindepth 1 -delete 2>/dev/null || true; mkdir -p /restore/r2-smoke-restored'
restic_run restore latest --host self-hosted-redis-r2-check --tag r2-integration --target /restore/r2-smoke-restored
docker compose --profile tools run --rm --no-deps redis-tools -c \
    'test "$(cat /restore/r2-smoke-restored/restore/r2-smoke/payload)" = verified'

printf 'Cloudflare R2 integration checks passed.\n'
