#!/usr/bin/env bash
# =============================================================================
# Install a Joomla extension package into a Joomla container via the
# JOOMLA web installer — i.e. exactly what a user does in the admin UI
# (Extensions → Install → Upload). No Joomla CLI required.
#
# Derived from the j2xml project (tests/scripts/install-plugin.sh).
#
# Required env:
#   JOOMLA_URL            e.g. http://localhost:8085
#   JOOMLA_CONTAINER      e.g. ext-joomla5
#   PACKAGE_ZIP           path to the built package zip on the host
#
# Optional env:
#   JOOMLA_ADMIN_USERNAME   (default: admin)
#   JOOMLA_ADMIN_PASSWORD   (default: AdminAdmin123! — the docker image default)
#   EXT_ELEMENTS            comma-separated #__extensions.element values to verify
#                           e.g. "com_myext,pkg_myext,mylib,myext"
#   EXT_NAME_LIKES          comma-separated LIKE patterns for the name column
#                           e.g. "%MyExt%,%myvendor%"
#   MIN_EXT_COUNT           expected extension rows (default: 1)
#   LABEL                   display name in logs (default: extension)
#
# Example:
#   JOOMLA_URL=http://localhost:8085 JOOMLA_CONTAINER=ext-joomla5 \
#   PACKAGE_ZIP=build/pkg_myext.zip \
#   EXT_ELEMENTS="com_myext,pkg_myext" EXT_NAME_LIKES="%MyExt%" MIN_EXT_COUNT=3 \
#   ./install-extension.sh
# =============================================================================

set -euo pipefail

JOOMLA_URL="${JOOMLA_URL:?Set JOOMLA_URL}"
CONTAINER="${JOOMLA_CONTAINER:?Set JOOMLA_CONTAINER}"
ZIP_PATH="${PACKAGE_ZIP:?Set PACKAGE_ZIP}"
ADMIN_USER="${JOOMLA_ADMIN_USERNAME:-admin}"
ADMIN_PASS="${JOOMLA_ADMIN_PASSWORD:-AdminAdmin123!}"
ELEMENTS="${EXT_ELEMENTS:-}"
LIKES="${EXT_NAME_LIKES:-}"
MIN_COUNT="${MIN_EXT_COUNT:-1}"
LABEL="${LABEL:-extension}"

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "FAIL: Package zip not found at $ZIP_PATH"
    exit 1
fi

echo "[install] Installing $LABEL into $CONTAINER ($JOOMLA_URL)..."
echo "[install] Package: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

COOKIE_FILE="$(mktemp -t joomla-install-cookies)"
RESULT_FILE="$(mktemp -t joomla-install-result)"
trap 'rm -f "$COOKIE_FILE" "$RESULT_FILE"' EXIT

# Step 1: Log in to Joomla admin
# The login form's CSRF field name IS the token: a random 32-hex name with value=1.
echo "[install] Logging in to Joomla admin..."
LOGIN_PAGE=$(curl -s -c "$COOKIE_FILE" "$JOOMLA_URL/administrator/index.php" 2>/dev/null)

TOKEN=$(echo "$LOGIN_PAGE" | sed -n 's/.*name="\([a-f0-9]\{32\}\)" value="1".*/\1/p' | head -1)
if [[ -z "$TOKEN" ]]; then
    echo "FAIL: Could not find CSRF token on login page"
    exit 1
fi

LOGIN_CODE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -L -o /dev/null -w "%{http_code}" \
    -X POST "$JOOMLA_URL/administrator/index.php" \
    -d "username=${ADMIN_USER}&passwd=${ADMIN_PASS}&option=com_login&task=login&${TOKEN}=1" \
    2>/dev/null)

if [[ "$LOGIN_CODE" != "200" ]]; then
    echo "FAIL: Login returned HTTP $LOGIN_CODE"
    exit 1
fi
echo "[install] Logged in (HTTP $LOGIN_CODE)"

# Step 2: Get the installer page and extract the per-request CSRF token
echo "[install] Fetching installer page..."
INSTALLER_PAGE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
    "$JOOMLA_URL/administrator/index.php?option=com_installer&view=install" 2>/dev/null)

CSRF=$(echo "$INSTALLER_PAGE" | sed -n 's/.*"csrf.token":[[:space:]]*"\([a-f0-9]\{32\}\)".*/\1/p' | head -1)
if [[ -z "$CSRF" ]]; then
    echo "FAIL: Could not find CSRF token on installer page"
    exit 1
fi
echo "[install] CSRF token: $CSRF"

# Step 3: Upload the package zip via Joomla's installer
echo "[install] Uploading package zip..."
INSTALL_CODE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -L -o "$RESULT_FILE" \
    -w "%{http_code}" \
    -H "X-CSRF-Token: $CSRF" \
    -X POST "$JOOMLA_URL/administrator/index.php?option=com_installer&task=install.install" \
    -F "task=install.install" \
    -F "${CSRF}=1" \
    -F "installtype=upload" \
    -F "install_package=@${ZIP_PATH}" \
    2>/dev/null)

