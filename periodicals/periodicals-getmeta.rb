#!/usr/bin/env ruby
# frozen_string_literal: true

#
# periodicals-getmeta.rb
#
# - Single subfolder: .periodicals_getmeta/
# - Interactive start menu: choose OCR language, runtime toggles (no OCR, force OCR, force lookups), cache TTL
# - Clear cache: OCR for ONE file / ENTIRE folder, HTTP for ENTIRE folder
# - Page-wise text extraction (pdftotext) + OCR when needed (using folder default OCR language)
# - OCR and HTTP caching in .periodicals_getmeta/
# - ISSN/ISBN detection per page with positions and context (for debugging)
# - Crossref & Wikidata lookups (with caching), interactive top-5 selection
# - Embeds PRISM/XMP into PDF (via exiftool)
# - JSONL log (state) with resume (file+sha), includes ocr_hits
# - Automatically adopts folder defaults after the first successful embed (ISSN/publisher/title)
# - Booklore sidecar integration (.metadata.json) and cover export (.cover.jpg)
#   * Sidecar is synchronized to mirror the embedded PDF metadata
#
# Requirements:
#   Ruby >= 3.2.0
#
# Dependencies:
#   brew install exiftool ocrmypdf tesseract poppler
#   (optional) brew install tesseract-lang
#
# Usage:
#   ruby periodicals-getmeta.rb "/path/to/folder/with/pdfs"
#

# Check Ruby version
if RUBY_VERSION < '3.2.0'
  warn "ERROR: Ruby 3.2.0 or higher is required (current: #{RUBY_VERSION})"
  exit 1
end

require 'json'
require 'uri'
require 'net/http'
require 'openssl'
require 'open3'
require 'fileutils'
require 'time'
require 'digest'
require 'tmpdir'

# ===================== Configuration =====================
USER_AGENT_EMAIL = "your-email@example.com"     # <-- SET YOUR EMAIL HERE (a polite API User-Agent)
MAX_CANDIDATES   = 5

CACHE_DIR          = ".periodicals_getmeta"
STATE_FILENAME     = "periodicals_getmeta.state.jsonl"
FOLDER_DEFAULTS_FN = "periodicals_getmeta.defaults.json"
LOCK_FILENAME      = "periodicals_getmeta.lock"

# Numbering modes for periodicals
NUMBERING_ISSUE_ONLY = "issue_only"      # Only issue numbers (e.g., Issue 120)
NUMBERING_VOL_ISSUE  = "volume_issue"    # Volume + Issue (e.g., Vol 5, Issue 3)

DEFAULT_CACHE_TTL_DAYS = 14
TIMEOUT_SECONDS         = 20

# Runtime options (controlled from the start menu)
# Using a module to avoid global variables
module RuntimeOptions
  @opts = {
    force_http: false,   # re-lookup: ignore HTTP cache/TTL for this run
    force_ocr:  false,   # re-OCR: ignore OCR cache for this run
    no_ocr:     false,   # run without OCR entirely
    ttl_days:   DEFAULT_CACHE_TTL_DAYS,
    debug:      false
  }

  class << self
    attr_accessor :opts
  end

  def self.[](key)
    @opts[key]
  end

  def self.[]=(key, value)
    @opts[key] = value
  end
end

def say(msg = '')
  puts(msg)
end

def info(msg)
  warn("[INFO] #{msg}") if RuntimeOptions[:debug]
end

def warn(msg)
  $stderr.puts("[WARN] #{msg}")
end

# Helper to check if a value is blank (nil, empty string, or whitespace)
def blank?(value)
  value.nil? || value.to_s.strip.empty?
end

# Helper to check if a value is present (not blank)
def present?(value)
  !blank?(value)
end

# ===================== FS helpers =====================
def cache_dir(base_dir) File.join(base_dir, CACHE_DIR) end
def ensure_cache_dir!(base_dir) FileUtils.mkdir_p(cache_dir(base_dir)) end
def state_path(base_dir) File.join(cache_dir(base_dir), STATE_FILENAME) end
def defaults_path(base_dir) File.join(cache_dir(base_dir), FOLDER_DEFAULTS_FN) end
def lock_path(base_dir) File.join(cache_dir(base_dir), LOCK_FILENAME) end

def pdf_cache_basename(pdf)
  # Use PDF filename (without extension) as cache base
  File.basename(pdf, ".pdf").gsub(/[^a-zA-Z0-9\-_]/, '_')
end

def http_cache_path(base_dir, pdf, provider)
  base = pdf_cache_basename(pdf)
  File.join(cache_dir(base_dir), "#{base}_#{provider}.json")
end

def ocr_cache_path(base_dir, pdf)
  base = pdf_cache_basename(pdf)
  File.join(cache_dir(base_dir), "#{base}_ocr.json")
end

def cleanup_cache_dir!(base_dir)
  cache = cache_dir(base_dir)
  return unless Dir.exist?(cache)
  
  # Remove all cache files but keep state, defaults, and lock
  Dir.glob(File.join(cache, "*")).each do |f|
    next if f.end_with?(STATE_FILENAME, FOLDER_DEFAULTS_FN, LOCK_FILENAME)
    FileUtils.rm_f(f)
  end
  say "Cache cleaned (kept state, defaults, and lock files)"
end

def sidecar_path_for(pdf)
  dir  = File.dirname(pdf)
  base = File.basename(pdf, ".pdf")
  File.join(dir, "#{base}.metadata.json")
end

def cover_path_for(pdf)
  dir  = File.dirname(pdf)
  base = File.basename(pdf, ".pdf")
  File.join(dir, "#{base}.cover.jpg")
end

def process_running?(pid)
  return false if pid.nil? || pid <= 0
  begin
    # Check if process exists (works on Unix/macOS)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    # Process doesn't exist
    false
  rescue Errno::EPERM
    # Process exists but we don't have permission (still running)
    true
  rescue => e
    # Unknown error, assume process might be running
    warn "Could not check process status: #{e.message}"
    true
  end
end

def acquire_lock!(base_dir)
  lp = lock_path(base_dir)
  
  if File.exist?(lp)
    # Read the PID from lock file
    lock_content = File.read(lp).strip rescue nil
    lock_pid = lock_content.to_i if lock_content
    
    # Check if the process is still running
    if lock_pid && lock_pid > 0 && process_running?(lock_pid)
      warn "\nLock file exists and process #{lock_pid} is still running."
      warn "Another instance of this script appears to be active."
      warn "Lock file: #{lp}"
      exit 2
    else
      # Stale lock - process is not running
      say "\n⚠️  Found stale lock file (process #{lock_pid || 'unknown'} is not running)"
      say "Lock file: #{lp}"
      print "Remove stale lock and continue? [Y/n]: "
      response = STDIN.gets&.strip&.downcase
      
      if response.empty? || response == 'y' || response == 'yes'
        FileUtils.rm_f(lp)
        say "Stale lock removed. Continuing...\n"
      else
        say "Aborted by user."
        exit 2
      end
    end
  end
  
  # Create new lock with current PID
  File.write(lp, "#{Process.pid}\n")
end

def release_lock!(base_dir)
  FileUtils.rm_f(lock_path(base_dir))
end

def sha256_file(path)
  digest = Digest::SHA256.new
  File.open(path, "rb") do |f|
    buf = String.new  # Create mutable string (not frozen)
    digest.update(buf) while f.read(1024 * 1024, buf)
  end
  digest.hexdigest
end

def load_json(path)
  return nil unless File.exist?(path)
  JSON.parse(File.read(path), symbolize_names: true)
rescue
  nil
end

def save_json(path, obj)
  File.write(path, JSON.pretty_generate(obj))
end

def append_state(base_dir, entry)
  File.open(state_path(base_dir), "a", encoding:"UTF-8") { |f| f.puts(entry.to_json) }
end

def load_folder_defaults(base_dir)
  defaults = load_json(defaults_path(base_dir)) || {}
  # Set default numbering mode if not present
  defaults[:numbering_mode] ||= NUMBERING_ISSUE_ONLY
  defaults
end

def save_folder_defaults(base_dir, h)
  save_json(defaults_path(base_dir), h)
end

def already_embedded?(base_dir, file, sha)
  p = state_path(base_dir)
  return false unless File.exist?(p)
  File.foreach(p) do |line|
    begin
      j = JSON.parse(line)
      if j["file"] == file && j["sha256"] == sha && j["status"] == "embedded"
        return true
      end
    rescue
    end
  end
  false
end

# ===================== Dependency checking =====================
def check_command(cmd)
  stdout, _stderr, status = Open3.capture3("which #{cmd}")
  status.success? && !stdout.strip.empty?
end

