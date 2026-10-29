#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)

"$ROOT/tests/static.sh"
"$ROOT/tests/operations.sh"
"$ROOT/tests/backups.sh"
"$ROOT/tests/docs.sh"
"$ROOT/tests/integration.sh"
"$ROOT/tests/r2-integration.sh"
