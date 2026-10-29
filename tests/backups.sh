#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$TMP/fake-bin"
cat >"$TMP/fake-bin/docker" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
case " $* " in
    *" compose "*" ps --status running --services "*)
        [ "${FAKE_REDIS_RUNNING:-0}" = 1 ] && printf 'redis\n'
        ;;
    *" LASTSAVE "*) printf '100\n' ;;
    *" BGSAVE "*) printf 'Background saving started\n' ;;
    *" INFO persistence "*)
        scheduled=0
        if [ "${FAKE_AOF_PENDING:-0}" = 1 ] && [ ! -f "$FAKE_DOCKER_LOG.ready" ]; then
            scheduled=1
            touch "$FAKE_DOCKER_LOG.ready"
        fi
        printf 'rdb_bgsave_in_progress:0\r\nrdb_last_bgsave_status:ok\r\naof_enabled:1\r\naof_rewrite_in_progress:0\r\naof_rewrite_scheduled:%s\r\naof_last_bgrewrite_status:%s\r\n' "$scheduled" "${FAKE_AOF_STATUS:-ok}"
        ;;
    *" run -d --rm --no-deps redis "*) printf 'restore-test-container\n' ;;
    *" CONFIG SET appendonly yes "*) printf '%s\n' "${FAKE_AOF_RESPONSE:-OK}" ;;
    *" PING "*) printf 'PONG\n' ;;
    *" restic snapshots "*) exit "${FAKE_SNAPSHOTS_EXIT:-0}" ;;
    *) printf 'OK\n' ;;
esac
FAKE
chmod +x "$TMP/fake-bin/docker"

REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/init" production >/dev/null

PATH="$TMP/fake-bin:$PATH" \
FAKE_DOCKER_LOG="$TMP/docker.log" \
REDIS_SECRETS_ROOT="$TMP/secrets" \
R2_ACCOUNT_ID=0123456789abcdef0123456789abcdef \
R2_BUCKET=redis-backups \
AWS_ACCESS_KEY_ID=test-access-key \
AWS_SECRET_ACCESS_KEY=test-secret-key \
"$ROOT/bin/backup-init" >/dev/null

R2_ENV="$TMP/secrets/production/r2.env"
[ -f "$R2_ENV" ] || fail 'backup-init did not create r2.env'
grep -Fxq 'R2_ACCOUNT_ID=0123456789abcdef0123456789abcdef' "$R2_ENV" || fail 'account ID missing'
grep -Fxq 'R2_BUCKET=redis-backups' "$R2_ENV" || fail 'bucket missing'
grep -Fxq 'RESTIC_REPOSITORY=s3:https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/redis-backups' "$R2_ENV" || fail 'Restic R2 URL is incorrect'
[ "$(stat -f '%Lp' "$R2_ENV" 2>/dev/null || stat -c '%a' "$R2_ENV")" = 600 ] || fail 'r2.env must have mode 600'

: >"$TMP/docker.log"
PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/backup" >/dev/null
grep -Eq ' BGSAVE$' "$TMP/docker.log" || fail 'backup did not request BGSAVE'
grep -Eq 'restic backup /data/dump.rdb --host self-hosted-redis --tag redis-production' "$TMP/docker.log" || fail 'Restic backup command is incorrect'
grep -Eq 'restic forget --host self-hosted-redis --tag redis-production --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune' "$TMP/docker.log" || fail 'Restic retention command is incorrect'

if PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/restore" latest >/dev/null 2>&1; then
    fail 'restore accepted a request without --confirm'
fi

if PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" FAKE_REDIS_RUNNING=1 REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/restore" latest --confirm >/dev/null 2>&1; then
    fail 'restore proceeded while Redis was running'
fi

: >"$TMP/docker.log"
PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" FAKE_AOF_PENDING=1 REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/restore" abcd1234 --confirm >/dev/null
grep -Eq 'restic restore abcd1234 --target /restore --include /data/dump.rdb' "$TMP/docker.log" || fail 'snapshot was not restored into staging'
grep -Eq 'redis-check-rdb /restore/data/dump.rdb' "$TMP/docker.log" || fail 'staged RDB was not validated'
grep -Eq 'redis-server /usr/local/etc/redis/redis.conf .*--appendonly no' "$TMP/docker.log" || fail 'restore did not load the RDB with AOF disabled'
grep -Eq 'CONFIG SET appendonly yes' "$TMP/docker.log" || fail 'restore did not rebuild AOF from the restored RDB'
[ "$(grep -c 'INFO persistence' "$TMP/docker.log")" -ge 2 ] || fail 'restore did not wait for scheduled AOF creation'
grep -Eq 'up -d --no-recreate --wait redis' "$TMP/docker.log" || fail 'Redis was not started after cutover'

for failure in rejected failed; do
    : >"$TMP/docker.log"
    response=OK
    status=ok
    if [ "$failure" = rejected ]; then response='ERR cannot enable AOF'; else status=err; fi
    if PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" FAKE_AOF_RESPONSE="$response" FAKE_AOF_STATUS="$status" REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/restore" latest --confirm >"$TMP/restore-error" 2>&1; then
        fail "restore accepted $failure AOF creation"
    fi
    grep -Eq 'AOF' "$TMP/restore-error" || fail 'restore did not explain the AOF failure'
    grep -Eq '^stop restore-test-container$' "$TMP/docker.log" || fail 'restore did not stop its temporary Redis on failure'
    if grep -Eq 'up -d --no-recreate --wait redis' "$TMP/docker.log"; then
        fail 'restore started the normal service after AOF creation failed'
    fi
done

printf 'Backup checks passed.\n'