def check_dependencies!
  required = {
    'exiftool' => 'brew install exiftool',
    'pdftotext' => 'brew install poppler',
    'pdfinfo' => 'brew install poppler',
    'pdftoppm' => 'brew install poppler'
  }

  optional = {
    'ocrmypdf' => 'brew install ocrmypdf',
    'tesseract' => 'brew install tesseract'
  }

  missing_required = []
  missing_optional = []

  required.each do |cmd, install|
    missing_required << { cmd: cmd, install: install } unless check_command(cmd)
  end

  optional.each do |cmd, install|
    missing_optional << { cmd: cmd, install: install } unless check_command(cmd)
  end

  if missing_required.any?
    warn "\nERROR: Missing required dependencies:"
    missing_required.each do |dep|
      warn "  - #{dep[:cmd]}: #{dep[:install]}"
    end
    exit 1
  end

  if missing_optional.any?
    warn "\nWARNING: Missing optional dependencies (OCR will not be available):"
    missing_optional.each do |dep|
      warn "  - #{dep[:cmd]}: #{dep[:install]}"
    end
    warn "\nYou can continue without OCR, or install the dependencies and restart.\n"
  end
end

# ===================== Shell utils =====================
def run_cmd(cmd, stdin_data: nil, show_progress: false, progress_msg: nil)
  info "CMD: #{cmd}"
  
  if show_progress && progress_msg
    # Run command with progress indicator
    thread = Thread.new do
      stdout, stderr, status = Open3.capture3(cmd, stdin_data: stdin_data)
      [stdout, stderr, status.success?]
    end
    
    # Show progress while command runs
    dots = 0
    print "#{progress_msg}"
    until thread.join(2)  # Wait 2 seconds between updates
      print "."
      dots += 1
      print "\n#{progress_msg}" if dots % 20 == 0  # New line every 20 dots
    end
    puts "" # New line after completion
    thread.value
  else
    stdout, stderr, status = Open3.capture3(cmd, stdin_data: stdin_data)
    [stdout, stderr, status.success?]
  end
end

# ===================== PDF & OCR =====================
def pdf_page_count(pdf)
  out, _, ok = run_cmd(%(pdfinfo "#{pdf}"))
  return 0 unless ok
  m = out.match(/Pages:\s+(\d+)/)
  m ? m[1].to_i : 0
end

