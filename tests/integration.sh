#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
COMPOSE_PROJECT_NAME="self-hosted-redis-test-$$"
export COMPOSE_PROJECT_NAME
unset REDIS_SECRETS_ROOT RESTIC_ENV_FILE RESTIC_REPOSITORY R2_ACCOUNT_ID R2_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/config" "$TMP/"
cp "$ROOT/compose.yaml" "$TMP/"
sed -e "s/self-hosted-redis-dev/$COMPOSE_PROJECT_NAME/g" \
    -e 's/127.0.0.1:6379:6379/127.0.0.1::6379/' \
    "$ROOT/compose.dev.yaml" >"$TMP/compose.dev.yaml"
cd "$TMP"

compose() {
    docker compose -f compose.yaml -f compose.dev.yaml "$@"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

app_cli() {
    user=$1
    password=$2
    shift 2
    compose exec -T -e REDISCLI_AUTH="$password" redis \
        redis-cli --user "$user" --no-auth-warning --raw "$@"
}

cleanup() {
    compose --profile tools down --volumes --remove-orphans >/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ ! -f secrets/development/users.acl ]; then
    ./bin/init development >/dev/null
fi

compose up -d --wait redis

unauthenticated=$(compose exec -T redis redis-cli --raw PING 2>&1 || true)
printf '%s\n' "$unauthenticated" | grep -Eq 'NOAUTH|Authentication required' || fail 'unauthenticated PING was not rejected'

if REDIS_ENV=development ./bin/project-user remove alpha >/dev/null 2>&1; then :; fi
if REDIS_ENV=development ./bin/project-user remove beta >/dev/null 2>&1; then :; fi
alpha_output=$(REDIS_ENV=development ./bin/project-user add alpha)
beta_output=$(REDIS_ENV=development ./bin/project-user add beta)
alpha_password=$(printf '%s\n' "$alpha_output" | awk -F= '$1 == "REDIS_PASSWORD" {print $2}')
beta_password=$(printf '%s\n' "$beta_output" | awk -F= '$1 == "REDIS_PASSWORD" {print $2}')

[ "$(app_cli alpha "$alpha_password" SET alpha:string value EX 60)" = OK ] || fail 'SET failed'
[ "$(app_cli alpha "$alpha_password" HSET alpha:hash field value)" = 1 ] || fail 'HSET failed'
[ "$(app_cli alpha "$alpha_password" LPUSH alpha:list item)" = 1 ] || fail 'LPUSH failed'
app_cli alpha "$alpha_password" XADD alpha:stream '*' event ready >/dev/null || fail 'XADD failed'
[ "$(app_cli alpha "$alpha_password" EVAL "return redis.call('SET', KEYS[1], ARGV[1])" 1 alpha:lua ok)" = OK ] || fail 'Lua operation failed'
app_cli alpha "$alpha_password" PUBLISH alpha:events ready >/dev/null || fail 'namespaced PUBLISH failed'

cross=$(app_cli alpha "$alpha_password" SET beta:intrusion denied 2>&1 || true)
printf '%s\n' "$cross" | grep -q 'NOPERM' || fail 'cross-project key access was not denied'
plain=$(app_cli alpha "$alpha_password" SET unprefixed denied 2>&1 || true)
printf '%s\n' "$plain" | grep -q 'NOPERM' || fail 'unprefixed key access was not denied'
for command in FLUSHALL FLUSHDB SHUTDOWN; do
    denied=$(app_cli alpha "$alpha_password" "$command" 2>&1 || true)
    printf '%s\n' "$denied" | grep -q 'NOPERM' || fail "$command was not denied"
done
denied=$(app_cli alpha "$alpha_password" CONFIG GET maxmemory 2>&1 || true)
printf '%s\n' "$denied" | grep -q 'NOPERM' || fail 'CONFIG was not denied'
denied=$(app_cli alpha "$alpha_password" ACL USERS 2>&1 || true)
printf '%s\n' "$denied" | grep -q 'NOPERM' || fail 'ACL was not denied'

app_cli alpha "$alpha_password" SET alpha:persistent before-recreate >/dev/null
sleep 2
compose down
compose up -d --wait redis
[ "$(app_cli alpha "$alpha_password" GET alpha:persistent)" = before-recreate ] || fail 'data did not survive container recreation'

cat >secrets/development/r2.env <<'ENV'
R2_ACCOUNT_ID=00000000000000000000000000000000
R2_BUCKET=local-test
AWS_ACCESS_KEY_ID=local-test
AWS_SECRET_ACCESS_KEY=local-test
RESTIC_REPOSITORY=/local-backup/repository
ENV
chmod 600 secrets/development/r2.env

REDIS_ENV=development ./bin/backup-init >/dev/null
REDIS_ENV=development ./bin/backup >/dev/null
app_cli alpha "$alpha_password" SET alpha:persistent after-backup >/dev/null
published=$(compose port redis 6379)
sed "s/127.0.0.1::6379/$published:6379/" compose.dev.yaml >compose.dev.yaml.tmp
mv compose.dev.yaml.tmp compose.dev.yaml
cat >restore-override.yaml <<'YAML'
services:
  redis:
    labels:
      self-hosted-redis.restore-test: preserve-host-access
YAML
compose -f restore-override.yaml up -d --wait redis
compose stop redis >/dev/null
REDIS_ENV=development ./bin/restore latest --confirm >/dev/null
[ "$(app_cli alpha "$alpha_password" GET alpha:persistent)" = before-recreate ] || fail 'restored snapshot did not recover the backed-up value'
[ "$(compose port redis 6379)" = "$published" ] || fail 'restore changed the published host port'
[ "$(docker inspect --format '{{ index .Config.Labels "self-hosted-redis.restore-test" }}' "$(compose ps -q redis)")" = preserve-host-access ] || fail 'restore dropped the deployment override'
compose down
compose up -d --wait redis
[ "$(app_cli alpha "$alpha_password" GET alpha:persistent)" = before-recreate ] || fail 'restored value did not survive an AOF restart'

app_cli beta "$beta_password" SET beta:health ok >/dev/null || fail 'second project user failed'
printf 'Docker integration checks passed.\n'
