#!/usr/bin/env bash
# =============================================================================
# Uninstall a Joomla extension package via the admin UI (Extensions → Manage),
# then verify every extension row AND file is gone — the clean-removal gate.
#
# Derived from the j2xml project (tests/scripts/uninstall-plugin.sh).
#
# Required env:
#   JOOMLA_URL            e.g. http://localhost:8085
#   JOOMLA_CONTAINER      e.g. ext-joomla5
#   PKG_ELEMENT           package element in #__extensions, e.g. pkg_myext
#
# Optional env:
#   JOOMLA_ADMIN_USERNAME   (default: admin)
#   JOOMLA_ADMIN_PASSWORD   (default: AdminAdmin123!)
#   EXT_ELEMENTS            comma-separated elements that must all disappear
#   EXT_NAME_LIKES          comma-separated name LIKE patterns
#   EXT_PATHS               space-separated container paths that must be gone,
#                           e.g. "/var/www/html/administrator/components/com_myext
#                                 /var/www/html/components/com_myext
#                                 /var/www/html/plugins/system/myext"
#   LABEL                   display name in logs (default: extension)
# =============================================================================

set -euo pipefail

JOOMLA_URL="${JOOMLA_URL:?Set JOOMLA_URL}"
CONTAINER="${JOOMLA_CONTAINER:?Set JOOMLA_CONTAINER}"
PKG_ELEMENT="${PKG_ELEMENT:?Set PKG_ELEMENT}"
ADMIN_USER="${JOOMLA_ADMIN_USERNAME:-admin}"
ADMIN_PASS="${JOOMLA_ADMIN_PASSWORD:-AdminAdmin123!}"
ELEMENTS="${EXT_ELEMENTS:-}"
LIKES="${EXT_NAME_LIKES:-}"
EXT_PATHS="${EXT_PATHS:-}"
LABEL="${LABEL:-extension}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_HELPER="/tmp/ext-db-query.php"
docker cp "$SCRIPT_DIR/db-query.php" "$CONTAINER:$DB_HELPER" >/dev/null

COOKIE_FILE="$(mktemp -t joomla-uninstall-cookies)"
RESULT_FILE="$(mktemp -t joomla-uninstall-result)"
trap 'rm -f "$COOKIE_FILE" "$RESULT_FILE"' EXIT

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

# Step 1: Log in to Joomla admin (token field name IS the CSRF token)
echo "[uninstall] Logging in to Joomla admin..."
LOGIN_PAGE=$(curl -s -c "$COOKIE_FILE" "$JOOMLA_URL/administrator/index.php" 2>/dev/null)

TOKEN=$(echo "$LOGIN_PAGE" | sed -n 's/.*name="\([a-f0-9]\{32\}\)" value="1".*/\1/p' | head -1)
[[ -z "$TOKEN" ]] && { echo "FAIL: Could not find CSRF token on login page"; exit 1; }

LOGIN_CODE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -L -o /dev/null -w "%{http_code}" \
    -X POST "$JOOMLA_URL/administrator/index.php" \
    -d "username=${ADMIN_USER}&passwd=${ADMIN_PASS}&option=com_login&task=login&${TOKEN}=1" \
    2>/dev/null)
[[ "$LOGIN_CODE" != "200" ]] && { echo "FAIL: Login returned HTTP $LOGIN_CODE"; exit 1; }
echo "[uninstall] Logged in (HTTP $LOGIN_CODE)"

# Step 2: Find the package extension ID
echo "[uninstall] Finding $PKG_ELEMENT package extension ID..."
PKG_ID=$(printf "SELECT extension_id FROM #__extensions WHERE element='%s' AND type='package'" "$PKG_ELEMENT" \
    | docker exec -i "$CONTAINER" php "$DB_HELPER" scalar 2>&1 | tail -1 | tr -d '[:space:]')

if [[ -z "$PKG_ID" ]] || [[ "$PKG_ID" = "NOTFOUND" ]] || ! [[ "$PKG_ID" =~ ^[0-9]+$ ]]; then
    echo "[uninstall] Package not found in database - already uninstalled"
    echo "SUCCESS: $LABEL not installed"
    exit 0
fi
echo "[uninstall] Package extension ID: $PKG_ID"

# Step 3: CSRF token from the manage page
MANAGE_PAGE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
    "$JOOMLA_URL/administrator/index.php?option=com_installer&view=manage" 2>/dev/null)
