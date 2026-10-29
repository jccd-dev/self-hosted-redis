#!/bin/sh
set -eu

# Usage: scripts/package-release.sh OUTPUT_DIR [vX.Y.Z]
# Builds the release assets described in docs/releases.md.
fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'usage: scripts/package-release.sh OUTPUT_DIR [vX.Y.Z]'
out=$1
version=$(cat "$ROOT/VERSION")
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail 'VERSION must be X.Y.Z'
[ "$#" = 1 ] || [ "$2" = "v$version" ] || fail "tag $2 does not match VERSION $version"
grep -q "^## \[$version\]" "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md has no $version entry"
# A tagged release must carry its release date, not "Unreleased".
[ "$#" = 1 ] || grep -Eq "^## \[$version\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$ROOT/CHANGELOG.md" ||
    fail "date the CHANGELOG.md $version entry before tagging"

items='install.sh VERSION LICENSE README.md bin lib config docs systemd compose.yaml compose.dev.yaml compose.host-access.yaml .env.example backup.env.example r2.env.example'
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
package="$stage/self-hosted-redis"
mkdir "$package"
# Ship only files Git would track; ignored operator state and editor files stay out.
# shellcheck disable=SC2086
git -C "$ROOT" ls-files --cached --others --exclude-standard -- $items >"$stage/files"
while IFS= read -r file; do
    [ -e "$ROOT/$file" ] || [ -L "$ROOT/$file" ] || continue # deleted but still in the index
    [ -f "$ROOT/$file" ] && [ ! -L "$ROOT/$file" ] || fail "not a regular file: $file"
    mkdir -p "$package/$(dirname "$file")"
    cp -p "$ROOT/$file" "$package/$file"
done <"$stage/files"
for item in $items; do
    [ -e "$package/$item" ] || fail "release is missing $item"
done
chmod -R a+rX,go-w "$package"

mkdir -p "$out"
COPYFILE_DISABLE=1 tar -czf "$out/self-hosted-redis.tar.gz" -C "$stage" self-hosted-redis
(cd "$out" && sha256sum self-hosted-redis.tar.gz >self-hosted-redis.tar.gz.sha256)
cp "$ROOT/install.sh" "$out/install.sh"
# Release notes: the CHANGELOG section for this version.
awk -v v="$version" '
    index($0, "## [" v "]") == 1 {on = 1; next}
    on && /^## / {exit}
    on {print}
' "$ROOT/CHANGELOG.md" >"$out/release-notes.md"
printf 'Packaged %s in %s.\n' "$version" "$out"