def pdftotext_page(pdf, page, out_txt)
  cmd = %(pdftotext -enc UTF-8 -layout -nopgbrk -f #{page} -l #{page} "#{pdf}" "#{out_txt}")
  _, _, ok = run_cmd(cmd)
  ok && File.exist?(out_txt)
end

def extract_pages_from_pdf(pdf)
  pages = []
  n = pdf_page_count(pdf)
  return pages if n <= 0
  Dir.mktmpdir("pgtext") do |tmp|
    (1..n).each do |p|
      out = File.join(tmp, "p#{p}.txt")
      txt = ""
      if pdftotext_page(pdf, p, out)
        txt = File.read(out, mode:"r:UTF-8") rescue ""
      end
      pages << { page: p, text: txt }
    end
  end
  pages
end

def need_ocr?(pages)
  empties = pages.count { |pg| pg[:text].strip.length < 20 }
  pages.any? && empties >= (pages.length * 0.5)
end

def ocrmypdf_once(pdf, ocr_langs)
  args = %W[ocrmypdf --skip-text]
  
  # Use all available CPU cores for faster processing
  # Detect number of cores
  cpu_count = begin
    if RUBY_PLATFORM =~ /darwin/  # macOS
      `sysctl -n hw.ncpu`.strip.to_i
    elsif RUBY_PLATFORM =~ /linux/
      `nproc`.strip.to_i
    else
      4  # Default fallback
    end
  rescue
    4  # Default fallback
  end
  
  args += ["--jobs", cpu_count.to_s] if cpu_count > 1
  
  if ocr_langs && !ocr_langs.strip.empty?
    args += ["--language", ocr_langs]
  end
  
  ocr_pdf = pdf.sub(/\.pdf$/i, ".ocr.tmp.pdf")
  args += [pdf, ocr_pdf]
  
  say "Performing OCR on #{File.basename(pdf)} (using #{cpu_count} cores)..."
  _, err, ok = run_cmd(args.map { |x| %("#{x}") }.join(" "), show_progress: true, progress_msg: "OCR in progress")
  
  ok && File.exist?(ocr_pdf) ? ocr_pdf : nil
end

def extract_text_pages_with_cache(base_dir, pdf, ocr_langs)
  print "Calculating SHA256..."
  sha = sha256_file(pdf)
  puts " done."
  
  cache_file = ocr_cache_path(base_dir, File.basename(pdf))
  say "Looking for cache: #{cache_file}"
  say "Cache exists: #{File.exist?(cache_file)}"
  say "Force OCR: #{RuntimeOptions[:force_ocr]}"

  if !RuntimeOptions[:force_ocr] && (cached = load_json(cache_file))
    say "Cache loaded successfully"
    say "Cached SHA256: #{cached[:sha256]}"
    say "Current SHA256: #{sha}"
    # Verify SHA hasn't changed
    if cached[:sha256] == sha
      say "✓ Using cached OCR results (SHA256 match)"
      return [cached[:pages], sha, cached[:source] || "cache"]
    else
      say "PDF changed (SHA mismatch), re-processing"
    end
  else
    say "Cache not loaded - Force OCR: #{RuntimeOptions[:force_ocr]}, File exists: #{File.exist?(cache_file)}"
  end

  say "Extracting text from PDF..."
  pages = extract_pages_from_pdf(pdf)
  source = "pdftotext"

  if !RuntimeOptions[:no_ocr] && need_ocr?(pages)
    if (ocr_pdf = ocrmypdf_once(pdf, ocr_langs))
      say "Extracting text from OCR'd PDF..."
      pages = extract_pages_from_pdf(ocr_pdf)
      source = "ocrmypdf"
      # Clean up temporary OCR file - text is now cached in JSON
      FileUtils.rm_f(ocr_pdf)
      info "Cleaned up temporary OCR file: #{File.basename(ocr_pdf)}"
    end
  end

  save_json(cache_file, {
    sha256: sha,
    pages: pages,
    source: source
  })
  [pages, sha, source]
end

# ===================== Regex & matches =====================
def valid_issn?(issn)
  m = issn.match(/\A([0-9]{4})-([0-9X]{4})\z/i)
  return false unless m
  digits = (m[1] + m[2]).upcase.chars
  weights = (8).downto(2).to_a
  sum = 0
  weights.each_with_index do |w, i|
    d = digits[i]
    return false unless d =~ /[0-9]/
    sum += d.to_i * w
  end
  check = (11 - (sum % 11)) % 11
  expected = (check == 10 ? 'X' : check.to_s)
  digits[7] == expected
end

def find_with_positions(text, regex)
  hits = []
  text.to_enum(:scan, regex).each do
    m = Regexp.last_match
    s, e = m.offset(0)
    hits << { value: m[0], start: s, end: e }
  end
  hits
end

def extract_issn_matches_per_page(pages)
  rx = /\bISSN\s*[: ]?\s*([0-9]{4})-([0-9Xx]{4})\b/i
  fallback = /\b([0-9]{4})-([0-9Xx]{4})\b/
  out = []
  pages.each do |pg|
    hits = find_with_positions(pg[:text], rx)
    hits = find_with_positions(pg[:text], fallback) if hits.empty?
    hits.each do |h|
      val = h[:value].gsub(/ISSN\s*[: ]?/i, '').upcase
      if valid_issn?(val)
        ctx_start = [h[:start]-40, 0].max
        ctx_end   = [h[:end]+40, pg[:text].length].min
        context   = pg[:text][ctx_start...ctx_end]
        out << { page: pg[:page], value: val, start: h[:start], end: h[:end], context: context }
      end
    end
  end
  out.uniq { |x| [x[:page], x[:value], x[:start]] }
end

def extract_isbn_matches_per_page(pages)
  rx = /\bISBN(?:-1[03])?\s*[: ]?\s*([0-9][0-9\-\s]{8,}[0-9Xx])\b/i
  out = []
  pages.each do |pg|
    hits = find_with_positions(pg[:text], rx)
    hits.each do |h|
      raw = h[:value].sub(/ISBN(?:-1[03])?\s*[: ]?/i, '')
      norm = raw.gsub(/[^0-9Xx]/, '')
      next unless [10,13].include?(norm.length)
      ctx_start = [h[:start]-40, 0].max
      ctx_end   = [h[:end]+40, pg[:text].length].min
      context   = pg[:text][ctx_start...ctx_end]
      out << { page: pg[:page], value: norm.upcase, start: h[:start], end: h[:end], context: context }
    end
  end
  out.uniq { |x| [x[:page], x[:value], x[:start]] }
end

# Extract issue numbers from OCR text (handles spaced digits like "i s s u e 1 2 0")
def extract_issue_number_from_pages(pages)
  out = []
  pages.each do |pg|
    # Pattern 1: "issue" followed by spaced digits (OCR artifact)
    # Matches: "i s s u e 1 2 0" or "issue 1 2 0" or "Issue  1  2  0"
    rx1 = /\b(?:i\s*s\s*s\s*u\s*e|issue)\s*[:#]?\s*([0-9](?:\s*[0-9]){1,5})\b/i
    pg[:text].scan(rx1) do |match|
      digits = match[0].gsub(/\s+/, '')
      out << { page: pg[:page], value: digits, source: "ocr_spaced" } if digits.length >= 1
    end
    
    # Pattern 2: Normal "Issue 120" or "Issue: 120" or "ISSUE 120, MARCH 2024"
    # Handles comma-separated formats and various punctuation
    rx2 = /\bissue\s*[:#]?\s*(\d{1,5})(?:\s*[,;]|\b)/i
    pg[:text].scan(rx2) do |match|
      out << { page: pg[:page], value: match[0], source: "normal" }
    end
    
    # Pattern 3: "Number X" format (common in academic journals)
    # Matches: "Number 6" or "No. 6"
    rx3 = /\b(?:number|no\.?)\s+(\d{1,5})\b/i
    pg[:text].scan(rx3) do |match|
      out << { page: pg[:page], value: match[0], source: "number" }
    end
  end
  out.uniq { |x| [x[:page], x[:value]] }
end

# Extract volume numbers from OCR text
def extract_volume_number_from_pages(pages)
  out = []
  pages.each do |pg|
    # Pattern: "Volume X" or "Vol. X" or "Vol X"
    rx = /\b(?:volume|vol\.?)\s+(\d{1,5})\b/i
    pg[:text].scan(rx) do |match|
      out << { page: pg[:page], value: match[0], source: "volume" }
    end
  end
  out.uniq { |x| [x[:page], x[:value]] }
end

# ===================== Filename parsing =====================
def parse_filename(fn)
  base = File.basename(fn, ".pdf")

  # Pattern 1: Title - YYYY-MM - NUMERIC_ISSUE (e.g., "Magazine - 2024-03 - 120")
  # Only accept numeric issues, not region codes like "UK"
  if base =~ /^(?<title>.+?)\s*[-–]\s*(?<year>\d{4})-(?<month>\d{2})\s*[-–]\s*(?<issue>\d+)$/i
    return { title:$~[:title].strip, year:$~[:year].to_i, month:$~[:month], issue:$~[:issue].strip, source:"filename" }
  end
  
  # Pattern 1b: Title - YYYY-MM - REGION (e.g., "National Geographic - Traveller - 2024-03 - UK")
  # Non-numeric suffix is treated as region/edition, not issue
  if base =~ /^(?<title>.+?)\s*[-–]\s*(?<year>\d{4})-(?<month>\d{2})\s*[-–]\s*(?<region>[A-Za-z]+)$/i
    return { title:$~[:title].strip, year:$~[:year].to_i, month:$~[:month], region:$~[:region].strip, source:"filename" }
  end

  # Pattern 2: Title - YYYY-MM (no issue/region)
  if base =~ /^(?<title>.+?)\s*[-–]\s*(?<year>\d{4})-(?<month>\d{2})$/i
    return { title:$~[:title].strip, year:$~[:year].to_i, month:$~[:month], source:"filename" }
  end

  # Pattern 3: Title YYYY-MM (space separated)
  if base =~ /^(?<title>.+?)\s+(?<year>\d{4})-(?<month>\d{2})/i
    return { title:$~[:title].strip, year:$~[:year].to_i, month:$~[:month], source:"filename(fuzzy)" }
  end

  # Pattern 4: Title with standalone YYYY (4 digits = year)
  if base =~ /^(?<title>.+?)\s+(?<year>\d{4})(?:\s|$)/i
    return { title:$~[:title].strip, year:$~[:year].to_i, source:"filename(year-only)" }
  end

  # Pattern 5: Title with YYYY anywhere in filename
  if base =~ /(?<year>\d{4})/
    # Extract year, use rest as title
    year_val = $~[:year].to_i
    title_part = base.gsub(/\d{4}/, '').gsub(/[-–_]+/, ' ').strip
    return { title: title_part, year: year_val, source:"filename(year-extracted)" } unless title_part.empty?
  end

  { title: base.strip, source: "filename(min)" }
end

# ===================== HTTP & cache =====================
def http_get(url, headers: {}, follow_redirects: true, max_redirects: 5)
  redirect_count = 0
  current_url = url
  
  loop do
    uri = URI(current_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.read_timeout = TIMEOUT_SECONDS
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = "periodicals-getmeta/1.0 (#{USER_AGENT_EMAIL})"
    headers.each { |k,v| req[k] = v }
    res = http.request(req)
    
    if res.is_a?(Net::HTTPSuccess)
      return res.body
    elsif follow_redirects && (res.is_a?(Net::HTTPRedirection))
      redirect_count += 1
      raise "Too many redirects (#{redirect_count})" if redirect_count > max_redirects
      current_url = res['location']
      info "Following redirect to: #{current_url}"
    else
      raise "HTTP #{res.code}"
    end
  end
end

def http_get_json(url, headers: {})
  body = http_get(url, headers: headers)
  JSON.parse(body)
end

def cached_http_get(base_dir, pdf, provider, url, headers: {})
  path = http_cache_path(base_dir, pdf, provider)
  if File.exist?(path) && !RuntimeOptions[:force_http]
    ttl_days = RuntimeOptions[:ttl_days] || DEFAULT_CACHE_TTL_DAYS
    if (Time.now - File.mtime(path)) / (24*3600.0) <= ttl_days
      return File.read(path)
    end
  end
  data = http_get(url, headers: headers)
  File.write(path, data)
  data
rescue => e
  warn "HTTP GET/cache error (#{provider}): #{e}"
  if File.exist?(path)
    File.read(path)
  else
    nil
  end
end

def cached_http_get_json(base_dir, pdf, provider, url, headers: {})
  path = http_cache_path(base_dir, pdf, provider)
  if File.exist?(path) && !RuntimeOptions[:force_http]
    ttl_days = RuntimeOptions[:ttl_days] || DEFAULT_CACHE_TTL_DAYS
    if (Time.now - File.mtime(path)) / (24*3600.0) <= ttl_days
      return JSON.parse(File.read(path)) rescue nil
    end
  end
  data = http_get_json(url, headers: headers)
  File.write(path, JSON.pretty_generate(data))
  data
rescue => e
  warn "HTTP GET/cache error (#{provider}): #{e}"
  if File.exist?(path)
    JSON.parse(File.read(path)) rescue nil
  else
    nil
  end
end

# ===================== Lookup providers =====================

# OpenAlex API - Free, no authentication required, comprehensive ISSN data
def openalex_candidates(base_dir:, pdf:, title: nil, issn: nil)
  out = []
  
  # Lookup by ISSN (most accurate)
  if issn
    url = "https://api.openalex.org/sources/issn:#{URI.encode_www_form_component(issn)}"
    data = cached_http_get_json(base_dir, pdf, "openalex_issn", url)
    if data && data['id']
      display_name = data['display_name'] || data['abbreviated_title']
      host_org = data.dig('host_organization', 'display_name')
      issn_l = data.dig('issn_l')
      out << { 
        source: "OpenAlex(ISSN)", 
        title: display_name, 
        issn: issn_l || issn, 
        publisher: host_org, 
        score: 1.0 
      }
    end
  end
  
  # Search by title if no ISSN results
  if title && out.empty?
    url = "https://api.openalex.org/sources?search=#{URI.encode_www_form_component(title)}&per-page=#{MAX_CANDIDATES}"
    data = cached_http_get_json(base_dir, pdf, "openalex_search", url)
    results = data && data['results'] || []
    results.first(MAX_CANDIDATES).each_with_index do |item, idx|
      display_name = item['display_name'] || item['abbreviated_title']
      host_org = item.dig('host_organization', 'display_name')
      issn_l = item['issn_l']
      out << { 
        source: "OpenAlex(search)", 
        title: display_name, 
        issn: issn_l, 
        publisher: host_org, 
        score: 0.85 - idx * 0.05 
      }
    end
  end
  
  out
end

def crossref_candidates(base_dir:, pdf:, title: nil, issn: nil)
  out = []
  if issn
    url = "https://api.crossref.org/journals/#{URI.encode_www_form_component(issn)}"
    data = cached_http_get_json(base_dir, pdf, "crossref_journal", url)
    if (msg = data && data['message'])
      out << { source:"Crossref(journal)", title:msg['title'], issn:(Array(msg['ISSN']).first || issn), publisher:msg['publisher'], score:1.0 }
    end
  end
  if title && out.empty?
    url = "https://api.crossref.org/journals?query=#{URI.encode_www_form_component(title)}"
    data = cached_http_get_json(base_dir, pdf, "crossref_search", url)
    items = data && data.dig('message','items') || []
    items.first(MAX_CANDIDATES).each_with_index do |it, idx|
      out << { source:"Crossref(search)", title:it['title'], issn:Array(it['ISSN']).first, publisher:it['publisher'], score:0.8 - idx*0.05 }
    end
  end
  
  # Fallback to ISSN Portal search if no results
  if out.empty? && issn
    out += issn_portal_lookup(base_dir: base_dir, pdf: pdf, issn: issn)
  end
  
  out
end

def wikidata_candidates(base_dir:, pdf:, title: nil, issn: nil)
  return [] if blank?(title)
  out = []
  s_url = "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=#{URI.encode_www_form_component(title)}&language=en&type=item&limit=#{MAX_CANDIDATES}&format=json"
  s = cached_http_get_json(base_dir, pdf, "wikidata_search", s_url, headers: {"Accept"=>"application/json"})
  (s && s['search'] || []).first(MAX_CANDIDATES).each do |hit|
    qid = hit['id']
    ent = cached_http_get_json(base_dir, pdf, "wikidata_entity", "https://www.wikidata.org/wiki/Special:EntityData/#{qid}.json")
    entity = ent && ent.dig('entities', qid) || {}
    claims = entity['claims'] || {}
    issn_vals = (claims['P236'] || []).map { |c| c.dig('mainsnak','datavalue','value') }.compact
    publisher_qids = (claims['P123'] || []).map { |c| c.dig('mainsnak','datavalue','value','id') }.compact
    pubname = nil
    publisher_qids.each do |pq|
      pjson = cached_http_get_json(base_dir, pdf, "wikidata_entity", "https://www.wikidata.org/wiki/Special:EntityData/#{pq}.json")
      lab = pjson && (pjson.dig('entities', pq, 'labels', 'en', 'value') || pjson.dig('entities', pq, 'labels', 'da', 'value'))
      pubname ||= lab
    end
    out << { source:"Wikidata", title:(entity.dig('labels','en','value') || entity.dig('labels','da','value') || hit['label'] || title), issn:issn_vals&.first, publisher:pubname, score:0.7 }
  end
  out
end

# ISSN Portal lookup - fallback when other databases fail
def issn_portal_lookup(base_dir:, pdf:, issn:)
  out = []
  return out unless valid_issn?(issn)

  # ISSN Portal URL format: https://portal.issn.org/resource/ISSN/2380-3878
  url = "https://portal.issn.org/resource/ISSN/#{issn.gsub('-', '')}"
  info "Searching ISSN Portal: #{issn}"
  
  resp = cached_http_get(base_dir, pdf, "issn_portal", url, headers: {"Accept" => "text/html"})
  return out unless resp

  # Parse HTML to extract title from: <span class="display display--l display--semibold display--primary">Title</span>
  if resp =~ /<span class="display display--l display--semibold display--primary">\s*([^<]+)\s*<\/span>/m
    title = $1.strip
    
    # Try to extract issuing body (publisher)
    publisher = nil
    if resp =~ /<dt class="record__field-label">Issuing body:<\/dt>\s*<dd[^>]*>([^<]+)<\/dd>/m
      publisher = $1.strip
    end
    
    out << {
      title: title,
      issn: issn,
      publisher: publisher,
      source: "ISSN Portal",
      score: 0.75
    }
    info "Found in ISSN Portal: #{title}"
  end

  out
end

def dedup_candidates(cands)
  seen = {}
  out = []
  cands.each do |c|
    key = [c[:issn], c[:title]&.downcase&.strip, c[:publisher]&.downcase&.strip].join("|")
    next if seen[key]
    seen[key] = true
    out << c
  end
  out.sort_by { |c| [-c[:score].to_f, (c[:issn] ? 0 : 1)] }.first(MAX_CANDIDATES)
end

# ===================== ExifTool (write metadata) =====================
def write_exiftool(pdf, md)
  args = []
  title = md[:dc_title] || "#{md[:publication_name]} #{md[:pubdate]} (Issue #{md[:issue]})".strip
  args << %Q{"-XMP-dc:Title=#{title}"}
  args << %Q{"-XMP-prism:publicationName=#{md[:publication_name]}"} if md[:publication_name]
  args << %Q{"-XMP-prism:publicationDate=#{md[:pubdate]}"} if md[:pubdate]
  args << %Q{"-XMP-prism:issueIdentifier=#{md[:issue]}"} if md[:issue]
  args << %Q{"-XMP-prism:volume=#{md[:volume]}"} if md[:volume]
  args << %Q{"-XMP-prism:issn=#{md[:issn]}"} if md[:issn]
  keywords = [md[:publication_name], md[:year], md[:month], (md[:issue] && "Issue #{md[:issue]}")].compact.join("; ")
  args << %Q{"-XMP-pdf:Keywords=#{keywords}"} unless keywords.empty?
  args << "-overwrite_original"
  cmd = %(exiftool #{args.join(' ')} "#{pdf}")
  _, stderr, ok = run_cmd(cmd)
  warn "ExifTool error: #{stderr}" unless ok
  ok
end

# ===================== Interaction =====================
def prompt_select(file, parsed, cands, folder_defaults, defaults_complete: false, preview_metadata: nil, extracted_metadata: nil)
  say "\n—"
  say "File: #{File.basename(file)}"
  
  if cands.empty?
    if defaults_complete && preview_metadata
      # Show metadata preview with sources
      say "\nMetadata to be used:"
      say "  Publication: #{preview_metadata[:publication_name] || '(none)'} <- from #{preview_metadata[:pub_source]}"
      say "  Publisher:   #{preview_metadata[:publisher] || '(none)'} <- from #{preview_metadata[:publisher_source]}"
      say "  ISSN:        #{preview_metadata[:issn] || '(none)'} <- from #{preview_metadata[:issn_source]}"
      say "  Year:        #{preview_metadata[:year] || '(none)'} <- from #{preview_metadata[:year_source]}"
      say "  Month:       #{preview_metadata[:month] || '(none)'} <- from #{preview_metadata[:month_source]}"
      say "  Issue:       #{preview_metadata[:issue] || '(none)'} <- from #{preview_metadata[:issue_source]}"
      say "  Volume:      #{preview_metadata[:volume] || '(none)'} <- from #{preview_metadata[:volume_source]}" if preview_metadata[:volume]
      say ""
      say "[D] Use defaults as-is  [F] Field-by-field review/edit  [S] Skip  [A] Abort"
      print "> "
      inp = STDIN.gets&.strip&.upcase
      return { action: 'abort' } if inp == 'A'
      return { action: 'skip' }  if inp == 'S'
      return { action: 'field_by_field' } if inp == 'F'
      return { action: 'defaults' } if inp == 'D' || inp.empty?
      return { action: 'defaults' }  # Default to defaults if unknown input
    else
      say "From filename: title='#{parsed[:title]}' year='#{parsed[:year]}' month='#{parsed[:month]}' issue='#{parsed[:issue]}'"
      say "Folder defaults → title: #{folder_defaults[:publication_name] || '-'} | ISSN: #{folder_defaults[:issn] || '-'} | publisher: #{folder_defaults[:publisher] || '-'}"
      
      # Show extracted metadata from OCR if available
      if extracted_metadata
        say "\nExtracted from OCR:"
        say "  ISSN: #{extracted_metadata[:issn].join(', ')}" if extracted_metadata[:issn]&.any?
        say "  Volume: #{extracted_metadata[:volume].join(', ')}" if extracted_metadata[:volume]&.any?
        say "  Issue: #{extracted_metadata[:issue].join(', ')}" if extracted_metadata[:issue]&.any?
      end
      
      say "\nNo candidates found in web databases. [M]anual / [S]kip / [A]bort?"
      print "> "
      inp = STDIN.gets&.strip&.upcase
      return { action: 'abort' } if inp == 'A'
      return { action: 'skip' }  if inp == 'S'
      return { action: 'manual' }
    end
  end

  say "From filename: title='#{parsed[:title]}' year='#{parsed[:year]}' month='#{parsed[:month]}' issue='#{parsed[:issue]}'"
  say "Folder defaults → title: #{folder_defaults[:publication_name] || '-'} | ISSN: #{folder_defaults[:issn] || '-'} | publisher: #{folder_defaults[:publisher] || '-'}"
  say "\nCandidates:"
  cands.each_with_index do |c, i|
    say "[#{i+1}] #{c[:title]}  | ISSN: #{c[:issn] || '-'}  | Publisher: #{c[:publisher] || '-'}  (#{c[:source]})"
  end
  if defaults_complete
    say "[D] Use folder defaults    [F] Field-by-field    [S] Skip    [A] Abort    [R] Re-search"
    print "Choose (1-#{cands.length}/D/F/S/A/R): "
  else
    say "[D] Use folder defaults    [M] Manual    [S] Skip    [A] Abort    [R] Re-search with another title"
    print "Choose (1-#{cands.length}/D/M/S/A/R): "
  end
  inp = STDIN.gets&.strip
  return { action: 'abort' } if inp&.upcase == 'A'
  return { action: 'skip' }  if inp&.upcase == 'S'
  return { action: 'manual' } if inp&.upcase == 'M'
  return { action: 'defaults' } if inp&.upcase == 'D'
  return { action: 'field_by_field' } if inp&.upcase == 'F'
  return { action: 'rescan' } if inp&.upcase == 'R'
  idx = inp.to_i
  if idx >= 1 && idx <= cands.length
    { action: 'pick', pick: cands[idx-1] }
  else
    { action: 'manual' }
  end
end

def build_metadata(file, parsed, pick, defaults, volume_hits: [])
  pubname  = pick[:title] || defaults[:publication_name] || parsed[:title]
  issn     = pick[:issn] || defaults[:issn]
  publisher= pick[:publisher] || defaults[:publisher]
  year     = parsed[:year]
  month    = parsed[:month] || "01"
  pubdate  = [year, month].compact.join("-")
  # Use volume from parsed, or from OCR hits if available
  volume   = parsed[:volume] || (volume_hits.first&.dig(:value))
  {
    publication_name: pubname,
    issn: issn,
    publisher: publisher,
    year: year,
    month: month,
    pubdate: pubdate,
    issue: parsed[:issue],
    volume: volume,
    dc_title: nil
  }
end

# Show metadata preview with sources
def show_metadata_preview(md, parsed, defaults, pick)
  say "\n=== Metadata Preview ==="
  
  # Determine source for each field
  pub_source = if pick && pick[:title]
    pick[:source] || "selected"
  elsif defaults[:publication_name]
    "defaults"
  else
    "filename"
  end
  
  issn_source = if pick && pick[:issn]
    pick[:source] || "selected"
  elsif defaults[:issn]
    "defaults"
  else
    "OCR/manual"
  end
  
  publisher_source = if pick && pick[:publisher]
    pick[:source] || "selected"
  elsif defaults[:publisher]
    "defaults"
  else
    "manual"
  end
  
  year_source = parsed[:year] ? "filename" : "manual"
  month_source = parsed[:month] ? "filename" : "default (01)"
  issue_source = parsed[:issue] ? parsed[:source] || "filename/OCR" : "none"
  volume_source = md[:volume] ? "manual" : "none"
  
  say "Publication: #{md[:publication_name] || '(none)'} <- from #{pub_source}"
  say "Publisher:   #{md[:publisher] || '(none)'} <- from #{publisher_source}"
  say "ISSN:        #{md[:issn] || '(none)'} <- from #{issn_source}"
  say "Year:        #{md[:year] || '(none)'} <- from #{year_source}"
  say "Month:       #{md[:month] || '(none)'} <- from #{month_source}"
  say "Issue:       #{md[:issue] || '(none)'} <- from #{issue_source}"
  say "Volume:      #{md[:volume] || '(none)'} <- from #{volume_source}" if md[:volume]
  say "==========================\n"
end

def manual_edit(md)
  say "Manual edit (press Enter to keep current value):"
  print "publication_name [#{md[:publication_name]}]: "; t = STDIN.gets&.strip; md[:publication_name] = t unless t.nil? || t.empty?
  
  # ISSN input with validation
  loop do
    print "issn [#{md[:issn]}]: "
    t = STDIN.gets&.strip
    if t.nil? || t.empty?
      break  # Keep current value
    elsif valid_issn?(t)
      md[:issn] = t
      break
    else
      warn "⚠️  Invalid ISSN checksum: #{t}"
      print "Press ENTER to use anyway, or type a new value: "
      override = STDIN.gets&.strip
      if override.nil? || override.empty?
        md[:issn] = t  # User pressed Enter to override
        say "Using ISSN despite invalid checksum: #{t}"
        break
      else
        # User entered a new value, loop to validate it
        t = override
        if valid_issn?(t)
          md[:issn] = t
          break
        else
          warn "⚠️  Invalid ISSN checksum: #{t}"
          print "Press ENTER to use anyway, or type a new value: "
          final = STDIN.gets&.strip
          if final.nil? || final.empty?
            md[:issn] = t
            say "Using ISSN despite invalid checksum: #{t}"
            break
          end
          # If user keeps entering values, continue loop
        end
      end
    end
  end
  
  print "publisher [#{md[:publisher]}]: "; t = STDIN.gets&.strip; md[:publisher] = t unless t.nil? || t.empty?
  print "year [#{md[:year]}]: "; t = STDIN.gets&.strip; md[:year] = t.to_i unless t.nil? || t.empty?
  print "month [#{md[:month]}]: "; t = STDIN.gets&.strip; md[:month] = t unless t.nil? || t.empty?
  print "issue [#{md[:issue]}]: "; t = STDIN.gets&.strip; md[:issue] = t unless t.nil? || t.empty?
  print "volume [#{md[:volume]}]: "; t = STDIN.gets&.strip; md[:volume] = t unless t.nil? || t.empty?
  print "dc_title (custom) [#{md[:dc_title]}]: "; t = STDIN.gets&.strip; md[:dc_title] = t unless t.nil? || t.empty?
  md[:pubdate] = [md[:year], md[:month]].compact.join("-")
  md
end

# Field-by-field editor with multi-source suggestions
def field_by_field_edit(md, sources)
  say "\n=== Field-by-field metadata editor ==="
  say "For each field, choose from suggestions or enter custom value"
  say "Press [ENTER] to accept current/default value\n"
  
  # Helper to show field options
  def show_field_options(field_name, current_value, suggestions)
    say "\n--- #{field_name.to_s.upcase.gsub('_', ' ')} ---"
    say "Current: #{current_value || '(none)'}" if current_value
    
    if suggestions && !suggestions.empty?
      say "Suggestions:"
      suggestions.each_with_index do |sugg, idx|
        say "  [#{idx + 1}] #{sugg[:value]} (from #{sugg[:source]})"
      end
      say "  [0] Enter custom value"
      print "Choose [1-#{suggestions.length}/0] or ENTER to keep current: "
    else
      say "No suggestions available."
      print "Enter value or ENTER to keep current: "
    end
  end
  
  # Process each field
  [:publication_name, :issn, :publisher, :year, :month, :issue, :volume].each do |field|
    suggestions = sources[field] || []
    current = md[field]
    
    show_field_options(field, current, suggestions)
    choice = STDIN.gets&.strip
    
    if choice.nil? || choice.empty?
      # Keep current value
      next
    elsif choice == '0'
      # Custom input
      if field == :issn
        # ISSN with validation
        loop do
          print "Enter custom #{field}: "
          custom = STDIN.gets&.strip
          if custom.nil? || custom.empty?
            break  # Keep current value
          elsif valid_issn?(custom)
            md[field] = custom
            break
          else
            warn "⚠️  Invalid ISSN checksum: #{custom}"
            print "Press ENTER to use anyway, or type a new value: "
            override = STDIN.gets&.strip
            if override.nil? || override.empty?
              md[field] = custom
              say "Using ISSN despite invalid checksum: #{custom}"
              break
            end
            custom = override  # Try again with new value
          end
        end
      else
        print "Enter custom #{field}: "
        custom = STDIN.gets&.strip
        md[field] = (field == :year ? custom.to_i : custom) unless custom.nil? || custom.empty?
      end
    else
      # Select from suggestions
      idx = choice.to_i - 1
      if idx >= 0 && idx < suggestions.length
        value = suggestions[idx][:value]
        # Validate ISSN if selecting from suggestions
        if field == :issn && !valid_issn?(value)
          warn "⚠️  Invalid ISSN checksum: #{value}"
          print "Press ENTER to use anyway, or enter a different value: "
          override = STDIN.gets&.strip
          if override.nil? || override.empty?
            md[field] = value
            say "Using ISSN despite invalid checksum: #{value}"
          elsif !override.empty?
            # User entered a new value
            if valid_issn?(override)
              md[field] = override
              say "✓ Using: #{override}"
            else
              warn "⚠️  Invalid ISSN checksum: #{override}"
              print "Press ENTER to use anyway: "
              final = STDIN.gets&.strip
              md[field] = override
              say "Using ISSN despite invalid checksum: #{override}"
            end
          end
        else
          md[field] = (field == :year ? value.to_i : value)
          say "✓ Selected: #{value}"
        end
      else
        say "Invalid choice, keeping current value"
      end
    end
  end
  
  md[:pubdate] = [md[:year], md[:month]].compact.join("-")
  md
end

# Collect all suggestions for metadata fields from multiple sources
def collect_field_suggestions(parsed, defaults, cands, issue_hits, issn_hits)
  sources = {}
  
  # Publication name suggestions
  sources[:publication_name] = []
  sources[:publication_name] << { value: defaults[:publication_name], source: "defaults" } if present?(defaults[:publication_name])
  sources[:publication_name] << { value: parsed[:title], source: "filename" } if present?(parsed[:title])
  cands.first(3).each { |c| sources[:publication_name] << { value: c[:title], source: c[:source] } if present?(c[:title]) }
  sources[:publication_name] = sources[:publication_name].uniq { |s| s[:value] }
  
  # ISSN suggestions
  sources[:issn] = []
  sources[:issn] << { value: defaults[:issn], source: "defaults" } if present?(defaults[:issn])
  issn_hits.first(5).each { |h| sources[:issn] << { value: h[:value], source: "OCR (page #{h[:page]})" } }
  cands.first(3).each { |c| sources[:issn] << { value: c[:issn], source: c[:source] } if present?(c[:issn]) }
  sources[:issn] = sources[:issn].uniq { |s| s[:value] }
  
  # Publisher suggestions
  sources[:publisher] = []
  sources[:publisher] << { value: defaults[:publisher], source: "defaults" } if present?(defaults[:publisher])
  cands.first(3).each { |c| sources[:publisher] << { value: c[:publisher], source: c[:source] } if present?(c[:publisher]) }
  sources[:publisher] = sources[:publisher].uniq { |s| s[:value] }
  
  # Year suggestions
  sources[:year] = []
  sources[:year] << { value: parsed[:year], source: "filename" } if parsed[:year]
  sources[:year] = sources[:year].uniq { |s| s[:value] }
  
  # Month suggestions
  sources[:month] = []
  sources[:month] << { value: parsed[:month], source: "filename" } if present?(parsed[:month])
  sources[:month] = sources[:month].uniq { |s| s[:value] }
  
  # Issue suggestions
  sources[:issue] = []
  sources[:issue] << { value: parsed[:issue], source: "filename" } if present?(parsed[:issue])
  issue_hits.first(5).each { |h| sources[:issue] << { value: h[:value], source: "OCR (page #{h[:page]})" } }
  sources[:issue] = sources[:issue].uniq { |s| s[:value] }
  
  # Volume suggestions (usually none, but keep structure)
  sources[:volume] = []
  
  sources
end

def requery_flow(base_dir, pdf, title)
  say "New search title (Enter to keep '#{title}'): "
  print "> "
  t = STDIN.gets&.strip
  t = title if t.nil? || t.empty?
  c1 = crossref_candidates(base_dir: base_dir, pdf: pdf, title: t)
  c2 = wikidata_candidates(base_dir: base_dir, pdf: pdf, title: t)
  dedup_candidates(c1 + c2)
end

# ===================== Tesseract languages =====================
def tesseract_installed_languages
  out, _, ok = run_cmd("tesseract --list-langs")
  return [] unless ok
  lines = out.split(/\r?\n/).map(&:strip)
  lines.reject { |l| l.empty? || l =~ /list of/i }
end

def choose_ocr_language!(base_dir, defaults)
  installed = tesseract_installed_languages
  if installed.empty?
    warn "No Tesseract languages found (tesseract --list-langs). Install e.g.: brew install tesseract-lang dan"
    return
  end
  say "\nInstalled OCR languages:"
  installed.each_with_index { |l,i| say "  [#{i+1}] #{l}" }
  say "Enter code (e.g., 'eng' or combo 'eng+dan'), or use numbers with '+', e.g., '1+2':"
  print "> "
  inp = STDIN.gets&.strip
  return if inp.nil? || inp.empty?

  chosen = nil
  if inp =~ /\A(\d+(\+\d+)*)\z/
    parts = inp.split('+').map(&:to_i)
    codes = parts.map { |idx| installed[idx-1] }.compact
    chosen = codes.join('+') unless codes.empty?
  else
    chosen = inp
  end

  if chosen && !chosen.empty?
    defaults[:ocr_language] = chosen
    save_folder_defaults(base_dir, defaults)
    say "OCR language set to: #{chosen}"
  end
end

# ===================== Cache clearing =====================
def pick_pdf_interactively(pdfs)
  say "\nSelect file to clear OCR cache:"
  pdfs.each_with_index do |f, i|
    say "  [#{i+1}] #{File.basename(f)}"
  end
  say "Enter a number (1-#{pdfs.size}) or press ENTER to cancel."
  print "> "
  inp = STDIN.gets&.strip
  return nil if inp.nil? || inp.empty?
  idx = inp.to_i
  return nil unless idx.between?(1, pdfs.size)
  pdfs[idx - 1]
end

def clear_ocr_cache_for_file(base_dir, file)
  sha = sha256_file(file)
  path = ocr_cache_path(base_dir, sha)
  if File.exist?(path)
    FileUtils.rm_f(path)
    say "Deleted OCR cache for file: #{File.basename(file)}"
  else
    say "No OCR cache found for file: #{File.basename(file)}"
  end
end

def clear_ocr_cache_all(base_dir)
  pattern = File.join(cache_dir(base_dir), "ocr_*.json")
  files = Dir.glob(pattern)
  files.each { |f| FileUtils.rm_f(f) }
  say "Deleted #{files.size} OCR cache file(s)."
end

def clear_http_cache_all(base_dir)
  pattern = File.join(cache_dir(base_dir), "http_*.json")
  files = Dir.glob(pattern)
  files.each { |f| FileUtils.rm_f(f) }
  say "Deleted #{files.size} HTTP cache file(s)."
end

def show_start_menu!(base_dir, defaults, pdfs)
  loop do
    say "\n========== PERIODICALS-GETMETA =========="
    say "Folder: #{base_dir}"
    say "PDFs found: #{pdfs.length}"
    say "Folder defaults:"
    say "  publication_name: #{defaults[:publication_name] || '-'}"
    say "  issn            : #{defaults[:issn] || '-'}"
    say "  publisher       : #{defaults[:publisher] || '-'}"
    say "  ocr_language    : #{defaults[:ocr_language] || '(none)'}"
    say "  numbering_mode  : #{defaults[:numbering_mode]}"
    say "  user_email      : #{defaults[:user_email] || USER_AGENT_EMAIL}"
    say "Runtime options:"
    say "  [2] Run WITHOUT OCR   : #{RuntimeOptions[:no_ocr] ? 'ON' : 'OFF'}"
    say "  [3] Force OCR (re-OCR): #{RuntimeOptions[:force_ocr] ? 'ON' : 'OFF'}"
    say "  [4] Force lookups     : #{RuntimeOptions[:force_http] ? 'ON' : 'OFF'} (ignore HTTP cache/TTL)"
    say "  HTTP cache TTL        : #{RuntimeOptions[:ttl_days]} days"
    say "-----------------------------------------"
    say " [1] Choose OCR language"
    say " [2] Toggle: run WITHOUT OCR (ON/OFF)"
    say " [3] Toggle: FORCE OCR for this run (ON/OFF)"
    say " [4] Toggle: FORCE lookups (ignore HTTP cache/TTL) (ON/OFF)"
    say " [5] Set TTL (days) for HTTP cache"
    say " [6] View/edit folder defaults (title/ISSN/publisher/ocr_language)"
    say " [7] Quick OCR test on first PDF"
    say " [8] Clear cache for ONE file (OCR + HTTP)"
    say " [9] Clear ALL cache files (keeps state/defaults)"
    say " [ENTER] Start processing"
    say " [Q] Quit without running"
    print "> "

    inp = STDIN.gets&.strip
    return if inp.nil? || inp.empty?

    case inp.upcase
    when 'Q'
      say "Quitting."
      exit 0
    when '1'
      choose_ocr_language!(base_dir, defaults)
    when '2'
      RuntimeOptions[:no_ocr] = !RuntimeOptions[:no_ocr]
      say "Run WITHOUT OCR: #{RuntimeOptions[:no_ocr] ? 'ON' : 'OFF'}"
    when '3'
      RuntimeOptions[:force_ocr] = !RuntimeOptions[:force_ocr]
      say "Force OCR: #{RuntimeOptions[:force_ocr] ? 'ON' : 'OFF'}"
    when '4'
      RuntimeOptions[:force_http] = !RuntimeOptions[:force_http]
      say "Force lookups: #{RuntimeOptions[:force_http] ? 'ON' : 'OFF'}"
    when '5'
      print "New TTL in days (current #{RuntimeOptions[:ttl_days]}): "
      t = STDIN.gets&.strip
      if t && t =~ /^\d+$/
        RuntimeOptions[:ttl_days] = t.to_i
        say "TTL set to #{RuntimeOptions[:ttl_days]} days."
      else
        warn "Invalid number."
      end
    when '6'
      say "Edit defaults (Enter keeps current):"
      print "publication_name [#{defaults[:publication_name]}]: "; t = STDIN.gets&.strip; defaults[:publication_name] = t unless t.nil? || t.empty?
      print "issn [#{defaults[:issn]}]: "; t = STDIN.gets&.strip; defaults[:issn] = t unless t.nil? || t.empty?
      print "publisher [#{defaults[:publisher]}]: "; t = STDIN.gets&.strip; defaults[:publisher] = t unless t.nil? || t.empty?
      print "ocr_language [#{defaults[:ocr_language]}]: "; t = STDIN.gets&.strip; defaults[:ocr_language] = t unless t.nil? || t.empty?
      say "Numbering mode: [1] Issue only (e.g., Issue 120)  [2] Volume + Issue (e.g., Vol 5, Issue 3)"
      current_display = defaults[:numbering_mode] == NUMBERING_VOL_ISSUE ? "2" : "1"
      print "numbering_mode [#{current_display}]: "; t = STDIN.gets&.strip
      unless t.nil? || t.empty?
        defaults[:numbering_mode] = (t == '2' ? NUMBERING_VOL_ISSUE : NUMBERING_ISSUE_ONLY)
      end
      current_email = defaults[:user_email] || USER_AGENT_EMAIL
      print "user_email (for API requests) [#{current_email}]: "; t = STDIN.gets&.strip
      defaults[:user_email] = t unless t.nil? || t.empty?
      save_folder_defaults(base_dir, defaults)
      say "Defaults saved."
    when '7'
      if pdfs.empty?
        warn "No PDFs to test."
      else
        test_pdf = pdfs.first
        say "Testing OCR on: #{File.basename(test_pdf)}"
        pages = extract_pages_from_pdf(test_pdf)
        need = need_ocr?(pages)
        say "pdftotext produced #{pages.count { |p| p[:text].strip.length >= 20 }} non-empty pages (#{pages.size} total)."
        if RuntimeOptions[:no_ocr]
          say "OCR is disabled (no OCR will be attempted)."
        else
          say "OCR recommended? #{need ? 'Yes' : 'No'}"
          if need
            lang = defaults[:ocr_language]
            say "Attempting OCR (language: #{lang || '(none)'}), test only…"
            if (ocr_pdf = ocrmypdf_once(test_pdf, lang))
              pages2 = extract_pages_from_pdf(ocr_pdf)
              say "After OCR: #{pages2.count { |p| p[:text].strip.length >= 20 }} non-empty pages."
            else
              warn "OCR did not complete."
            end
          end
        end
      end
    when '8'
      if pdfs.empty?
        warn "No PDFs."
      else
        chosen = pick_pdf_interactively(pdfs)
        if chosen
          clear_ocr_cache_for_file(base_dir, chosen)
          base = pdf_cache_basename(chosen)
          cache = cache_dir(base_dir)
          http_files = Dir.glob(File.join(cache, "#{base}_*.json"))
          http_files.each { |f| FileUtils.rm_f(f) unless f.end_with?("_ocr.json") }
          say "Cleared cache for: #{File.basename(chosen)}"
        else
          say "Cancelled."
        end
      end
    when '9'
      print "Clean up ALL cache files? This will remove OCR and HTTP cache but keep state/defaults. [y/N]: "
      confirm = STDIN.gets&.strip&.downcase
      if confirm == 'y' || confirm == 'yes'
        cleanup_cache_dir!(base_dir)
      else
        say "Cancelled."
      end
    when ''
      return
    else
      warn "Unknown option."
    end
  end
end

# ===================== Booklore sidecar & cover =====================
def ensure_cover_image(pdf, cover_path)
  return { created: false, reason: "already_exists" } if File.exist?(cover_path)
  Dir.mktmpdir("cover") do |tmp|
    prefix = File.join(tmp, "cover")
    # Produce cover image (first page only)
    stdout, stderr, ok = run_cmd(%(pdftoppm -jpeg -f 1 -l 1 "#{pdf}" "#{prefix}"))
    if ok
      # pdftoppm can create different filename patterns depending on version:
      # - cover-1.jpg (older versions)
      # - cover-01.jpg (newer versions with zero-padding)
      # - cover.jpg (some versions when single page)
      candidates = [
        "#{prefix}-1.jpg",
        "#{prefix}-01.jpg",
        "#{prefix}.jpg"
      ]
      
      # Also check for any .jpg files in the temp directory
      jpg_files = Dir.glob(File.join(tmp, "*.jpg"))
      candidates.concat(jpg_files)
      candidates.uniq!
      
      found = candidates.find { |f| File.exist?(f) }
      if found
        FileUtils.cp(found, cover_path)
        return { created: true, reason: "success" }
      else
        warn "Cover extraction: pdftoppm succeeded but output file not found. Checked: #{candidates.join(', ')}"
        return { created: false, reason: "output_missing" }
      end
    else
      warn "Cover extraction failed: #{stderr}"
      return { created: false, reason: "pdftoppm_failed" }
    end
  end
  { created: false, reason: "unknown" }
end

def load_booklore_sidecar(path)
  load_json(path)
end

def save_booklore_sidecar(path, sc)
  File.write(path, JSON.pretty_generate(sc))
end

# Synchronize sidecar JSON to reflect the same metadata we embed in the PDF.
# Overwrites title/publishedDate/pageCount/identifiers with authoritative values.
# Merges discovered ISBNs uniquely. Adds publicationName/publisher/issue/volume/keywords.
def sync_sidecar_with_md(existing_sidecar, md, page_count, cover_path, isbn_list = [])
  now_iso   = Time.now.utc.iso8601
  cover_rel = File.basename(cover_path)

  sc = existing_sidecar || {}
  sc[:version]     ||= "1.0"
  sc[:generatedBy]   = "periodicals-getmeta"
  sc[:generatedAt]   = now_iso

  sc[:cover] ||= {}
  sc[:cover][:source] ||= "external"
  sc[:cover][:path]   = cover_rel

  sc[:metadata] ||= {}
  m = sc[:metadata]

  canonical_title = md[:dc_title] || "#{md[:publication_name]} #{md[:pubdate]} (Issue #{md[:issue]})"

  # Authoritative fields mirrored from the embedded metadata
  m[:title]          = canonical_title
  m[:publishedDate]  = md[:pubdate]                if md[:pubdate]
  m[:pageCount]      = page_count                  if page_count && page_count > 0

  m[:identifiers] ||= {}
  m[:identifiers][:issn] = md[:issn] if present?(md[:issn])

  # Merge ISBNs found via OCR (unique array)
  if isbn_list && !isbn_list.empty?
    case m[:identifiers][:isbn]
    when Array
      m[:identifiers][:isbn] = (m[:identifiers][:isbn] + isbn_list).uniq
    when String
      m[:identifiers][:isbn] = ([m[:identifiers][:isbn]] + isbn_list).uniq
    else
      m[:identifiers][:isbn] = isbn_list.uniq
    end
  end

  # Helpful extra fields (non-breaking for Booklore)
  m[:publicationName] = md[:publication_name] if present?(md[:publication_name])
  m[:publisher]       = md[:publisher]        if present?(md[:publisher])
  m[:issue]           = md[:issue]            if present?(md[:issue])
  m[:volume]          = md[:volume]           if present?(md[:volume])

  keywords = [md[:publication_name], md[:year], md[:month], (md[:issue] && "Issue #{md[:issue]}")].compact.map(&:to_s)
  m[:keywords] = keywords unless keywords.empty?

  sc
end

# ===================== Adopt defaults after first success =====================
def adopt_defaults_from_first_success!(base_dir, defaults, md)
  changed = false
  if blank?(defaults[:publication_name]) && present?(md[:publication_name])
    defaults[:publication_name] = md[:publication_name]; changed = true
  end
  if blank?(defaults[:issn]) && md[:issn] && valid_issn?(md[:issn])
    defaults[:issn] = md[:issn]; changed = true
  end
  if blank?(defaults[:publisher]) && present?(md[:publisher])
    defaults[:publisher] = md[:publisher]; changed = true
  end
  if changed
    save_folder_defaults(base_dir, defaults)
    say ">>> Folder defaults have been established from the first successful match:"
    say "    title='#{defaults[:publication_name]}', ISSN='#{defaults[:issn]}', publisher='#{defaults[:publisher]}'"
  end
end

# ===================== Booklore finalization (extracted duplicate code) =====================
def finalize_booklore_and_state!(base_dir, pdf, sha, md, ok, ocr_source, issn_hits, isbn_hits, sc_path, sidecar, page_count, pick: nil)
  cover_path = cover_path_for(pdf)
  cover_status = ensure_cover_image(pdf, cover_path)
  isbn_list = isbn_hits.map { |h| h[:value] }.uniq
  sc = sync_sidecar_with_md(sidecar, md, page_count, cover_path, isbn_list)
  save_booklore_sidecar(sc_path, sc)

  # After embedding metadata, PDF SHA256 has changed - update OCR cache with new SHA
  if ok
    new_sha = sha256_file(pdf)
    if new_sha != sha
      say "Updating OCR cache with new SHA256 (PDF was modified by metadata embedding)"
      cache_file = ocr_cache_path(base_dir, File.basename(pdf))
      if cached = load_json(cache_file)
        cached[:sha256] = new_sha
        save_json(cache_file, cached)
      end
      sha = new_sha  # Use new SHA for state entry
    end
  end

  state_entry = {
    time: Time.now.iso8601,
    file: pdf,
    sha256: sha,
    status: (ok ? "embedded" : "error"),
    ocr_source: ocr_source,
    ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) },
    metadata: md,
    sidecar: { path: sc_path, updated: true },
    cover: { path: cover_path, created: cover_status[:created] }
  }
  state_entry[:pick] = pick if pick
  append_state(base_dir, state_entry)
end

# ===================== Main =====================
def main
  base_dir = ARGV[0]
  unless base_dir && Dir.exist?(base_dir)
    warn "Usage: ruby periodicals-getmeta.rb \"/path/to/folder/with/pdfs\""
    exit 1
  end

  # Check all dependencies before starting
  check_dependencies!

  ensure_cache_dir!(base_dir)
  acquire_lock!(base_dir)

  defaults = load_folder_defaults(base_dir)
  defaults[:ocr_language] ||= 'eng' if blank?(defaults[:ocr_language])

  pdfs = Dir.glob(File.join(base_dir, "*.pdf")).sort

  # Interactive start menu
  show_start_menu!(base_dir, defaults, pdfs)

  if pdfs.empty?
    warn "No PDFs found in: #{base_dir}"
    release_lock!(base_dir)
    exit 0
  end

  pdfs.each do |pdf|
    # Page-wise text extraction (with caching + OCR when needed) - calculates SHA once
    pages, sha, ocr_source = extract_text_pages_with_cache(base_dir, pdf, defaults[:ocr_language])
    
    if already_embedded?(base_dir, pdf, sha)
      info "Skipping (already embedded): #{File.basename(pdf)}"
      next
    end

    parsed = parse_filename(pdf)

    # Load Booklore sidecar once (reused later)
    sc_path = sidecar_path_for(pdf)
    sidecar = load_booklore_sidecar(sc_path)
    sidecar_issn = sidecar&.dig(:metadata, :identifiers, :issn)

    # Prefer sidecar title for searching (if present), otherwise use parsed title
    sidecar_title = sidecar&.dig(:metadata, :title)
    search_title  = present?(sidecar_title) ? sidecar_title : parsed[:title]

    # Extract metadata from pages
    issn_hits = extract_issn_matches_per_page(pages)
    isbn_hits = extract_isbn_matches_per_page(pages)
    issue_hits = extract_issue_number_from_pages(pages)
    volume_hits = extract_volume_number_from_pages(pages)
    
    # Cache page count from pages array (avoid re-parsing PDF)
    page_count = pages.length
    
    # If filename didn't have issue but OCR found one, use it
    issue_from_ocr = false
    if blank?(parsed[:issue]) && !issue_hits.empty?
      parsed[:issue] = issue_hits.first[:value]
      issue_from_ocr = true
      info "Issue number extracted from OCR: #{parsed[:issue]}"
    end

    # Smart candidate building: skip API calls if defaults are complete and will be used
    defaults_complete = present?(defaults[:issn]) && present?(defaults[:publication_name]) && present?(defaults[:publisher])
    
    cands = []
    unless defaults_complete
      # Build candidate list using concat for efficiency
      # Try OpenAlex first (free, fast, comprehensive)
      if defaults[:issn] && valid_issn?(defaults[:issn])
        cands.concat(openalex_candidates(base_dir: base_dir, pdf: pdf, issn: defaults[:issn]))
      end
      if sidecar_issn && valid_issn?(sidecar_issn)
        cands.concat(openalex_candidates(base_dir: base_dir, pdf: pdf, issn: sidecar_issn))
      end
      issn_hits.first(2).each { |h| cands.concat(openalex_candidates(base_dir: base_dir, pdf: pdf, issn: h[:value])) }
      
      # If OpenAlex didn't find anything, try Crossref and Wikidata
      if cands.empty?
        cands.concat(crossref_candidates(base_dir: base_dir, pdf: pdf, issn: defaults[:issn])) if defaults[:issn] && valid_issn?(defaults[:issn])
        cands.concat(crossref_candidates(base_dir: base_dir, pdf: pdf, title: search_title))
        cands.concat(wikidata_candidates(base_dir: base_dir, pdf: pdf, title: search_title))
        
        # If still no results, try ISSN Portal as last resort
        if cands.empty? && !issn_hits.empty?
          issn_hits.first(2).each { |h| cands.concat(issn_portal_lookup(base_dir: base_dir, pdf: pdf, issn: h[:value])) }
        end
      else
        # OpenAlex found something, but also search by title for more options
        cands.concat(openalex_candidates(base_dir: base_dir, pdf: pdf, title: search_title))
      end
      
      cands = dedup_candidates(cands)
    end

    # Build preview metadata for prompt when defaults are complete
    preview_md = nil
    if defaults_complete
      pick = { title: defaults[:publication_name] || parsed[:title], issn: defaults[:issn], publisher: defaults[:publisher], source: "defaults" }
      md = build_metadata(pdf, parsed, pick, defaults, volume_hits: volume_hits)
      
      # Determine correct issue source
      issue_src = if md[:issue]
        if issue_from_ocr
          "OCR (page #{issue_hits.first[:page]})"
        else
          "filename"
        end
      else
        "none"
      end
      
      # Determine correct volume source
      volume_src = if md[:volume]
        if parsed[:volume]
          "filename"
        elsif !volume_hits.empty?
          "OCR (page #{volume_hits.first[:page]})"
        else
          "none"
        end
      else
        "none"
      end
      
      preview_md = {
        publication_name: md[:publication_name],
        publisher: md[:publisher],
        issn: md[:issn],
        year: md[:year],
        month: md[:month],
        issue: md[:issue],
        volume: md[:volume],
        pub_source: pick[:title] ? "defaults" : "filename",
        publisher_source: pick[:publisher] ? "defaults" : "none",
        issn_source: pick[:issn] ? "defaults" : "none",
        year_source: parsed[:year] ? "filename" : "none",
        month_source: parsed[:month] ? "filename" : "default (01)",
        issue_source: issue_src,
        volume_source: volume_src
      }
    end

    # Collect extracted metadata for display (deduplicate values)
    extracted_md = {
      issn: issn_hits.first(3).map { |h| h[:value] }.uniq,
      volume: volume_hits.first(3).map { |h| h[:value] }.uniq,
      issue: issue_hits.first(3).map { |h| h[:value] }.uniq
    }

    loop do
      sel = prompt_select(pdf, parsed, cands, defaults, defaults_complete: defaults_complete, preview_metadata: preview_md, extracted_metadata: extracted_md)
      case sel[:action]
      when 'abort'
        say "Aborted."
        release_lock!(base_dir)
        exit 0

      when 'skip'
        append_state(base_dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha, status: "skipped",
          ocr_source: ocr_source,
          ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) }
        })
        break

      when 'defaults'
        pick = { title: defaults[:publication_name] || parsed[:title], issn: defaults[:issn], publisher: defaults[:publisher], source: "defaults", score: 0.6 }
        md = build_metadata(pdf, parsed, pick, defaults, volume_hits: volume_hits)
        # Metadata already shown in prompt, just proceed
        ok = write_exiftool(pdf, md)
        finalize_booklore_and_state!(base_dir, pdf, sha, md, ok, ocr_source, issn_hits, isbn_hits, sc_path, sidecar, page_count)
        adopt_defaults_from_first_success!(base_dir, defaults, md) if ok
        break

      when 'manual'
        pick = { title: parsed[:title], issn: issn_hits.first && issn_hits.first[:value], publisher: defaults[:publisher] }
        md = build_metadata(pdf, parsed, pick, defaults, volume_hits: volume_hits)
        md = manual_edit(md)
        ok = write_exiftool(pdf, md)
        finalize_booklore_and_state!(base_dir, pdf, sha, md, ok, ocr_source, issn_hits, isbn_hits, sc_path, sidecar, page_count)
        adopt_defaults_from_first_success!(base_dir, defaults, md) if ok
        break

      when 'field_by_field'
        pick = { title: defaults[:publication_name] || parsed[:title], issn: defaults[:issn], publisher: defaults[:publisher], source: "defaults", score: 0.6 }
        sources = collect_field_suggestions(parsed, defaults, cands, issue_hits, issn_hits)
        md = field_by_field_edit(build_metadata(pdf, parsed, pick, defaults, volume_hits: volume_hits), sources)
        ok = write_exiftool(pdf, md)
        finalize_booklore_and_state!(base_dir, pdf, sha, md, ok, ocr_source, issn_hits, isbn_hits, sc_path, sidecar, page_count)
        adopt_defaults_from_first_success!(base_dir, defaults, md) if ok
        break

      when 'rescan'
        cands = requery_flow(base_dir, pdf, parsed[:title])
        cands = dedup_candidates(cands)
        next

      when 'pick'
        pick = sel[:pick]
        md = build_metadata(pdf, parsed, pick, defaults, volume_hits: volume_hits)
        show_metadata_preview(md, parsed, defaults, pick)
        if blank?(md[:publication_name]) || blank?(md[:issn])
          say "Some fields are empty → manual fine-tuning:"
          md = manual_edit(md)
        else
          print "Proceed with this metadata? [Y/n/e=edit]: "
          confirm = STDIN.gets&.strip&.downcase
          if confirm == 'e' || confirm == 'edit'
            md = manual_edit(md)
          elsif confirm == 'n' || confirm == 'no'
            next  # Go back to selection
          end
        end
        ok = write_exiftool(pdf, md)
        finalize_booklore_and_state!(base_dir, pdf, sha, md, ok, ocr_source, issn_hits, isbn_hits, sc_path, sidecar, page_count, pick: pick)
        adopt_defaults_from_first_success!(base_dir, defaults, md) if ok
        break

      else
        warn "Unknown choice."
      end
    end
  end

  say "\nDone. Log: #{state_path(base_dir)}"
  say "Defaults: #{defaults_path(base_dir)}"
  say "Cache folder: #{cache_dir(base_dir)}"
  release_lock!(base_dir)
end

# Run
main if __FILE__ == $0
