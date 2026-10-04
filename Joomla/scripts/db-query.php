<?php
/**
 * @package     Joomla extension test toolkit
 *
 * @copyright   Copyright (C) 2026 Svend Gundestrup. All Rights Reserved.
 * @license     http://www.gnu.org/licenses/gpl-3.0.html GNU/GPL v3
 *
 * Derived from the j2xml project (tests/scripts/db-query.php).
 */
/**
 * Database-driver-neutral query helper for Joomla integration suites.
 *
 * Runs INSIDE the Joomla container (docker exec -i <container> php db-query.php).
 * Reads SQL from STDIN, expands Joomla's #__ prefix from configuration.php,
 * connects via PDO (mysqli or pgsql — decided by the container's own config),
 * and prints scalar/column/row results for shell test runners.
 *
 * Modes:
 *   scalar                       first column of first row (default)
 *   exec                         affected row count
 *   column                       first column of all rows, one per line
 *   json                         all rows as JSON array
 *   component-param <el> <k> <v> set params[k]=v on a #__extensions component row
 *   token <userId>               create a Joomla API (joomlatoken) token, prints it
 *
 * Usage:
 *   echo "SELECT COUNT(*) FROM #__extensions" | docker exec -i $C php db-query.php scalar
 *   docker exec -i $C php db-query.php token 42
 */

declare(strict_types=1);

$mode = $argv[1] ?? 'scalar';
$sql = stream_get_contents(STDIN);
require '/var/www/html/configuration.php';

$config = new JConfig();
$driver = strtolower((string) ($config->dbtype ?? 'mysqli'));
$host = (string) $config->host;
$port = null;
if (preg_match('/^([^:]+):(\d+)$/', $host, $matches)) {
    $host = $matches[1];
    $port = $matches[2];
}
$database = (string) $config->db;
$user = (string) $config->user;
$password = (string) $config->password;
$prefix = (string) $config->dbprefix;
// Table identifiers cannot be bound parameters; whitelist the prefix so the
// interpolated table names below are guaranteed identifier-only characters.
if (!preg_match('/^[A-Za-z0-9_]+$/', $prefix)) {
    fwrite(STDERR, "Refusing unsafe table prefix in configuration.php\n");
    exit(1);
}
$sql = str_replace('#__', $prefix, $sql);

if (str_contains($driver, 'pgsql') || str_contains($driver, 'postgres')) {
    $dsn = "pgsql:host={$host};dbname={$database}" . ($port ? ";port={$port}" : '');
    $pdo = new PDO($dsn, $user, $password);
} else {
    $dsn = "mysql:host={$host};dbname={$database}" . ($port ? ";port={$port}" : '');
    $pdo = new PDO($dsn, $user, $password);
}

$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

// Set a component parameter: component-param <element> <key> <value>
if ($mode === 'component-param') {
    $element = (string) ($argv[2] ?? '');
    $key = (string) ($argv[3] ?? '');
    $value = (string) ($argv[4] ?? '');
    $table = $prefix . 'extensions';
    $statement = $pdo->prepare("SELECT params FROM {$table} WHERE element=? AND type='component'"); // NOSONAR — identifier-only prefix, validated above
    $statement->execute([$element]);
    $params = json_decode((string) $statement->fetchColumn(), true) ?: [];
    $params[$key] = $value;
    $statement = $pdo->prepare("UPDATE {$table} SET params=? WHERE element=? AND type='component'"); // NOSONAR — identifier-only prefix, validated above
    $statement->execute([json_encode($params, JSON_THROW_ON_ERROR), $element]);
    echo (string) $statement->rowCount();
    exit;
}

// Create a Joomla webservices API token for a user (the same mechanism the
// admin "Joomla API Token" user plugin uses). Token value is printed once;
// only its HMAC seed is stored.
if ($mode === 'token') {
    $userId = (int) ($argv[2] ?? 0);
    $profiles = $prefix . 'user_profiles';
    $statement = $pdo->prepare("DELETE FROM {$profiles} WHERE profile_key LIKE 'joomlatoken%' AND user_id=?"); // NOSONAR — identifier-only prefix, validated above
    $statement->execute([$userId]);
    $seed = random_bytes(32);
    $token = base64_encode('sha256:' . $userId . ':' . hash_hmac('sha256', $seed, (string) $config->secret));
    $statement = $pdo->prepare("INSERT INTO {$profiles} (user_id, profile_key, profile_value, ordering) VALUES (?, 'joomlatoken.token', ?, 1)"); // NOSONAR — identifier-only prefix, validated above
    $statement->execute([$userId, base64_encode($seed)]);
    $statement = $pdo->prepare("INSERT INTO {$profiles} (user_id, profile_key, profile_value, ordering) VALUES (?, 'joomlatoken.enabled', '1', 2)"); // NOSONAR — identifier-only prefix, validated above
    $statement->execute([$userId]);
    echo $token;
    exit;
}

$statement = $pdo->query($sql);

if ($mode === 'exec') {
    echo (string) $statement->rowCount();
    exit;
}

if ($mode === 'column') {
    $values = $statement->fetchAll(PDO::FETCH_COLUMN);
    echo implode("\n", array_map(static fn ($value): string => (string) $value, $values));
    exit;
}

if ($mode === 'json') {
    echo json_encode($statement->fetchAll(PDO::FETCH_ASSOC), JSON_THROW_ON_ERROR);
    exit;
}

echo (string) ($statement->fetchColumn() ?: '');
