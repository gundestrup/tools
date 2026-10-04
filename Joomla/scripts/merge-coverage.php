<?php
/**
 * @package     Joomla extension test toolkit
 *
 * @copyright   Copyright (C) 2026 Svend Gundestrup. All Rights Reserved.
 * @license     http://www.gnu.org/licenses/gpl-3.0.html GNU/GPL v3
 *
 * Derived from the j2xml project (tests/scripts/merge-coverage.php).
 */
/**
 * Merge raw pcov dumps produced inside the test containers into a single
 * clover XML report. (PHP-generic — no Joomla API usage.)
 *
 * Each .cov file contains serialize()d output of \pcov\collect() in
 * Xdebug-style line format: file => [line => status] where status is
 * >0 executed, -1 executable-but-not-executed, -2 dead code.
 *
 * Container paths under /var/www/html/ are rewritten to repo-relative paths
 * (the repository mirrors Joomla's directory layout when mounted) and
 * filtered to the extension directories configured via EXT_COV_PREFIXES.
 *
 * Env:
 *   EXT_COV_PREFIXES  comma-separated repo-relative prefixes that belong to
 *                     the extension (required — everything else is dropped).
 *                     Example: "administrator/components/com_myext/,
 *                               plugins/system/myext/,libraries/myext/"
 *   DOC_ROOT          container docroot prefix (default /var/www/html/)
 *
 * Usage: php merge-coverage.php <output.xml> <raw-dir> [<raw-dir> ...]
 */

if ($argc < 3) {
    fwrite(STDERR, "Usage: {$argv[0]} <output.xml> <raw-dir> [<raw-dir> ...]\n");
    exit(1);
}

$outFile = $argv[1];
$dirs    = array_slice($argv, 2);

$docRoot = rtrim((string) (getenv('DOC_ROOT') ?: '/var/www/html'), '/') . '/';

$prefixes = array_values(array_filter(array_map(
    'trim',
    explode(',', (string) (getenv('EXT_COV_PREFIXES') ?: ''))
)));

if (!$prefixes) {
    fwrite(STDERR, "Set EXT_COV_PREFIXES (comma-separated repo-relative prefixes to keep).\n");
    exit(1);
}

$isExtensionFile = static function (string $rel) use ($prefixes): bool {
    foreach ($prefixes as $prefix) {
        if (str_starts_with($rel, $prefix)) {
            return true;
        }
    }

    return false;
};

$merged   = []; // relPath => [line => 0|1]
$dumpCount = 0;

foreach ($dirs as $dir) {
    foreach (glob(rtrim($dir, '/') . '/*.cov') ?: [] as $covFile) {
        $data = @unserialize((string) file_get_contents($covFile), ['allowed_classes' => false]);

        if (!is_array($data)) {
            continue;
        }

        $dumpCount++;

        foreach ($data as $file => $lines) {
            if (!is_string($file) || !str_starts_with($file, $docRoot) || !is_array($lines)) {
                continue;
            }

            $rel = substr($file, strlen($docRoot));

            if (!$isExtensionFile($rel)) {
                continue;
            }

            foreach ($lines as $line => $hit) {
                if ($hit === -1) {
                    $merged[$rel][$line] = $merged[$rel][$line] ?? 0;
                } elseif ($hit > 0) {
                    $merged[$rel][$line] = 1;
                }
                // -2 (dead code) is not an executable line: skip.
            }
        }
    }
}

ksort($merged);

$xml = new XMLWriter();
$xml->openURI($outFile);
$xml->startDocument('1.0', 'UTF-8');
$xml->setIndent(true);
$xml->startElement('coverage');
$xml->writeAttribute('generated', (string) time());
$xml->startElement('project');
$xml->writeAttribute('timestamp', (string) time());

$totalLines = 0;
$totalHits  = 0;

foreach ($merged as $file => $lines) {
    ksort($lines);

    $xml->startElement('file');
    $xml->writeAttribute('name', $file);

    $fileLines = 0;
    $fileHits  = 0;

    foreach ($lines as $num => $hit) {
        $xml->startElement('line');
        $xml->writeAttribute('num', (string) $num);
        $xml->writeAttribute('type', 'stmt');
        $xml->writeAttribute('count', (string) $hit);
        $xml->endElement();

        $fileLines++;
        $fileHits += $hit;
    }

    $xml->startElement('metrics');
    $xml->writeAttribute('loc', (string) $fileLines);
    $xml->writeAttribute('ncloc', (string) $fileLines);
    $xml->writeAttribute('classes', '0');
    $xml->writeAttribute('methods', '0');
    $xml->writeAttribute('coveredmethods', '0');
    $xml->writeAttribute('statements', (string) $fileLines);
    $xml->writeAttribute('coveredstatements', (string) $fileHits);
    $xml->writeAttribute('elements', (string) $fileLines);
    $xml->writeAttribute('coveredelements', (string) $fileHits);
    $xml->endElement(); // metrics
    $xml->endElement(); // file

    $totalLines += $fileLines;
    $totalHits  += $fileHits;
}

$xml->startElement('metrics');
$xml->writeAttribute('files', (string) count($merged));
$xml->writeAttribute('loc', (string) $totalLines);
$xml->writeAttribute('ncloc', (string) $totalLines);
$xml->writeAttribute('classes', '0');
$xml->writeAttribute('methods', '0');
$xml->writeAttribute('coveredmethods', '0');
$xml->writeAttribute('statements', (string) $totalLines);
$xml->writeAttribute('coveredstatements', (string) $totalHits);
$xml->writeAttribute('elements', (string) $totalLines);
$xml->writeAttribute('coveredelements', (string) $totalHits);
$xml->endElement(); // metrics

$xml->endElement(); // project
$xml->endElement(); // coverage
$xml->endDocument();
$xml->flush();

$pct = $totalLines ? round(100 * $totalHits / $totalLines, 2) : 0;

echo "Merged $dumpCount dump(s): $totalHits/$totalLines lines covered ({$pct}%) across " . count($merged) . " file(s)\n";
echo "Wrote $outFile\n";
