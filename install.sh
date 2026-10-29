#!/bin/sh
set -eu

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

version=latest
prefix=/opt/self-hosted-redis
host_access=0
update=0
rollback=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version | --prefix)
            [ "$#" -ge 2 ] || fail "$1 requires a value"
            case "$1" in
                --version) version=$2 ;;
                --prefix) prefix=$2 ;;
            esac
            shift 2
            ;;
        --update)
            [ "$#" -ge 2 ] || fail '--update requires an installation path'
            update=1; prefix=$2; shift 2 ;;
        --rollback) rollback=1; shift ;;
        --host-access) host_access=1; shift ;;
        *) fail 'usage: install.sh [--version vX.Y.Z] [--prefix /absolute/path] [--host-access]' ;;
    esac
done
case "$prefix" in /*) ;; *) fail 'installation path must be absolute' ;; esac
if [ "$update" = 0 ]; then
    [ "$rollback" = 0 ] || fail 'use bin/update --rollback'
    [ ! -e "$prefix" ] && [ ! -L "$prefix" ] || fail "$prefix already exists; use bin/update"
else
    [ -d "$prefix" ] && [ ! -L "$prefix" ] || fail 'installation directory is missing or is a symlink'
    [ ! -e "$prefix/.git" ] || fail 'update requires a release installation, not a Git checkout'
    [ "${REDIS_ENV:-production}" = production ] || fail 'update supports production only'
    [ -z "${REDIS_SECRETS_ROOT:-}" ] || fail 'update requires installation-local secrets'
fi
case "$version" in
    latest) ;;
    *) printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || fail 'version must be latest or vX.Y.Z' ;;
esac
[ "$(uname -s)" = Linux ] || fail 'the installer requires Linux'
[ "$(id -u)" = 0 ] || fail 'release management requires root; use sudo sh install.sh or sudo ./bin/update'
for command in docker curl tar sha256sum openssl awk; do
    command -v "$command" >/dev/null 2>&1 || fail "missing required command: $command"
done
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable or access is denied'
compose_version=$(docker compose version --short | sed 's/^v//')
printf '%s\n' "$compose_version" | awk -F. '{exit !($1 > 2 || ($1 == 2 && $2 >= 24))}' ||
    fail 'Docker Compose 2.24.0 or later is required'
printf 'Advice: persist vm.overcommit_memory=1 and disable Transparent Huge Pages on the host.\n'

umask 077
work=$(mktemp -d)
locked=0
cutover=0
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$cutover" = 1 ]; then
        printf 'Update failed. Restoring the previous release code.\n' >&2
        if compose stop redis && restore_code "$work/old/self-hosted-redis" && compose up -d --force-recreate --wait redis && "$prefix/bin/check"; then
            printf 'Previous release recovered; update was not applied.\n' >&2
        else
            printf 'Recovery failed. Previous code is in %s/.previous.tar.gz; inspect Docker logs before retrying.\n' "$prefix" >&2
        fi
    fi
    [ "$locked" = 0 ] || rmdir "$prefix/.update-lock"
    rm -rf "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
if [ "$update" = 1 ]; then
    mkdir "$prefix/.update-lock" 2>/dev/null || fail 'another update is running (or .update-lock needs inspection)'
    locked=1
fi

# Only shipped code is replaced. Operator state and Docker volumes stay in place.
code_items='bin lib config docs systemd install.sh VERSION README.md compose.yaml compose.dev.yaml compose.host-access.yaml .env.example backup.env.example r2.env.example'
restore_code() {
    for item in $code_items; do
        rm -rf "${prefix:?}/$item" || return 1
        if [ -e "$1/$item" ]; then
            cp -pR "$1/$item" "$prefix/$item" || return 1
        fi
    done
}
if [ "$rollback" = 1 ]; then
    [ -f "$prefix/.previous.tar.gz" ] || fail 'no previous release is available'
    mkdir "$work/unpacked"
    tar -xzf "$prefix/.previous.tar.gz" -C "$work/unpacked"
    release="$work/unpacked/self-hosted-redis"
else
    base=${SELF_HOSTED_REDIS_RELEASE_URL:-https://github.com/jccd-dev/self-hosted-redis/releases}
    if [ "$version" = latest ]; then
        url="$base/latest/download"
    else
        url="$base/download/$version"
    fi
    for asset in self-hosted-redis.tar.gz self-hosted-redis.tar.gz.sha256; do
        curl --fail --silent --show-error --location --proto '=https,file' --proto-redir '=https' \
            "$url/$asset" -o "$work/$asset"
    done
    checksum=$(awk 'NR == 1 {print $1}' "$work/self-hosted-redis.tar.gz.sha256")
    printf '%s\n' "$checksum" | grep -Eq '^[0-9a-fA-F]{64}$' || fail 'invalid release checksum'
    (cd "$work" && printf '%s  self-hosted-redis.tar.gz\n' "$checksum" | sha256sum -c -) || fail 'release checksum mismatch'
    # Reject paths and links before extraction, including links to files outside staging.
    tar -tzf "$work/self-hosted-redis.tar.gz" >"$work/entries"
    awk '
        $0 !~ /^self-hosted-redis\// || $0 ~ /(^|\/)\.\.(\/|$)/ {exit 1}
    ' "$work/entries" || fail 'unsafe release archive paths'
    tar -tvzf "$work/self-hosted-redis.tar.gz" | awk 'substr($0,1,1) !~ /[-d]/ {exit 1}' || fail 'release archive contains links or special files'
    mkdir "$work/unpacked"
    tar -xzf "$work/self-hosted-redis.tar.gz" -C "$work/unpacked" --no-same-owner
    release="$work/unpacked/self-hosted-redis"
    for item in install.sh VERSION bin/init bin/check bin/update lib/common.sh compose.yaml .env.example; do
        [ -f "$release/$item" ] || fail "release is missing $item"
    done
    for item in secrets .env .git .previous.tar.gz .update-lock .host-access; do
        [ ! -e "$release/$item" ] || fail "release contains operator state: $item"
    done
    release_version=$(cat "$release/VERSION")
    printf '%s\n' "$release_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail 'invalid release VERSION'
    [ "$version" = latest ] || [ "$version" = "v$release_version" ] || fail 'release VERSION differs from requested version'
fi
# Staging uses a private umask; shipped configuration must be readable by Redis.
chmod -R a+rX,go-w,u-s,g-s "$release"
if [ "$update" = 0 ]; then
    if docker volume inspect self-hosted-redis-data >/dev/null 2>&1; then
        fail 'Redis data volume already exists; use the existing installation instead'
    fi
    mkdir -p "$(dirname "$prefix")"
    mkdir "$prefix"
    cp -pR "$release/." "$prefix/"
    cp "$prefix/.env.example" "$prefix/.env"
    [ "$host_access" = 0 ] || touch "$prefix/.host-access"
else
    [ -f "$release/VERSION" ] || fail 'previous release is incomplete'
fi
# Reuse the same Compose settings as the operation scripts.
ROOT=$prefix
. "$prefix/lib/common.sh"
ROOT=$prefix
REDIS_ENV=production
REDIS_SECRETS_ROOT="$prefix/secrets"
if [ "$update" = 0 ]; then
    docker network inspect shared-services >/dev/null 2>&1 || docker network create shared-services >/dev/null
    "$prefix/bin/init" production
    compose pull redis
    # Redis runs unprivileged and must be able to read and save the hashed ACL.
    compose run --rm --no-deps --entrypoint sh redis -c 'chown redis /run/redis /run/redis/users.acl'
    compose up -d --force-recreate --wait redis
    "$prefix/bin/check"
    printf 'Installed %s at %s. Add an application with %s/bin/project-user add <name>.\n' "$release_version" "$prefix" "$prefix"
else
    "$prefix/bin/check"
    # Detect the documented host-access override on manually installed releases too.
    container=$(compose ps -q redis)
    files=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container")
    saved_ifs=$IFS
    IFS=,
    for deployed_file in $files; do
        case "$deployed_file" in
            "$prefix/compose.yaml" | "$prefix/compose.host-access.yaml") ;;
            *) fail 'deployment uses custom Compose files; use a manual update' ;;
        esac
    done
    IFS=$saved_ifs
    case "$files" in
        *compose.host-access.yaml*) touch "$prefix/.host-access" ;;
    esac
    old_backup=$(backup_env_file)
    if [ -n "${RESTIC_ENV_FILE:-}" ] || [ -f "$old_backup" ]; then
        "$prefix/bin/backup"
    fi
    mkdir -p "$work/old/self-hosted-redis"
    for item in $code_items; do
        [ ! -e "$prefix/$item" ] || cp -pR "$prefix/$item" "$work/old/self-hosted-redis/$item"
    done
    # Pull and validate the staged release against the existing operator state.
    cp -R "$prefix/secrets" "$release/secrets"
    [ ! -f "$prefix/.env" ] || cp "$prefix/.env" "$release/.env"
    [ ! -f "$prefix/.host-access" ] || touch "$release/.host-access"
    ROOT=$release
    compose config >/dev/null
    compose pull redis
    ROOT=$prefix
    tar -czf "$prefix/.previous.tar.gz.tmp" -C "$work/old" self-hosted-redis
    mv "$prefix/.previous.tar.gz.tmp" "$prefix/.previous.tar.gz"
    compose stop redis
    cutover=1
    restore_code "$release"
    compose up -d --force-recreate --wait redis
    "$prefix/bin/check"
    cutover=0
    printf 'Release %s is running. Previous code retained in %s/.previous.tar.gz.\n' "$(cat "$prefix/VERSION")" "$prefix"
fi
