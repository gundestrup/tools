#!/usr/bin/env bash
# =============================================================================
# Enable per-request code coverage collection inside test containers.
# (PHP-generic — nothing Joomla-specific in this script.)
#
# Installs the pcov extension, drops coverage-prepend.php in as PHP's
# auto_prepend_file, disables opcache (mandatory — opcache breaks pcov),
# and reloads Apache so every subsequent HTTP request dumps raw coverage
# data to /tmp/ext-cov inside the container.
#
# Collect the results afterwards with coverage-collect.sh.
#
# Derived from the j2xml project (tests/scripts/coverage-enable.sh).
#
# Usage:
#   coverage-enable.sh <container> <url> [<container> <url> ...]
#
# Example:
#   coverage-enable.sh ext-joomla5 http://localhost:8085 ext-joomla6 http://localhost:8086
# =============================================================================

set -euo pipefail

PCOV_VERSION="${PCOV_VERSION:-1.0.12}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREPEND_FILE="$SCRIPT_DIR/coverage-prepend.php"

if [[ $# -lt 2 ]] || [[ $(( $# % 2 )) -ne 0 ]]; then
    echo "Usage: $0 <container> <url> [<container> <url> ...]"
    exit 1
fi

while [[ $# -ge 2 ]]; do
    CONTAINER="$1"; URL="$2"; shift 2

    echo "[coverage] Waiting for $CONTAINER ($URL) ..."
    UP=0
    for _ in $(seq 1 90); do
        # Any HTTP response (including 403/302) means Apache is serving.
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/" 2>/dev/null)" != "000" ]]; then
            UP=1
            break
        fi
        sleep 2
    done
    if [[ "$UP" -ne 1 ]]; then
        echo "[coverage] FAIL: $CONTAINER never became ready at $URL"
        exit 1
    fi

    echo "[coverage] Installing pcov-$PCOV_VERSION in $CONTAINER ..."
    docker exec "$CONTAINER" bash -c "
        if ! php -m | grep -qi '^pcov$'; then
            pecl install 'pcov-$PCOV_VERSION' && docker-php-ext-enable pcov
        fi
        php -m | grep -qi '^pcov$'
    "

    echo "[coverage] Installing collector and PHP config in $CONTAINER ..."
    # /tmp/ext-cov must be writable by the Apache workers (www-data).
    docker exec "$CONTAINER" bash -c 'mkdir -p /opt/ext-coverage /tmp/ext-cov && chmod 777 /tmp/ext-cov'
    docker cp "$PREPEND_FILE" "$CONTAINER:/opt/ext-coverage/prepend.php"
    docker exec "$CONTAINER" bash -c 'printf "%s\n" \
        "auto_prepend_file=/opt/ext-coverage/prepend.php" \
        "pcov.enabled=1" \
        "pcov.directory=/var/www/html" \
        "opcache.enable=0" \
        "opcache.enable_cli=0" \
        > /usr/local/etc/php/conf.d/zz-ext-coverage.ini'

    echo "[coverage] Reloading Apache in $CONTAINER ..."
    docker exec "$CONTAINER" bash -c 'apache2ctl -k graceful 2>/dev/null || kill -USR1 1'
    sleep 2

    if docker exec "$CONTAINER" php -r 'exit(extension_loaded("pcov") ? 0 : 1);'; then
        echo "[coverage] $CONTAINER ready (pcov active)"
    else
        echo "[coverage] FAIL: pcov is not active in $CONTAINER"
        exit 1
    fi
done
