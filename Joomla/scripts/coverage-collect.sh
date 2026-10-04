#!/usr/bin/env bash
# =============================================================================
# Collect raw coverage data from test containers and merge it into a clover
# XML report suitable for Codecov upload. (PHP-generic.)
#
# Expects coverage to have been enabled earlier via coverage-enable.sh
# (raw dumps live in /tmp/ext-cov inside each container).
#
# Raw dumps are pulled into build/coverage-raw/<container>/ and the merge is
# cumulative: every directory present under build/coverage-raw/ contributes
# to the output, so repeated calls across suites (e.g. mysql + postgres)
# merge into one report — per-container cumulative collection merges suites
# for free.
#
# Derived from the j2xml project (tests/scripts/coverage-collect.sh).
#
# Usage:
#   coverage-collect.sh <output.xml> <container> [<container> ...]
#
# Example:
#   coverage-collect.sh coverage-integration.xml ext-joomla5 ext-joomla6
# =============================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <output.xml> <container> [<container> ...]"
    exit 1
fi

OUT="$1"; shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RAW_BASE="${COVERAGE_RAW_DIR:-$ROOT_DIR/build/coverage-raw}"
mkdir -p "$RAW_BASE"

for CONTAINER in "$@"; do
    dest="$RAW_BASE/$CONTAINER"
    mkdir -p "$dest"

    if docker exec "$CONTAINER" test -d /tmp/ext-cov 2>/dev/null; then
        docker cp "$CONTAINER:/tmp/ext-cov/." "$dest/" 2>/dev/null || true
        count=$(find "$dest" -name '*.cov' | wc -l | tr -d ' ')
        echo "[coverage] $CONTAINER: collected $count dump(s)"
    else
        echo "[coverage] WARNING: $CONTAINER has no /tmp/ext-cov (was coverage-enable.sh run?)"
    fi
done

if ! command -v php >/dev/null 2>&1; then
    echo "[coverage] FAIL: php CLI not found on this host; cannot merge coverage"
    exit 1
fi

# Merge every raw directory collected so far (cumulative across suites).
dirs=()
for d in "$RAW_BASE"/*/; do
    [[ -d "$d" ]] && dirs+=("$d")
done

if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "[coverage] FAIL: no raw coverage directories under $RAW_BASE"
    exit 1
fi

php "$SCRIPT_DIR/merge-coverage.php" "$OUT" "${dirs[@]}"
