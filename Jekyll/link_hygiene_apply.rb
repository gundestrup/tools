#!/usr/bin/env ruby
# frozen_string_literal: true

# link_hygiene_apply.rb — applies the plan produced by
# link_hygiene_scan.rb:
#
#   rewrite — exact-string replace the original URL with the verified
#             https/final URL everywhere it appears.
#   stale   — append an archive annotation after each occurrence:
#               markdown: ` *([arkiveret](https://web.archive.org/web/<year>/<url>))*`
#               html:     ` <a href="https://web.archive.org/...">[arkiveret]</a>`
#             `<year>` comes from the file's post date
#             (`YYYY-MM-DD-*.md` basename, else a `/YYYY/` path
#             segment, else `FALLBACK_YEAR`). If the plan carries a
#             real snapshot URL (scan ran with WAYBACK=1) it is used
#             verbatim instead.
#
# Placement rules (learned the hard way):
#   - `[text](url)`        → annotation AFTER the closing `)`
#   - `<url>` autolink     → annotation AFTER the `>` (never inside)
#   - bare url             → annotation right after it
#   - inside an HTML attr  → never
#   - longest-URL-first ordering prevents prefix collisions (a stale
#     `http://a/x` must not rewrite inside `http://a/x/y`)
#
# Usage: ruby link_hygiene_apply.rb [ROOT] [PLAN_FILE]
# Env:   LINK_EXCLUDE — comma-separated extra dirs to skip

require "json"

ROOT = ARGV[0] || Dir.pwd
PLAN_FILE = ARGV[1] || ENV.fetch("PLAN_FILE", "link_plan.json")
FALLBACK_YEAR = ENV["FALLBACK_YEAR"] || "2010"
FILE_GLOBS = %w[**/*.md **/*.markdown **/*.html].freeze
EXCLUDE_DIRS = (%w[_site .git tmp .jekyll-cache node_modules vendor] +
                (ENV["LINK_EXCLUDE"] || "").split(",").map(&:strip)).freeze

plan = JSON.parse(File.read(PLAN_FILE))
rewrite = plan["rewrite"]
stale = plan["stale"].select { |u, _| u =~ %r{^https?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}} }

files = FILE_GLOBS.flat_map { |g| Dir.glob(File.join(ROOT, g)) }
                  .reject { |f| EXCLUDE_DIRS.any? { |d| f.include?("/#{d}/") || f.end_with?("/#{d}") } }

def file_year(path, fallback)
  if (m = File.basename(path).match(/(\d{4})-\d{2}-\d{2}/))
    m[1]
  elsif (m = path.match(%r{/(\d{4})/}))
    m[1]
  else
    fallback
  end
end

replacements = rewrite.keys.sort_by { |u| -u.length }
stale_keys = stale.keys.sort_by { |u| -u.length }
n_rewritten = 0
n_annotated = 0

files.each do |file|
  src = File.read(file, encoding: "UTF-8")
  out = src.dup

  replacements.each do |orig|
    next unless out.include?(orig)
    out = out.gsub(orig) { rewrite[orig] }
    n_rewritten += 1
  end

  stale_keys.each do |orig|
    wb = if stale[orig].is_a?(String) && stale[orig].start_with?("http")
           stale[orig]
         else
           "https://web.archive.org/web/#{file_year(file, FALLBACK_YEAR)}/#{orig}"
         end
    next unless out.include?(orig)

    anno = file.end_with?(".html") ? " <a href=\"#{wb}\">[arkiveret]</a>" : " *([arkiveret](#{wb}))*"
    esc = Regexp.escape(orig)
    # Lookahead matching an already-inserted annotation — makes every
    # gsub idempotent per occurrence (the wayback URL itself embeds the
    # original URL, so a plain include?(wb) check can't detect this).
    anno_re = /(?:\*\(\[arkiveret\]|<a href="https:\/\/web\.archive\.org)/

    # markdown link target: [text](orig) -> annotation after `)`
    out = out.gsub(/(\]\(#{esc}\))(?!\s*#{anno_re.source})/) { "#{Regexp.last_match(1)}#{anno}" }
    # autolink <orig> -> annotation after `>`
    out = out.gsub(/(<#{esc}>)(?!\s*#{anno_re.source})/) { "#{Regexp.last_match(1)}#{anno}" }
    # bare url — not inside ](...), <...>, an attribute value, or an
    # existing wayback URL (where orig is preceded by `/`); and not a
    # strict prefix of a longer URL (next char must not be url-ish,
    # `/` included).
    out = out.gsub(%r{(?<!\]\()(?<!<)(?<![="'/])#{esc}(?![\w~:\/?#\[\]@!$&'()*,;=%.-])(?!\s*#{anno_re.source})}) do
      "#{orig}#{anno}"
    end
    n_annotated += 1
  end

  File.write(file, out) if out != src
end

puts "rewrote #{n_rewritten} urls, annotated #{n_annotated} stale urls"
