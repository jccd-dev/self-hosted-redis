#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
if [ "${1:-}" != --inside ]; then
    # A separate daemon keeps production-named resources off the host daemon.
    target="self-hosted-redis-release-test-$$"
    work=$(mktemp -d)
    # shellcheck disable=SC2329
    cleanup() {
        result=$?
        if [ "$result" -ne 0 ]; then
            docker exec "$target" docker compose -f /opt/self-hosted-redis/compose.yaml logs --tail=80 redis >&2 || true
        fi
        docker container rm --force --volumes "$target" >/dev/null 2>&1 || true
        rm -r -- "$work"
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    for item in install.sh VERSION bin lib config docs systemd compose.yaml compose.dev.yaml compose.host-access.yaml .env.example backup.env.example r2.env.example README.md; do
        cp -R "$ROOT/$item" "$work/"
    done
    mkdir "$work/tests"
    cp "$0" "$work/tests/release-integration.sh"
    docker run -d --privileged --name "$target" docker:29-dind >/dev/null
    docker cp "$work/." "$target:/src"
    docker exec "$target" apk add --no-cache curl openssl tar coreutils >/dev/null
    docker exec "$target" chmod 755 /src
    if docker exec --user 1000:0 "$target" sh /src/install.sh --prefix /tmp/nonroot >"$work/nonroot.log" 2>&1; then
        echo 'FAIL: nonroot installation accepted' >&2; exit 1
    fi
    grep -q 'requires root' "$work/nonroot.log"
    docker exec "$target" test ! -e /tmp/nonroot
    docker exec "$target" sh /src/tests/release-integration.sh --inside
    exit
fi

tries=0
until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || { echo 'Disposable Docker daemon did not start' >&2; exit 1; }
    sleep 1
done
mkdir -p /fixtures/package/self-hosted-redis /fixtures/releases/download
for item in install.sh VERSION bin lib config docs systemd compose.yaml compose.dev.yaml compose.host-access.yaml .env.example backup.env.example r2.env.example README.md; do
    cp -R "$ROOT/$item" /fixtures/package/self-hosted-redis/
done
publish() {
    printf '%s\n' "$1" >/fixtures/package/self-hosted-redis/VERSION
    mkdir -p "/fixtures/releases/download/v$1"
    tar -czf "/fixtures/releases/download/v$1/self-hosted-redis.tar.gz" -C /fixtures/package self-hosted-redis
    (cd "/fixtures/releases/download/v$1" && sha256sum self-hosted-redis.tar.gz >self-hosted-redis.tar.gz.sha256)
}
publish 0.1.0
export SELF_HOSTED_REDIS_RELEASE_URL=file:///fixtures/releases
sh "$ROOT/install.sh" --version v0.1.0 --host-access
cd /opt/self-hosted-redis
printf '\nREDIS_MAXMEMORY=128mb\nREDIS_MEM_LIMIT=320m\n' >>.env
cp .env /fixtures/expected.env
output=$(./bin/project-user add release-test)
password=$(printf '%s\n' "$output" | awk -F= '$1 == "REDIS_PASSWORD" {print $2}')
cp secrets/production/users.acl /fixtures/expected.acl
app_cli() {
    docker compose exec -T -e REDISCLI_AUTH="$password" redis redis-cli --user release-test --no-auth-warning --raw "$@"
}
app_cli SET release-test:persistent survives-update
publish 0.2.0
./bin/update v0.2.0
[ "$(cat VERSION)" = 0.2.0 ]
cmp .env /fixtures/expected.env
cmp secrets/production/users.acl /fixtures/expected.acl
[ "$(app_cli GET release-test:persistent)" = survives-update ]
[ "$(docker compose port redis 6379)" = 127.0.0.1:6379 ]
./bin/check
cp backup.env.example secrets/production/backup.env
./bin/backup-init
./bin/update --rollback
[ "$(cat VERSION)" = 0.1.0 ]
[ "$(app_cli GET release-test:persistent)" = survives-update ]
cmp secrets/production/users.acl /fixtures/expected.acl
./bin/check
printf '#!/bin/sh\nexit 1\n' >/fixtures/package/self-hosted-redis/bin/check
publish 0.3.0
if ./bin/update v0.3.0; then
    echo 'FAIL: unhealthy update succeeded' >&2; exit 1
fi
[ "$(cat VERSION)" = 0.1.0 ]
[ "$(app_cli GET release-test:persistent)" = survives-update ]
./bin/check
printf 'Clean Linux install, update, backup and rollback checks passed.\n'
