# Test helpers for POSIX sh integration suites.
# Reference: pgdog-dynamic-config tests/integration-test.sh.
# Source this from your suite: . ./test-helpers.sh
# Expects: $TIMEOUT, $INTERVAL, $TEST_RESULTS_DIR, $RESULTS_FILE
# (RESULTS_FILE="$(mktemp ...)"), and sets $PASS/$FAIL counters.

PASS=0
FAIL=0

log() {
  printf '\n\033[1m=== %s ===\033[0m\n' "$1"
}

pass() {
  printf '  \033[32m✓\033[0m %s\n' "$1"
  printf 'PASS\t%s\n' "$1" >> "$RESULTS_FILE"
  PASS=$((PASS + 1))
}

fail() {
  printf '  \033[31m✗\033[0m %s\n' "$1"
  printf 'FAIL\t%s\n' "$1" >> "$RESULTS_FILE"
  FAIL=$((FAIL + 1))
}

# Called only via trap — the disables are required, not optional.
# shellcheck disable=SC2317,SC2329
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# Hand-rolled JUnit XML for Codecov test-results upload — no test
# framework needed. Call it from the suite's EXIT-trap cleanup (NOT the
# happy path) so a report exists even when the suite dies early:
#   cleanup() {
#     write_junit
#     if [ "$FAIL" -gt 0 ]; then
#       docker compose -f "$TEST_COMPOSE" logs --tail=50 2>/dev/null || true
#     fi
#     docker compose -f "$TEST_COMPOSE" down -v --remove-orphans || true
#   }
#   trap cleanup EXIT
# The FAIL>0 log dump makes local failures as diagnosable as CI's
# `if: failure()` step.
# shellcheck disable=SC2317,SC2329
write_junit() {
  mkdir -p "$TEST_RESULTS_DIR"
  _tests=$(wc -l < "$RESULTS_FILE" | tr -d ' ')
  _fails=$(grep -c '^FAIL' "$RESULTS_FILE" || true)
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="integration-tests" tests="%s" failures="%s">\n' "$_tests" "$_fails"
    while IFS="$(printf '\t')" read -r _status _name; do
      _esc=$(xml_escape "$_name")
      if [ "$_status" = "PASS" ]; then
        printf '  <testcase classname="integration-test" name="%s"/>\n' "$_esc"
      else
        printf '  <testcase classname="integration-test" name="%s"><failure message="assertion failed"/></testcase>\n' "$_esc"
      fi
    done < "$RESULTS_FILE"
    printf '</testsuite>\n'
  } > "$TEST_RESULTS_DIR/junit.xml"
}

assert_contains() {
  _file="$1"
  _pattern="$2"
  _msg="$3"
  if grep -q "$_pattern" "$_file" 2>/dev/null; then
    pass "$_msg"
  else
    fail "$_msg (expected '$_pattern' in $_file)"
  fi
}

wait_healthy() {
  _service="$1"
  _elapsed=0
  while [ "$_elapsed" -lt "$TIMEOUT" ]; do
    _status=$(docker inspect --format='{{.State.Health.Status}}' "$_service" 2>/dev/null || echo "none")
    if [ "$_status" = "healthy" ]; then
      return 0
    fi
    printf '  Waiting for %s to become healthy (status: %s, %ds elapsed)...\n' \
      "$_service" "$_status" "$_elapsed"
    sleep "$INTERVAL"
    _elapsed=$((_elapsed + INTERVAL))
  done
  return 1
}

wait_running() {
  _service="$1"
  _elapsed=0
  while [ "$_elapsed" -lt "$TIMEOUT" ]; do
    _status=$(docker inspect --format='{{.State.Status}}' "$_service" 2>/dev/null || echo "none")
    if [ "$_status" = "running" ]; then
      return 0
    fi
    printf '  Waiting for %s to be running (status: %s, %ds elapsed)...\n' \
      "$_service" "$_status" "$_elapsed"
    sleep "$INTERVAL"
    _elapsed=$((_elapsed + INTERVAL))
  done
  return 1
}

# Polls a file for a pattern — the ONLY correct way to verify a daemon's
# autonomous loop. Never `docker exec` the worker script in its place;
# a manual invocation proves nothing about the loop.
wait_for_pattern() {
  _file="$1"
  _pattern="$2"
  _timeout="$3"
  _elapsed=0
  while [ "$_elapsed" -lt "$_timeout" ]; do
    if grep -q "$_pattern" "$_file" 2>/dev/null; then
      return 0
    fi
    sleep 1
    _elapsed=$((_elapsed + 1))
  done
  return 1
}

# Negative assertion: secrets must not leak to container logs.
# Usage: assert_no_secrets_in_logs <service> <password> [<password>...]
assert_no_secrets_in_logs() {
  _service="$1"; shift
  for _secret in "$@"; do
    if docker logs "$_service" 2>&1 | grep -q "$_secret"; then
      fail "secret leaked in $_service logs"
    else
      pass "no secret in $_service logs"
    fi
  done
}
