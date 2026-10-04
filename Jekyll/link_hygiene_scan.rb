#!/usr/bin/env ruby
# frozen_string_literal: true

# link_hygiene_scan.rb — one-off external-link hygiene pass for
# migrated content (Joomla-era sites, blog archives). Scans markdown
# + HTML sources, probes every unique external URL, and writes a
# reviewable JSON plan — nothing is modified yet.
#
# Classification per URL:
#   rewrite — http:// URL whose https:// endpoint answers (redirects
#             followed cross-domain; the FINAL url is stored, so
#             content that moved hosts resolves to its current home)
#   stale   — dead URL (DNS gone, refused, >=400): keep the link in
#             the sources, annotate it in link_hygiene_apply.rb
#   keep    — alive as-is (https already, or http-only site with no
#             https endpoint)
#
# Usage:
#   ruby link_hygiene_scan.rb [ROOT] [PLAN_FILE]
#
# Env:
#   LINK_EXCLUDE   comma-separated extra dirs to skip
#                  (default skips _site .git tmp .jekyll-cache
#                   node_modules vendor)
#   WAYBACK=1      also query the wayback availability API per stale
#                  URL — sequential + slow, and archive.org rate-limits
#                  aggressively (429s return null). Usually skip this:
#                  the year-form archive URL the apply step generates
#                  (`web.archive.org/web/<post-year>/<url>`) resolves
#                  to the closest capture with no lookup at all.
#
# Review the plan before applying — especially `stale` entries, where
# a "dead" result may just be anti-bot blocking (LinkedIn, etc.).

require "net/http"
require "uri"
require "json"

ROOT = ARGV[0] || Dir.pwd
PLAN_FILE = ARGV[1] || ENV.fetch("PLAN_FILE", "link_plan.json")
FILE_GLOBS = %w[**/*.md **/*.markdown **/*.html].freeze
EXCLUDE_DIRS = (%w[_site .git tmp .jekyll-cache node_modules vendor] +
                (ENV["LINK_EXCLUDE"] || "").split(",").map(&:strip)).freeze
THREADS = 16
TIMEOUT = 8

files = FILE_GLOBS.flat_map { |g| Dir.glob(File.join(ROOT, g)) }
                  .reject { |f| EXCLUDE_DIRS.any? { |d| f.include?("/#{d}/") || f.end_with?("/#{d}") } }

url_re = %r{https?://[^\s<>{}\[\]"'|`]+}
entries = []
files.each do |file|
  File.readlines(file, encoding: "UTF-8").each_with_index do |line, i|
    line.scan(url_re) do |m|
      url = m.dup
      url = url.sub(/[.,;:!?]+$/, "")
      url = url[0..-2] while url.end_with?(")") && url.count(")") > url.count("(")
      next if url =~ %r{^https?://(localhost|127\.0\.0\.1|example\.|.*\.test\b)}
      entries << { file:, line: i, url: }
    end
  end
end
uniq = entries.map { |e| e[:url] }.uniq.sort
puts "#{entries.size} url occurrences, #{uniq.size} unique in #{files.size} files"

def get_final(url_s, redirects_left: 5)
  uri = begin
    URI.parse(url_s)
  rescue StandardError
    return [:error, "InvalidURIError"]
  end
  return [:invalid, nil] unless uri.host

  http = Net::HTTP.new(uri.host, uri.port || (uri.scheme == "https" ? 443 : 80))
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = TIMEOUT
  http.read_timeout = TIMEOUT

  begin
    res = http.request(Net::HTTP::Get.new(uri.request_uri.empty? ? "/" : uri.request_uri,
                                        { "User-Agent" => "Mozilla/5.0 (compatible; link-check)" }))
  rescue StandardError => e
    return [:error, e.class.to_s]
  end

  loc = res["location"]
  if loc && redirects_left.positive?
    nxt = begin
      URI.join(uri.to_s, loc).to_s
    rescue StandardError
      return [:error, "bad redirect"]
    end
    return get_final(nxt, redirects_left: redirects_left - 1)
  end
  [:ok, { url: uri.to_s, scheme: uri.scheme, status: res.code.to_i }]
end

# Probe the preferred URL: https variant for http links, else itself.
probes = {}
uniq.each { |u| probes[u] = u.start_with?("http://") ? u.sub("http://", "https://") : u }
results = {}
queue = Queue.new
uniq.each { |u| queue << u }
threads = THREADS.times.map do
  Thread.new do
    until queue.empty?
      u = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      results[u] = get_final(probes[u])
      print "."
    end
  end
end
threads.each(&:join)
puts

def wayback(url)
  api = URI("https://archive.org/wayback/available?url=#{URI.encode_www_form_component(url)}")
  res = Net::HTTP.start(api.host, api.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: 20) do |h|
    h.get(api.request_uri, "User-Agent" => "link-check")
  end
  snap = JSON.parse(res.body).dig("archived_snapshots", "closest")
  snap && snap["available"] ? snap["url"].sub("http://", "https://") : nil
rescue StandardError
  nil
end

rewrite = {}
stale = {}
keep = []
uniq.each do |u|
  r = results[u]
  alive = r[0] == :ok && (r[1][:status] < 400 || r[1][:status] == 403)

  if alive && u.start_with?("http://")
    final = r[1]
    rewrite[u] = final[:scheme] == "https" ? final[:url] : u.sub("http://", "https://")
    next
  end

  if alive
    keep << u
    next
  end

  # Preferred probe failed — for http urls, fall back to the http variant.
  if u.start_with?("http://")
    r2 = get_final(u)
    if r2[0] == :ok && (r2[1][:status] < 400 || r2[1][:status] == 403)
      keep << u # alive over http only — no https endpoint exists
      next
    end
  end

  stale[u] = :wayback
end

puts "#{rewrite.size} to rewrite, #{stale.size} dead, #{keep.size} keep"

if ENV["WAYBACK"] == "1" && stale.any?
  puts "checking wayback availability (sequential — archive.org rate-limits)..."
  stale.keys.each do |u|
    stale[u] = wayback(u)
    print "~"
    sleep 0.5
  end
  puts
end

File.write(PLAN_FILE, JSON.pretty_generate({ rewrite:, stale: }))
puts "plan written to #{PLAN_FILE}"
puts "rewrites: #{rewrite.size}, stale: #{stale.size} " \
     "(#{stale.count { |_, v| v.is_a?(String) }} with snapshot)" \
     ", keep: #{keep.size}"
