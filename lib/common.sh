#!/bin/sh

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
REDIS_ENV=${REDIS_ENV:-production}
REDIS_SECRETS_ROOT=${REDIS_SECRETS_ROOT:-$ROOT/secrets}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

validate_environment() {
    case "$REDIS_ENV" in
        production | development) ;;
        *) die "REDIS_ENV must be production or development" ;;
    esac
}

secrets_dir() {
    printf '%s/%s\n' "$REDIS_SECRETS_ROOT" "$REDIS_ENV"
}

compose() {
    config_file="$ROOT/.env"
    [ -f "$config_file" ] || config_file=/dev/null
    set -- --env-file "$config_file" "$@"
    if [ "$REDIS_ENV" = development ]; then
        docker compose -f "$ROOT/compose.yaml" -f "$ROOT/compose.dev.yaml" "$@"
    else
        docker compose -f "$ROOT/compose.yaml" "$@"
    fi
}

generate_password() {
    openssl rand -hex 32
}

password_hash() {
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
}

validate_slug() {
    printf '%s\n' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,31}$' ||
        die "project slug must start with a lowercase letter and contain only lowercase letters, digits, or hyphens (maximum 32 characters)"
}

require_secret() {
    path="$(secrets_dir)/$1"
    [ -f "$path" ] || die "missing $path; run ./bin/init $REDIS_ENV first"
}

# Credentials and arguments expand inside the container.
# shellcheck disable=SC2016
redis_admin() {
    require_secret admin-password
    compose exec -T redis sh -c \
        'REDISCLI_AUTH=$(cat /run/redis/admin-password) exec redis-cli --user admin --no-auth-warning --raw "$@"' \
        sh "$@"
}

# Credentials and arguments expand inside the container.
# shellcheck disable=SC2016
redis_backup() {
    require_secret backup-password
    compose exec -T redis sh -c \
        'REDISCLI_AUTH=$(cat /run/redis/backup-password) exec redis-cli --user backup --no-auth-warning --raw "$@"' \
        sh "$@"
}

backup_env_file() {
    file=${RESTIC_ENV_FILE:-$(secrets_dir)/backup.env}
    if [ -z "${RESTIC_ENV_FILE:-}" ] && [ ! -f "$file" ] && [ -f "$(secrets_dir)/r2.env" ]; then
        file="$(secrets_dir)/r2.env"
    fi
    case "$file" in
        /*) printf '%s\n' "$file" ;;
        *) printf '%s/%s\n' "$ROOT" "$file" ;;
    esac
}

require_backup_config() {
    file=$(backup_env_file)
    [ -f "$file" ] || die "backups are not configured; create $file from backup.env.example, then run ./bin/backup-init"
    require_secret restic-password
}

restic_run() {
    require_backup_config
    env_file=$(backup_env_file)
    RESTIC_ENV_FILE="$env_file" compose --profile tools run --rm --no-deps restic "$@"
}
