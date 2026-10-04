<?php
/**
 * @package     Joomla extension test toolkit
 *
 * @copyright   Copyright (C) 2026 Svend Gundestrup. All Rights Reserved.
 * @license     http://www.gnu.org/licenses/gpl-3.0.html GNU/GPL v3
 *
 * Derived from the j2xml project (tests/scripts/bootstrap.php).
 */
/**
 * Shared bootstrap for CLI test scripts running INSIDE a Joomla container.
 *
 * Boots the Joomla CMS far enough to use the database, JTable classes and
 * Factory::getApplication() without a web request — same mechanism as
 * Joomla's own cli/joomla.php (ConsoleApplication + session.cli aliases).
 *
 * Usage:
 *   docker cp bootstrap.php <container>:/tmp/bootstrap.php
 *   docker exec <container> php -r 'require "/tmp/bootstrap.php"; // ...'
 * or require it at the top of a test PHP script copied into the container.
 */

const _JEXEC = 1;
error_reporting(E_ALL & ~E_DEPRECATED);
ini_set('display_errors', 1);

defined('JDEBUG') or define('JDEBUG', false);

define('JPATH_BASE', '/var/www/html');

// Load defines
require JPATH_BASE . '/includes/defines.php';

// Use the modern bootstrap
require JPATH_LIBRARIES . '/bootstrap.php';

// Load the configuration
require JPATH_CONFIGURATION . '/configuration.php';

// Load the backward compatibility classmap (whichever plugin generation exists)
if (file_exists(JPATH_BASE . '/plugins/behaviour/compat/src/classmap/classmap.php')) {
    require JPATH_BASE . '/plugins/behaviour/compat/src/classmap/classmap.php';
} elseif (file_exists(JPATH_BASE . '/plugins/behaviour/compat6/src/classmap/classmap.php')) {
    require JPATH_BASE . '/plugins/behaviour/compat6/src/classmap/classmap.php';
}

// Set up a minimal application via the DI container
$container = Joomla\CMS\Factory::getContainer();

// Register the database service if not already registered
if (!$container->has('Joomla\\Database\\DatabaseInterface')) {
    $config = new JConfig();
    $container->register(new \Joomla\CMS\Service\Provider\Database(), $config);
}

// Get the database directly (the container already registers the key)
$db = $container->get('Joomla\\Database\\DatabaseInterface');

// Create the CMS console application, the same entry point used by
// Joomla's own cli/joomla.php: alias the session to the CLI driver,
// resolve the application from the container and register it with
// Factory so Factory::getApplication() works in test scripts.
$container->alias('session', 'session.cli')
    ->alias('JSession', 'session.cli')
    ->alias(\Joomla\CMS\Session\Session::class, 'session.cli')
    ->alias(\Joomla\Session\Session::class, 'session.cli')
    ->alias(\Joomla\Session\SessionInterface::class, 'session.cli');

$app = $container->get(\Joomla\Console\Application::class);
Joomla\CMS\Factory::$application = $app;

// Load a dummy admin identity via IdentityAware::loadIdentity()
// (replaces deprecated Factory::$user).
$app->loadIdentity(new Joomla\CMS\User\User(['id' => 42, 'name' => 'Admin', 'username' => 'admin']));

// Register the J* alias for DatabaseDriver if needed
if (!class_exists('JDatabaseDriver')) {
    class_alias('\\Joomla\\Database\\DatabaseDriver', 'JDatabaseDriver');
}

/**
 * Helper to get the database
 */
function getDb() {
    return Joomla\CMS\Factory::getContainer()->get(\Joomla\Database\DatabaseInterface::class);
}
