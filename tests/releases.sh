#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/package" "$TMP/fake-bin"
if "$ROOT/scripts/package-release.sh" "$TMP/mismatch" v9.9.9 >/dev/null 2>&1; then
    echo 'FAIL: packaging accepted a tag that differs from VERSION' >&2; exit 1
fi
# The first fixture is the real release package, relabeled 0.1.0 for later version bumps.
"$ROOT/scripts/package-release.sh" "$TMP/built" >/dev/null
(cd "$TMP/built" && sha256sum -c self-hosted-redis.tar.gz.sha256 >/dev/null)
cmp "$ROOT/install.sh" "$TMP/built/install.sh"
[ -s "$TMP/built/release-notes.md" ]
tar -tzf "$TMP/built/self-hosted-redis.tar.gz" >"$TMP/entries"
for entry in VERSION LICENSE install.sh bin/update docs/releases.md systemd/self-hosted-redis-backup.timer .env.example; do
    grep -qx "self-hosted-redis/$entry" "$TMP/entries" || { echo "FAIL: release lacks $entry" >&2; exit 1; }
done
if grep -Ev '^self-hosted-redis/' "$TMP/entries" || grep -E '/(secrets/.+|\.env|\.git.*|\.DS_Store|tests/.*|scripts/.*|\.host-access)$' "$TMP/entries"; then
    echo 'FAIL: release contains unexpected paths' >&2; exit 1
fi
tar -xzf "$TMP/built/self-hosted-redis.tar.gz" -C "$TMP/package"
printf '0.1.0\n' >"$TMP/package/self-hosted-redis/VERSION"
mkdir -p "$TMP/releases/download/v0.1.0"
tar -czf "$TMP/releases/download/v0.1.0/self-hosted-redis.tar.gz" -C "$TMP/package" self-hosted-redis
(cd "$TMP/releases/download/v0.1.0" && sha256sum self-hosted-redis.tar.gz >self-hosted-redis.tar.gz.sha256)
cat >"$TMP/fake-bin/uname" <<'FAKE'
#!/bin/sh
printf 'Linux\n'
FAKE
cat >"$TMP/fake-bin/id" <<'FAKE'
#!/bin/sh
printf '%s\n' "${FAKE_UID:-0}"
FAKE
cat >"$TMP/fake-bin/docker" <<'FAKE'
#!/bin/sh
case "$*" in
    'volume inspect self-hosted-redis-data') exit 1 ;;
    'compose version --short') echo 2.24.0 ;;
    *'ps --status running --services') echo redis ;;
    *'printenv REDIS_MAXMEMORY_POLICY') echo noeviction ;;
    *'printenv REDIS_MAXMEMORY') echo 256mb ;;
    *'CONFIG GET maxmemory-policy') printf 'maxmemory-policy\nnoeviction\n' ;;
    *'CONFIG GET maxmemory') printf 'maxmemory\n268435456\n' ;;
    *'INFO persistence') echo aof_enabled:1 ;;
    *' PING') echo PONG ;;
esac
FAKE
chmod +x "$TMP/fake-bin/"*
if PATH="$TMP/fake-bin:$PATH" FAKE_UID=1000 SELF_HOSTED_REDIS_RELEASE_URL="file://$TMP/releases" sh "$ROOT/install.sh" --version v0.1.0 --prefix "$TMP/nonroot" >"$TMP/nonroot.log" 2>&1; then
    echo 'FAIL: nonroot installer reached secret ownership changes' >&2; exit 1
