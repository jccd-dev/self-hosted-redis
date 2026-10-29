# Contributing

Issues and pull requests are welcome. For security problems, follow
[SECURITY.md](SECURITY.md) instead of opening an issue.

## Scope

This project stays a small, CLI-managed, single-node Redis deployment. Changes
should keep production private by default, keep credentials out of logs and
Git, and fit a 1 GB VPS. A web UI is out of scope.

## Development

Requirements: POSIX `sh`, Docker with Compose 2.24.0 or later, OpenSSL,
`shellcheck`, and `sha256sum`.

```sh
./tests/run.sh
```

`tests/static.sh`, `operations.sh`, `backups.sh`, `docs.sh`, and `releases.sh`
need no running Redis. `tests/integration.sh` and `tests/release-integration.sh`
start disposable containers; the release test needs a privileged container and
network access. `tests/r2-integration.sh` is skipped unless
`RUN_R2_INTEGRATION=1` and an R2 backup configuration are set. CI runs the same
suite on every pull request.

Scripts are POSIX `sh` and must pass `shellcheck -x`. Add or update a test for
behavior changes, and update the README or `docs/` when operator commands
change. Record user-facing changes under a new version heading in
`CHANGELOG.md`.

## Releases

Maintainers set `VERSION` to `X.Y.Z`, add the `## [X.Y.Z] - YYYY-MM-DD` section
to `CHANGELOG.md`, merge to `main`, and push tag `vX.Y.Z`. The release workflow
runs the test suite, builds the assets with `scripts/package-release.sh`, and
publishes them with that changelog section as release notes.
