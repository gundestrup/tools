# Shell coverage via kcov — Cobertura XML for Codecov.
# Reference: pgdog-dynamic-config tests/integration-test.sh.
#
# Why a throwaway Debian container: kcov is not packaged for Alpine.
# Any Debian-family image already on the test network works — the repo
# reuses postgres:18. The run is best-effort (|| true): coverage must
# never fail a green suite.
#
# Wire this at the END of the test suite, after the real test services
# are down — it replays the generator script purely for coverage, so it
# must not interfere with asserted state.

COVERAGE_DIR="$PROJECT_DIR/coverage"          # CHANGEME: output dir
GENERATOR="/pgdog/generate-config.sh"         # CHANGEME: script to measure
SCRIPTS_DIR="/pgdog"                          # CHANGEME: --include-pattern dir
MOUNT_SRC="$PROJECT_DIR/pgdog"                # CHANGEME: host dir mounted at $SCRIPTS_DIR
BASE_IMAGE="postgres:18"                      # CHANGEME: any Debian-family image
SIDECAR_CONTAINER="pgdog-dynamic-config-test" # CHANGEME: live sidecar name

# Discover the test network from a running container instead of
# hardcoding the compose project name.
_net=$(docker inspect "$SIDECAR_CONTAINER" \
  --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' \
  2>/dev/null)
[ -n "$_net" ] || { echo "coverage: no test network found, skipping"; exit 0; }

# Stop the live sidecar so the coverage replay doesn't race it on the
# flock / generated files.
docker stop "$SIDECAR_CONTAINER" >/dev/null 2>&1 || true

mkdir -p "$COVERAGE_DIR"

# Re-run the target script under kcov inside the throwaway container.
# Mount points must match the paths the script expects in production.
# --cap-add SYS_PTRACE + seccomp=unconfined are REQUIRED: kcov works via
# ptrace, which Docker's default seccomp profile blocks.
docker run --rm \
  --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
  --network "$_net" \
  -e PGHOST=db-test \                             # CHANGEME: env the script needs
  -e PGUSER=pgdog \
  -e PGPASSWORD="$TEST_PGDOG_PASSWORD" \
  -e PGDATABASE=pgdog \
  -v "$MOUNT_SRC:$SCRIPTS_DIR" \
  -v "$COVERAGE_DIR:/coverage" \
  "$BASE_IMAGE" sh -c '
    apt-get update -qq >/dev/null 2>&1 &&
    apt-get install -y -qq kcov >/dev/null 2>&1 &&
    kcov --include-pattern='"$SCRIPTS_DIR"' /coverage '"$GENERATOR"'
    rm -f '"$SCRIPTS_DIR"'/*.toml '"$SCRIPTS_DIR"'/*.toml.tmp
  ' >/dev/null 2>&1 || true

# Notes:
# - --include-pattern limits measurement to YOUR scripts; without it kcov
#   reports on every sh file the image ships.
# - kcov output is Cobertura XML → codecov-action `directory: ./coverage`.
# - Coverage is line-based and approximate for shell (kcov tracks executed
#   lines, not branches). Informational only.
# - The final `rm` cleans generated artifacts the replay leaves behind.