echo "[install] Install HTTP code: $INSTALL_CODE"

# Step 4: Check the result page and the Joomla log for installer warnings.
# "File does not exist" = manifest references a file missing from the zip —
# non-fatal to Joomla but a packaging bug we want to fail on.
RESULT_HTML=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
INSTALL_WARNINGS=""

if grep -q "Installation of the package was successful\|alert-success" <<<"$RESULT_HTML"; then
    echo "[install] Installation appears successful (success message found)"
elif grep -q "alert-danger\|alert-error" <<<"$RESULT_HTML"; then
    echo "[install] Installation may have failed (error message found)"
    grep -o -m3 'alert-danger[^<]*<[^>]*>[^<]*' <<<"$RESULT_HTML"
fi

WARNINGS_HTML=$(grep -io 'alert-warning[^<]*<[^>]*>[^<]*' <<<"$RESULT_HTML" | grep -i 'File does not exist\|JInstaller' | head -10 || true)
INSTALLER_WARNINGS=$(grep -io -m10 'JInstaller[^<]*File does not exist[^<]*' <<<"$RESULT_HTML" || true)

if [[ -n "$WARNINGS_HTML" ]] || [[ -n "$INSTALLER_WARNINGS" ]]; then
    echo "[install] WARNING: Installer warnings detected:"
    [[ -n "$WARNINGS_HTML" ]]       && echo "  alert-warning: $WARNINGS_HTML"
    [[ -n "$INSTALLER_WARNINGS" ]]  && echo "  JInstaller: $INSTALLER_WARNINGS"
    INSTALL_WARNINGS="${WARNINGS_HTML}${INSTALLER_WARNINGS}"
fi

# Also grep the Joomla log dir in the container (path read from configuration.php)
JLOG_DIR=$(docker exec "$CONTAINER" php -r '
require "/var/www/html/configuration.php";
$c = new JConfig();
echo $c->log_path;
' 2>/dev/null || echo "/var/www/html/administrator/logs")

if [[ -n "$JLOG_DIR" ]]; then
    JLOG_WARNINGS=$(docker exec "$CONTAINER" bash -c "grep -r 'File does not exist' '$JLOG_DIR'/*.log* 2>/dev/null | tail -10" 2>/dev/null || true)
    if [[ -n "$JLOG_WARNINGS" ]]; then
        echo "[install] WARNING: Joomla log contains installer warnings:"
        echo "$JLOG_WARNINGS"
        INSTALL_WARNINGS="${INSTALL_WARNINGS}${JLOG_WARNINGS}"
    fi
fi

# Step 5: Verify the extensions are registered in #__extensions.
# Uses the db-query.php adapter: works for both MySQL and PostgreSQL stacks.
echo "[install] Verifying installation in database..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_HELPER="/tmp/ext-db-query.php"
docker cp "$SCRIPT_DIR/db-query.php" "$CONTAINER:$DB_HELPER" >/dev/null

# Build "element IN ('a','b') OR name LIKE '%x%'" from the env lists.
build_ext_where() {
    local where="" quoted=""
    if [[ -n "$ELEMENTS" ]]; then
        local IFS=','
        for el in $ELEMENTS; do quoted="${quoted}'${el}',"; done
        where="element IN (${quoted%,})"
    fi
    if [[ -n "$LIKES" ]]; then
        local IFS=','
        for l in $LIKES; do
            [[ -n "$where" ]] && where="$where OR "
            where="${where}name LIKE '${l}'"
        done
    fi
    printf '%s' "${where:-1=1}"
}
EXT_WHERE=$(build_ext_where)

VERIFY=$(printf 'SELECT type, element, name, enabled FROM #__extensions WHERE %s ORDER BY type, element' "$EXT_WHERE" \
    | docker exec -i "$CONTAINER" php "$DB_HELPER" json 2>&1 || true)
echo "$VERIFY"

EXT_COUNT=$(printf 'SELECT COUNT(*) FROM #__extensions WHERE %s' "$EXT_WHERE" \
    | docker exec -i "$CONTAINER" php "$DB_HELPER" scalar 2>&1 | tail -1 | tr -d '[:space:]')

if [[ "${EXT_COUNT:-0}" -ge "$MIN_COUNT" ]]; then
    echo "SUCCESS: $LABEL installed ($EXT_COUNT extensions found, expected >= $MIN_COUNT)"
    if [[ -n "$INSTALL_WARNINGS" ]]; then
        echo "FAIL: Installation completed but installer warnings were detected"
        echo "  This usually indicates a packaging problem (missing files, wrong paths in manifest)"
        exit 1
    fi
    exit 0
else
    echo "WARNING: Only ${EXT_COUNT:-0} extensions found (expected >= $MIN_COUNT)"
    grep -i "error\|fail\|warning" "$RESULT_FILE" 2>/dev/null | grep -v "script\|css\|noscript\|JavaScript" | head -5 || true
    exit 1
fi
