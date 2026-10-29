# Optional Restic backups

Redis runs without a repository, cloud account, or backup timer. Creating a backup configuration opts into the backup commands; scheduling remains a separate step. Without configuration, `bin/backup-init`, `bin/backup`, and `bin/restore` fail before contacting Docker or a provider.

## Configuration and passwords

After `./bin/init production`, create `secrets/production/backup.env` with mode `0600`. It is a Compose environment file, not a shell script. Set `RESTIC_REPOSITORY` and the credentials required by your provider. Single-quote values containing literal dollar signs or `#` characters. The file's variables are passed to the Restic container, including provider variables outside AWS.

The scripts select `RESTIC_ENV_FILE` when explicitly exported or prefixed on a command. Relative paths are resolved from the repository root. Otherwise they use `secrets/<environment>/backup.env`, falling back to an existing `secrets/<environment>/r2.env`. An explicit missing file fails; it never falls back to a different repository. When both default files exist, `backup.env` wins. Keep separate repositories or repository prefixes for each Redis deployment and environment.

The container uses `/run/secrets/restic-password`, supplied by `secrets/<environment>/restic-password`. To connect to an existing encrypted repository, securely place its password in that file before running `backup-init`; a newly generated password cannot open an existing repository. Keep the password outside the VPS too. Do not set `RESTIC_PASSWORD` or an alternative password command in `backup.env`.

Run `./bin/backup-init`, then `./bin/backup`. Initialization opens an accessible repository or attempts to create one. An authentication or connection error still fails; it does not reset an existing repository. Backup takes a fresh Redis RDB snapshot and applies the existing retention of 7 daily, 4 weekly, and 6 monthly snapshots.

To inspect the repository directly:

```sh
RESTIC_ENV_FILE=secrets/production/backup.env docker compose --profile tools run --rm restic snapshots
RESTIC_ENV_FILE=secrets/production/backup.env docker compose --profile tools run --rm restic check
```

For legacy setups, substitute `secrets/production/r2.env`. Direct Compose commands need the explicit selection; the shell scripts provide the legacy fallback.

## Local storage

Copy `backup.env.example` into `secrets/production/backup.env` and set its permissions to `0600`. Its only required value is:

```dotenv
RESTIC_REPOSITORY=/local-backup/repository
```

`/local-backup` is the persistent `self-hosted-redis-local-restic` Docker volume. Paths refer to the container filesystem. Use a Compose volume override if you need a particular host directory or disk. Do not put a repository outside persistent mounted storage. A local repository supports recovery drills but cannot survive loss of the same server or disk.

For development, use `secrets/development/backup.env`, run scripts with `REDIS_ENV=development`, and include `-f compose.yaml -f compose.dev.yaml` in direct Compose commands. The local repository uses the separate `self-hosted-redis-dev-local-restic` volume.

## Amazon S3 or compatible storage

Create a dedicated bucket or prefix and use credentials limited to it:

```dotenv
RESTIC_REPOSITORY=s3:https://s3.us-east-1.amazonaws.com/your-bucket/redis
AWS_ACCESS_KEY_ID=replace-with-access-key
AWS_SECRET_ACCESS_KEY='replace-with-secret-key'
AWS_DEFAULT_REGION=us-east-1
```

For temporary credentials also include `AWS_SESSION_TOKEN`. For other S3 providers, use their endpoint and region. Refer to [Restic's repository setup](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html) for other backends. Backends requiring extra tools or credential files may also need a Compose image or volume override; the supplied image has SSH but does not include rclone.

## Backblaze B2

Use a bucket-scoped application key:

```dotenv
RESTIC_REPOSITORY=b2:your-bucket:redis
B2_ACCOUNT_ID=replace-with-application-key-id
B2_ACCOUNT_KEY='replace-with-application-key'
```

## Cloudflare R2

The [README bootstrap recipe](../README.md#cloudflare-r2-recipe) remains available. Alternatively, write `backup.env` directly:

```dotenv
RESTIC_REPOSITORY=s3:https://ACCOUNT_ID.r2.cloudflarestorage.com/your-bucket
AWS_ACCESS_KEY_ID=replace-with-bucket-scoped-access-key
AWS_SECRET_ACCESS_KEY='replace-with-bucket-scoped-secret-key'
AWS_DEFAULT_REGION=auto
```

The token needs Object Read & Write access to the dedicated bucket. `R2_ACCOUNT_ID` and `R2_BUCKET` are only needed by the optional bootstrap recipe, not by generic backup commands.

## Restore and scheduling

Follow the [restore drill](../README.md#restore-drill). Restore replaces the current dataset only after validating the RDB and preserving a safety copy. Run application checks before removing that copy.

Enable the [daily timer](../README.md#daily-systemd-timer) only after a successful backup and restore drill. To turn off scheduled backups, run `sudo systemctl disable --now self-hosted-redis-backup.timer`. Remove or move `backup.env` and any legacy `r2.env` if backup commands should also be disabled. Leave the repository and password intact for recovery. Removing Docker volumes can delete local repositories.
