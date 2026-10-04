# Joomla/scripts

Reusable test toolkit for Joomla extension integration testing.
Derived from the j2xml project (`tests/scripts/`) — copy into your repo's
`tests/scripts/` and configure via env vars. See the compose stacks in
`engineering-memory/frameworks/joomla/docker/` and the pattern notes in
`engineering-memory/patterns/docker-test-environment.md`.

## Joomla-specific (needs a Joomla container)

| Script | Purpose |
|--------|---------|
| `install-extension.sh` | Upload + install a package zip through the real admin web installer (login → CSRF → `com_installer` upload → `#__extensions` verify → JInstaller warning gate) |
| `uninstall-extension.sh` | Uninstall via Extensions → Manage, then verify DB rows AND files are gone |
| `db-query.php` | PDO SQL adapter run inside the container — `#__` expansion, mysql/pgsql from `configuration.php`; modes: `scalar`, `exec`, `column`, `json`, `component-param`, `token` (Joomla API token generation) |
| `bootstrap.php` | Boot Joomla in CLI context inside the container (ConsoleApplication + session.cli + dummy admin identity) — for test scripts that need the CMS without a web request |
| `php-diagnostics.sh` | `enable`: redirect E_ALL to Apache error.log + truncate it; `check`: grep the log post-suite, fail on warnings scoped to your extension paths |

## PHP-generic (any containerized PHP app, no Joomla dependency)

| Script | Purpose |
|--------|---------|
| `coverage-enable.sh` | Install pcov in container, wire `auto_prepend_file`, disable opcache, reload Apache |
| `coverage-prepend.php` | Per-request pcov collector → raw `.cov` dumps in `/tmp/ext-cov` |
| `coverage-collect.sh` | `docker cp` dumps out, cumulative merge to clover via `merge-coverage.php` |
| `merge-coverage.php` | `.cov` dumps → clover XML (path rewrite + `EXT_COV_PREFIXES` filter) |
| `merge-clover.php` | Union-merge multiple clover reports (the Codecov drop fix — see `tools/codecov.md`) |

## Required env vars

```bash
# install / uninstall
JOOMLA_URL=http://localhost:8085
JOOMLA_CONTAINER=ext-joomla5
PACKAGE_ZIP=build/pkg_myext.zip          # install only
PKG_ELEMENT=pkg_myext                    # uninstall only
EXT_ELEMENTS="com_myext,pkg_myext"       # #__extensions.element values
EXT_NAME_LIKES="%MyExt%"                 # name LIKE patterns
EXT_PATHS="/var/www/html/administrator/components/com_myext ..."  # uninstall only
MIN_EXT_COUNT=2                          # install only (default 1)

# optional: JOOMLA_ADMIN_USERNAME / JOOMLA_ADMIN_PASSWORD
#           (defaults match the official image: admin / AdminAdmin123!)

# diagnostics check scope (grep -iE pattern against extension paths)
php-diagnostics.sh check ext-joomla6 "J6" 'com_myext|lib_myext|myext'

# coverage filtering
EXT_COV_PREFIXES="administrator/components/com_myext/,plugins/system/myext/"
CLOVER_ROOTS="administrator/,plugins/,libraries/"   # merge-clover (has defaults)
```

## Typical suite shape (what the caller writes)

```bash
php-diagnostics.sh enable "$C5"; php-diagnostics.sh enable "$C6"
JOOMLA_URL=$URL5 JOOMLA_CONTAINER=$C5 PACKAGE_ZIP=build/pkg_x.zip \
  EXT_ELEMENTS=... MIN_EXT_COUNT=N ./install-extension.sh
# ... your functional tests (export/import/REST/etc.) ...
php-diagnostics.sh check "$C5" "J5" 'myext'
JOOMLA_URL=$URL5 JOOMLA_CONTAINER=$C5 PKG_ELEMENT=pkg_x \
  EXT_ELEMENTS=... EXT_PATHS="..." ./uninstall-extension.sh
```

## Suite orchestration across database stacks

- Keep **one** suite script parameterized by env vars (`DB_DRIVER`,
  URLs, container names), then expose caller flags such as `--mysql`,
  `--postgresql`, and `--coverage`. Reject mutually exclusive matrix
  flags instead of silently choosing one.
- Give each database stack a distinct Compose project name:
  `docker compose --project-name ext-mysql ...` and
  `--project-name ext-postgres ...`. Identical service names plus the
  default project lets one suite reuse the other suite's app containers.
- Fixed `container_name` values can survive outside the active Compose
  project. Before `up`, remove stale containers whose
  `com.docker.compose.project` label belongs to a different stack.
- On reused Joomla containers, inspect `configuration.php` (`$dbtype`)
  before trusting failures; recreate the stack rather than interpreting
  a wrong-database result as an extension bug.
- `down -v` is still mandatory — project isolation prevents container
  reuse, while `-v` prevents database state leakage.

## Adaptation checklist

1. Copy `scripts/` + `docker/` (from `engineering-memory/frameworks/joomla/`) into your repo (`tests/`).
2. Rename `ext-*` container names / ports in the compose files if they clash.
3. Set `EXT_ELEMENTS`, `EXT_NAME_LIKES`, `EXT_PATHS`, `PKG_ELEMENT` to your
   package's manifest values.
4. Set `EXT_COV_PREFIXES` to your source dirs (must match the repo mount).
5. Write your suite orchestrator on the shape above; keep per-step logs
   quiet-on-pass (`/tmp/*.log`, tail on failure).
