#!/usr/bin/env bash
# =============================================================================
# PHP diagnostics + error-log assertion for Joomla test containers.
#
# Derived from the j2xml project (run-all-tests.sh: enable_php_diagnostics /
# check_runtime_warnings).
#
# Why: the suite's real deprecation gate. Redirect PHP errors to Apache's
# error.log (display_errors stays OFF so pages render clean), truncate it
# before the suite runs, then grep afterwards — warnings scoped to YOUR
# extension paths fail the build; Joomla/vendor noise is reported only.
#
# Subcommands:
#   php-diagnostics.sh enable <container>
#       Write 99-tests.ini, truncate error.log, graceful-reload Apache.
#   php-diagnostics.sh check <container> <label> [scope-regex]
#       Grep error.log; FAIL if any line matches scope-regex, else report
#       the count of out-of-scope warnings. scope-regex is a grep -iE pattern
#       matched against your extension's container paths, e.g.:
#       'myext|/var/www/html/(administrator/components/com_myext|plugins/system/myext)'
#
# Example:
#   php-diagnostics.sh enable ext-joomla6
#   # ... run test suite ...
#   php-diagnostics.sh check ext-joomla6 "J6" 'com_myext|lib_myext|plg_.*myext'
# =============================================================================

set -euo pipefail

CMD="${1:?Usage: $0 enable <container> | check <container> <label> [scope-regex]}"

case "$CMD" in
  enable)
    CONTAINER="${2:?container required}"
    docker exec "$CONTAINER" bash -c 'cat > /usr/local/etc/php/conf.d/99-ext-tests.ini <<"INI"
error_reporting=E_ALL
display_errors=Off
log_errors=On
error_log=/var/log/apache2/error.log
INI
: > /var/log/apache2/error.log
apachectl -k graceful' 2>/dev/null
    echo "[diagnostics] $CONTAINER: E_ALL logging to /var/log/apache2/error.log enabled, log truncated"
    ;;

  check)
    CONTAINER="${2:?container required}"
    LABEL="${3:-$CONTAINER}"
    SCOPE="${4:-}"

    LOG=$(docker exec "$CONTAINER" bash -c \
      'grep -iE "Deprecated|deprecation|PHP Warning|PHP Notice|PHP Fatal|Warning:|Notice:" /var/log/apache2/error.log 2>/dev/null || true')
    WARNINGS=$(printf '%s\n' "$LOG" | sed '/^$/d' | wc -l | tr -d ' ')

    SCOPED=""
    if [[ -n "$SCOPE" ]]; then
        SCOPED=$(printf '%s\n' "$LOG" | grep -iE "$SCOPE" || true)
    fi

    if [[ -n "$SCOPED" ]]; then
        echo "FAIL: $LABEL: extension PHP warnings/deprecations detected"
        printf '%s\n' "$SCOPED" | head -10
        exit 1
    elif [[ "$WARNINGS" -eq 0 ]] 2>/dev/null; then
        echo "PASS: $LABEL: No PHP warnings or deprecations in Apache error log"
        exit 0
    else
        echo "INFO: $LABEL: $WARNINGS PHP warnings/deprecations in Apache log (outside extension scope)"
        exit 0
    fi
    ;;

  *)
    echo "Usage: $0 enable <container> | check <container> <label> [scope-regex]"
    exit 1
    ;;
esac
