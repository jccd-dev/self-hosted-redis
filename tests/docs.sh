#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for file in README.md docs/laravel-vps-guide.md docs/client-recipes/docker.md docs/client-recipes/laravel.md docs/client-recipes/node.md docs/client-recipes/python.md; do
    [ -s "$file" ] || fail "missing documentation: $file"
done

grep -Eq 'REDIS_PREFIX' docs/client-recipes/docker.md || fail 'generic contract is not documented'
grep -Eq 'keyPrefix' docs/client-recipes/node.md || fail 'Node namespace handling is not documented'
grep -Eq 'PULSE_INGEST_DRIVER=redis' docs/client-recipes/laravel.md || fail 'Pulse ingest is not documented'
grep -Eq 'pulse:work' docs/client-recipes/laravel.md || fail 'Pulse worker is not documented'
grep -Eq 'Object Read.*Write' README.md || fail 'R2 token scope is not documented'
grep -Eq 'single-node|single node' README.md || fail 'single-node limitation is not documented'
grep -Eq 'vm\.overcommit_memory' README.md || fail 'Redis kernel prerequisite is not documented'
grep -Eq '/opt/self-hosted-redis' README.md || fail 'systemd installation path is not documented'
grep -Eq '127\.0\.0\.1' docs/laravel-vps-guide.md || fail 'non-Docker Laravel Redis host is not documented'
grep -Eq 'shared-services' docs/laravel-vps-guide.md || fail 'Dockerized Laravel network is not documented'
grep -Eq 'REDIS_HOST=redis' docs/laravel-vps-guide.md || fail 'Dockerized Laravel Redis hostname is not documented'
grep -Eq 'config:clear' docs/laravel-vps-guide.md || fail 'Laravel configuration refresh is not documented'
grep -Eq 'Pulse' docs/laravel-vps-guide.md || fail 'Laravel Pulse usage is not documented'

printf 'Documentation checks passed.\n'