fi
grep -q 'requires root' "$TMP/nonroot.log"
[ ! -e "$TMP/nonroot" ]
PATH="$TMP/fake-bin:$PATH" SELF_HOSTED_REDIS_RELEASE_URL="file://$TMP/releases" sh "$ROOT/install.sh" --version v0.1.0 --prefix "$TMP/install"
[ "$(cat "$TMP/install/VERSION")" = 0.1.0 ]
[ -s "$TMP/install/secrets/production/users.acl" ]
[ -f "$TMP/install/.env" ]
[ -f "$TMP/install/LICENSE" ]
printf 'REDIS_MAXMEMORY=256mb\n# operator setting\n' >"$TMP/install/.env"
cp "$TMP/install/.env" "$TMP/expected.env"
cp "$TMP/install/secrets/production/users.acl" "$TMP/expected.acl"
touch "$TMP/install/.host-access"
printf '0.2.0\n' >"$TMP/package/self-hosted-redis/VERSION"
mkdir -p "$TMP/releases/download/v0.2.0"
tar -czf "$TMP/releases/download/v0.2.0/self-hosted-redis.tar.gz" -C "$TMP/package" self-hosted-redis
(cd "$TMP/releases/download/v0.2.0" && sha256sum self-hosted-redis.tar.gz >self-hosted-redis.tar.gz.sha256)
PATH="$TMP/fake-bin:$PATH" SELF_HOSTED_REDIS_RELEASE_URL="file://$TMP/releases" "$TMP/install/bin/update" v0.2.0
[ "$(cat "$TMP/install/VERSION")" = 0.2.0 ]
cmp "$TMP/expected.env" "$TMP/install/.env"
cmp "$TMP/expected.acl" "$TMP/install/secrets/production/users.acl"
[ -f "$TMP/install/.host-access" ]
PATH="$TMP/fake-bin:$PATH" SELF_HOSTED_REDIS_RELEASE_URL="file://$TMP/releases" "$TMP/install/bin/update" --rollback
[ "$(cat "$TMP/install/VERSION")" = 0.1.0 ]
cmp "$TMP/expected.acl" "$TMP/install/secrets/production/users.acl"
# A release that fails health checks must restore the previous working code.
printf '0.3.0\n' >"$TMP/package/self-hosted-redis/VERSION"
printf '#!/bin/sh\nexit 1\n' >"$TMP/package/self-hosted-redis/bin/check"
chmod +x "$TMP/package/self-hosted-redis/bin/check"
mkdir -p "$TMP/releases/download/v0.3.0"
tar -czf "$TMP/releases/download/v0.3.0/self-hosted-redis.tar.gz" -C "$TMP/package" self-hosted-redis
(cd "$TMP/releases/download/v0.3.0" && sha256sum self-hosted-redis.tar.gz >self-hosted-redis.tar.gz.sha256)
if PATH="$TMP/fake-bin:$PATH" SELF_HOSTED_REDIS_RELEASE_URL="file://$TMP/releases" "$TMP/install/bin/update" v0.3.0; then
    echo 'FAIL: unhealthy update succeeded' >&2; exit 1
fi
[ "$(cat "$TMP/install/VERSION")" = 0.1.0 ]
cmp "$TMP/expected.acl" "$TMP/install/secrets/production/users.acl"
# Configured backups fail closed before code replacement.
printf 'RESTIC_REPOSITORY=/local-backup/repository\n' >"$TMP/install/secrets/production/backup.env"
if PATH="$TMP/fake-bin:$PATH" SELF_HOSTED_REDIS_RELEASE_URL="file://$TMP/releases" "$TMP/install/bin/update" v0.2.0; then
    echo 'FAIL: update ignored backup failure' >&2; exit 1
fi
[ "$(cat "$TMP/install/VERSION")" = 0.1.0 ]
rm "$TMP/install/secrets/production/backup.env"
# A bad checksum never creates an installation.
printf '%064d\n' 0 >"$TMP/releases/download/v0.2.0/self-hosted-redis.tar.gz.sha256"
if PATH="$TMP/fake-bin:$PATH" SELF_HOSTED_REDIS_RELEASE_URL="file://$TMP/releases" sh "$ROOT/install.sh" --version v0.2.0 --prefix "$TMP/bad"; then
    echo 'FAIL: invalid checksum accepted' >&2; exit 1
fi
[ ! -e "$TMP/bad" ]
printf 'Release lifecycle checks passed.\n'
