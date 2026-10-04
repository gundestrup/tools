<?php
/**
 * @package     Joomla extension test toolkit
 *
 * @copyright   Copyright (C) 2026 Svend Gundestrup. All Rights Reserved.
 * @license     http://www.gnu.org/licenses/gpl-3.0.html GNU/GPL v3
 *
 * Derived from the j2xml project (tests/scripts/merge-clover.php).
 */
/**
 * Merge multiple clover XML coverage reports into a single report.
 * (PHP-generic — works for any project mixing PHPUnit + integration reports.)
 *
 * Why this exists: PHPUnit's clover output enumerates every executable line
 * of every included file, while an integration pcov merge only lists lines
 * observed inside the containers. Uploading both reports separately makes
 * Codecov resolve the conflicting line sets per file, which discards hits.
 * Merging into one file before upload keeps the union: a line is covered
 * when ANY report hit it.
 *
 * Inputs may be clover XML files or directories containing *.xml files.
 * Absolute file paths are rewritten to repo-relative paths by matching the
 * first known top-level source directory (see CLOVER_ROOTS).
 *
 * Env:
 *   CLOVER_ROOTS  comma-separated top-level directories that identify
 *                 repo-relative paths inside absolute ones.
 *                 Default: "administrator/,api/,cli/,language/,libraries/,
 *                           media/,plugins/,tests/"  (Joomla extension layout)
 *
 * Usage: php merge-clover.php <output.xml> <input.xml|dir> [<input.xml|dir> ...]
 */

if ($argc < 3) {
    fwrite(STDERR, "Usage: {$argv[0]} <output.xml> <input.xml|dir> [<input.xml|dir> ...]\n");
    exit(1);
}

$outFile = $argv[1];
$inputs  = [];

foreach (array_slice($argv, 2) as $arg) {
    if (is_dir($arg)) {
        foreach (glob(rtrim($arg, '/') . '/*.xml') ?: [] as $f) {
            $inputs[] = $f;
        }
    } elseif (is_file($arg)) {
        $inputs[] = $arg;
    }
}

if (!$inputs) {
    fwrite(STDERR, "No clover XML inputs found.\n");
    exit(1);
}

// Top-level directories that identify repo-relative paths inside absolute ones.
$roots = array_values(array_filter(array_map('trim', explode(',', (string) (getenv('CLOVER_ROOTS')
    ?: 'administrator/,api/,cli/,language/,libraries/,media/,plugins/,tests/')))));

$relativize = static function (string $name) use ($roots): string {
    $n = str_replace('\\', '/', $name);

    if ($n === '' || ($n[0] !== '/' && !preg_match('/^[A-Za-z]:\//', $n))) {
        return $n; // already relative
    }

    $best = null;
    foreach ($roots as $root) {
        $pos = strpos($n, '/' . $root);
        if ($pos !== false && ($best === null || $pos < $best)) {
            $best = $pos;
        }
    }

    return $best === null ? ltrim($n, '/') : substr($n, $best + 1);
};

$merged    = []; // relPath => [line => 0|1]
$filesUsed = 0;

foreach ($inputs as $input) {
    $xml = @simplexml_load_file($input);

    if (!$xml || !isset($xml->project)) {
        fwrite(STDERR, "Skipping unparsable clover file: $input\n");
        continue;
    }

    $filesUsed++;

    // PHPUnit nests <file> elements inside <package>; the integration merge
    // emits them directly under <project>. Match either layout.
    foreach ($xml->xpath('//project//file') ?: [] as $file) {
        $name = $relativize((string) $file['name']);

        // Drop paths that cannot be mapped to a file in this checkout —
        // stale absolute paths would otherwise surface as phantom files.
        if ($name === '' || !is_file($name)) {
            continue;
        }

        foreach ($file->xpath('.//line[@type="stmt"]') ?: [] as $line) {
            $num   = (int) $line['num'];
            $count = (int) $line['count'];

            if ($num <= 0) {
                continue;
            }

            if ($count > 0) {
                $merged[$name][$num] = 1;
            } else {
                $merged[$name][$num] = $merged[$name][$num] ?? 0;
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

echo "Merged $filesUsed report(s): $totalHits/$totalLines lines covered ({$pct}%) across " . count($merged) . " file(s)\n";
echo "Wrote $outFile\n";