CSRF=$(echo "$MANAGE_PAGE" | sed -n 's/.*"csrf.token":[[:space:]]*"\([a-f0-9]\{32\}\)".*/\1/p' | head -1)
[[ -z "$CSRF" ]] && { echo "FAIL: Could not find CSRF token on manage page"; exit 1; }
echo "[uninstall] CSRF token: $CSRF"

# Step 4: Uninstall the package (cascades to sub-extensions)
echo "[uninstall] Uninstalling package (ID: $PKG_ID)..."
UNINSTALL_CODE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -L -o "$RESULT_FILE" \
    -w "%{http_code}" \
    -H "X-CSRF-Token: $CSRF" \
    -X POST "$JOOMLA_URL/administrator/index.php?option=com_installer&task=manage.remove" \
    -F "task=manage.remove" \
    -F "cid[]=${PKG_ID}" \
    -F "${CSRF}=1" \
    2>/dev/null)
echo "[uninstall] Uninstall HTTP code: $UNINSTALL_CODE"

# Only "File does not exist" is a packaging problem; "missing or already
# uninstalled" is normal Joomla cascade noise.
UNINSTALL_RESULT_HTML=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
UNINSTALL_WARNINGS=""
if echo "$UNINSTALL_RESULT_HTML" | grep -iq "File does not exist"; then
    UNINSTALL_WARNINGS=$(echo "$UNINSTALL_RESULT_HTML" | grep -io 'JInstaller[^<]*File does not exist[^<]*\|File does not exist[^<]*' | head -10 || true)
    echo "[uninstall] WARNING: Uninstaller warnings detected (missing files):"
    echo "$UNINSTALL_WARNINGS" | sed 's/^/  /'
fi

sleep 2

# Step 5: Uninstall any remaining matching extensions individually
REMAINING_IDS=$(printf "SELECT extension_id FROM #__extensions WHERE %s" "$EXT_WHERE" \
    | docker exec -i "$CONTAINER" php "$DB_HELPER" column 2>&1 | paste -sd, -)

if [[ -n "$REMAINING_IDS" ]]; then
    echo "[uninstall] Uninstalling remaining extensions individually: $REMAINING_IDS"
    IFS=',' read -ra ID_ARRAY <<< "$REMAINING_IDS"
    for ID in "${ID_ARRAY[@]}"; do
        [[ "$ID" =~ ^[0-9]+$ ]] || continue
        echo "[uninstall] Removing extension ID: $ID"
        curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -L -o /dev/null -w "%{http_code}" \
            -H "X-CSRF-Token: $CSRF" \
            -X POST "$JOOMLA_URL/administrator/index.php?option=com_installer&task=manage.remove" \
            -F "task=manage.remove" \
            -F "cid[]=${ID}" \
            -F "${CSRF}=1" \
            2>/dev/null
        echo ""
        sleep 1
    done
fi

# Step 6: Verify DB is clean
echo "[uninstall] Verifying removal from database..."
REMAINING_COUNT=$(printf "SELECT COUNT(*) FROM #__extensions WHERE %s" "$EXT_WHERE" \
    | docker exec -i "$CONTAINER" php "$DB_HELPER" scalar 2>&1 | tail -1 | tr -d '[:space:]')
echo "[uninstall] Extensions remaining in DB: ${REMAINING_COUNT:-0}"

if [[ "${REMAINING_COUNT:-0}" -gt 0 ]]; then
    printf "SELECT type, element, name FROM #__extensions WHERE %s" "$EXT_WHERE" \
        | docker exec -i "$CONTAINER" php "$DB_HELPER" json 2>&1 | sed 's/^/  REMAINS: /' || true
fi

# Step 7: Verify files are gone
echo "[uninstall] Verifying files removed from filesystem..."
FILES_REMAINING=0
for path in $EXT_PATHS; do
    if docker exec "$CONTAINER" test -e "$path" 2>/dev/null; then
        echo "  FILE_REMAINS: $path"
        FILES_REMAINING=$((FILES_REMAINING + 1))
    fi
done
echo "[uninstall] Files remaining: $FILES_REMAINING"

# Result
if [[ "${REMAINING_COUNT:-0}" -eq 0 ]] && [[ "$FILES_REMAINING" -eq 0 ]]; then
    echo "SUCCESS: $LABEL cleanly uninstalled"
    if [[ -n "$UNINSTALL_WARNINGS" ]]; then
        echo "FAIL: Uninstall completed but uninstaller warnings were detected"
        exit 1
    fi
    exit 0
else
    echo "WARNING: ${REMAINING_COUNT:-0} extensions and $FILES_REMAINING files still remain"
    exit 1
fi
