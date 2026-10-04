# Jekyll utilities

Standalone scripts for maintaining Jekyll sites.

## Scripts

- `link_hygiene_scan.rb` — scans Markdown/HTML sources for external
  links, probes each unique URL (following redirects, https upgrade),
  and writes a JSON plan. For migrated content (Joomla-era posts, old
  blog archives).
- `link_hygiene_apply.rb` — applies the plan written by
  `link_hygiene_scan.rb`: rewrites dead links to
  `*([arkiveret](https://web.archive.org/web/<year>/<url>))*` and
  upgrades live links to their final URL.
- `install-hooks.sh` — drop-in git hook enabler. Copy to
  `<repo>/bin/install-hooks.sh` together with the repo's tracked hooks.

## Related

- Document management is handled by the
  [jekyll-documents](https://github.com/gundestrup/jekyll-documents) gem —
  the old `document_generator.rb` script was removed in favour of the gem.
