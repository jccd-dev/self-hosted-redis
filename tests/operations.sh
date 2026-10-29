#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s' "$1" | grep -Eq "$2" || fail "output does not match: $2"
}

REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/init" development >/dev/null
REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/init" production >/dev/null

ACL_FILE="$TMP/secrets/development/users.acl"
[ -f "$ACL_FILE" ] || fail 'init did not create users.acl'
grep -Eq '^user default off$' "$ACL_FILE" || fail 'default user is not disabled'
grep -Eq '^user admin on #[0-9a-f]{64} ~\* &\* \+@all$' "$ACL_FILE" || fail 'admin ACL is incorrect'
grep -Eq '^user health on #[0-9a-f]{64} -@all \+ping$' "$ACL_FILE" || fail 'health ACL is incorrect'
grep -Eq '^user backup on #[0-9a-f]{64} -@all \+ping \+info \+bgsave \+lastsave$' "$ACL_FILE" || fail 'backup ACL is incorrect'
[ "$(stat -f '%Lp' "$ACL_FILE" 2>/dev/null || stat -c '%a' "$ACL_FILE")" = 600 ] || fail 'users.acl must have mode 600'

if REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/init" development >/dev/null 2>&1; then
    fail 'init should refuse to overwrite existing secrets'
fi

mkdir -p "$TMP/fake-bin"
cat >"$TMP/fake-bin/docker" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
case " $* " in
    *" ACL USERS "*)
        printf '%s\n' admin health backup ${FAKE_ACL_USERS:-}
        ;;
    *)
        printf 'OK\n'
        ;;
esac
FAKE
chmod +x "$TMP/fake-bin/docker"

if PATH="$TMP/fake-bin:$PATH" "$ROOT/bin/project-user" add 'Bad Slug' >/dev/null 2>&1; then
    fail 'project-user accepted an invalid slug'
fi

OUTPUT=$(PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" REDIS_SECRETS_ROOT="$TMP/secrets" REDIS_ENV=production "$ROOT/bin/project-user" add sample)
assert_contains "$OUTPUT" '^REDIS_HOST=redis$'
assert_contains "$OUTPUT" '^REDIS_USERNAME=sample$'
assert_contains "$OUTPUT" '^REDIS_PASSWORD=[0-9a-f]{64}$'
assert_contains "$OUTPUT" '^REDIS_DATABASE=0$'
assert_contains "$OUTPUT" '^REDIS_PREFIX=sample:$'
assert_contains "$OUTPUT" '^REDIS_URL=redis://sample:[0-9a-f]{64}@redis:6379/0$'
grep -Eq 'ACL SETUSER sample reset on #[0-9a-f]{64} resetkeys ~sample:\* resetchannels &sample:\* \+@all -@admin -@dangerous -function\|delete -function\|flush -function\|load -function\|restore -script\|flush -randomkey -pubsub\|channels -pubsub\|shardchannels -pubsub\|numpat' "$TMP/docker.log" || fail 'project ACL command is incorrect'
grep -Eq 'ACL SAVE' "$TMP/docker.log" || fail 'ACL changes were not saved'

: >"$TMP/docker.log"
ROTATED=$(PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" FAKE_ACL_USERS=sample REDIS_SECRETS_ROOT="$TMP/secrets" REDIS_ENV=development "$ROOT/bin/project-user" rotate sample)
assert_contains "$ROTATED" '^REDIS_HOST=127\.0\.0\.1$'
grep -Eq 'ACL SETUSER sample resetpass #[0-9a-f]{64}' "$TMP/docker.log" || fail 'rotation command is incorrect'

: >"$TMP/docker.log"
PATH="$TMP/fake-bin:$PATH" FAKE_DOCKER_LOG="$TMP/docker.log" FAKE_ACL_USERS=sample REDIS_SECRETS_ROOT="$TMP/secrets" "$ROOT/bin/project-user" remove sample >/dev/null
grep -Eq 'ACL DELUSER sample' "$TMP/docker.log" || fail 'remove command is incorrect'

printf 'Operation checks passed.\n'
