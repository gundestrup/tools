<?php
/**
 * @package     Joomla extension test toolkit
 *
 * @copyright   Copyright (C) 2026 Svend Gundestrup. All Rights Reserved.
 * @license     http://www.gnu.org/licenses/gpl-3.0.html GNU/GPL v3
 *
 * Derived from the j2xml project (tests/scripts/coverage-prepend.php).
 */
/**
 * Integration-test coverage collector (PHP-generic, works in any container).
 *
 * Installed as PHP's auto_prepend_file inside the test containers by
 * coverage-enable.sh. Records per-request line coverage via pcov and dumps
 * the raw data (Xdebug-style line format) to /tmp/ext-cov for later merging
 * by merge-coverage.php.
 */

if (!extension_loaded('pcov')) {
    return;
}

\pcov\start();

register_shutdown_function(static function (): void {
    \pcov\stop();

    $files = \pcov\waiting();

    if (!$files) {
        return;
    }

    $data = \pcov\collect(\pcov\inclusive, $files);

    \pcov\clear();

    if ($data) {
        $dir = '/tmp/ext-cov';

        if (!is_dir($dir)) {
            @mkdir($dir, 0700, true);
        }

        @file_put_contents(
            $dir . '/' . uniqid('cov_' . getmypid() . '_', true) . '.cov',
            serialize($data)
        );
    }
});
