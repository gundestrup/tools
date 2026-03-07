#!/usr/bin/env ruby
# encoding: UTF-8
#
# periodicals-getmeta.rb
#
# - Single subfolder: .periodicals_getmeta/
# - Interactive start menu: choose OCR language, runtime toggles (no OCR, force OCR, force lookups), TTL, view/edit defaults
# - NEW: Clear cache (OCR for ONE file / entire folder, HTTP for entire folder)
# - Page-wise text extraction (pdftotext) + OCR when needed (using folder default OCR language)
# - OCR and HTTP caching stored in .periodicals_getmeta/
# - ISSN/ISBN per page with positions and context for debugging
# - Crossref & Wikidata lookups (with caching), top-5 candidate selection
# - Embeds PRISM/XMP into PDF (via exiftool)
# - JSONL log (state) with resume (file+sha), includes ocr_hits
# - Automatically adopts folder defaults after the first successful embed (ISSN/publisher/title)
#
# Dependencies:
#   brew install exiftool ocrmypdf tesseract poppler
#   (optional) brew install tesseract-lang
#
# Usage:
#   ruby periodicals-getmeta.rb "/path/to/folder/with/pdfs"
#
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
USER_AGENT_EMAIL = "your-email@example.com"     # <-- SET YOUR EMAIL HERE (polite API User-Agent)
MAX_CANDIDATES   = 5

CACHE_DIR          = ".periodicals_getmeta"
STATE_FILENAME     = "periodicals_getmeta.state.jsonl"
FOLDER_DEFAULTS_FN = "periodicals_getmeta.defaults.json"
LOCK_FILENAME      = "periodicals_getmeta.lock"

DEFAULT_CACHE_TTL_DAYS = 14
TIMEOUT_SECONDS         = 20

# Runtime options (controlled from the start menu)
$opts = {
  force_http: false,   # re-lookup: ignore HTTP cache/TTL
  force_ocr:  false,   # re-OCR for this run: ignore OCR cache
  no_ocr:     false,   # run without OCR entirely
  ttl_days:   DEFAULT_CACHE_TTL_DAYS,
  debug:      false
}

def say(s="") puts(s) end
def info(s) $stderr.puts("[INFO] #{s}") if $opts[:debug] end
def warn(s) $stderr.puts("[WARN] #{s}") end

# ===================== FS helpers =====================
def cache_dir(base_dir) File.join(base_dir, CACHE_DIR) end
def ensure_cache_dir!(base_dir) FileUtils.mkdir_p(cache_dir(base_dir)) end
def state_path(base_dir) File.join(cache_dir(base_dir), STATE_FILENAME) end
def defaults_path(base_dir) File.join(cache_dir(base_dir), FOLDER_DEFAULTS_FN) end
def lock_path(base_dir) File.join(cache_dir(base_dir), LOCK_FILENAME) end

def http_cache_path(base_dir, provider, key)
  safe = key.to_s.downcase.gsub(/[^a-z0-9\-_:.]/i, '_')
  File.join(cache_dir(base_dir), "http_#{provider}__#{safe}.json")
end

def ocr_cache_path(base_dir, sha) File.join(cache_dir(base_dir), "ocr_#{sha}.json") end

def acquire_lock!(base_dir)
  lp = lock_path(base_dir)
  if File.exist?(lp)
    warn "Lock file already exists: #{lp} — another run might be active. Delete the lock to override."
    exit 2
  end
  File.write(lp, "#{Process.pid}\n")
end

def release_lock!(base_dir)
  FileUtils.rm_f(lock_path(base_dir))
end

def sha256_file(path)
  digest = Digest::SHA256.new
  File.open(path, "rb") do |f|
    buf = ""
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
  load_json(defaults_path(base_dir)) || {}
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

# ===================== Shell utils =====================
def run_cmd(cmd, stdin_data:nil)
  info "CMD: #{cmd}"
  stdout, stderr, status = Open3.capture3(cmd, stdin_data: stdin_data)
  [stdout, stderr, status.success?]
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
  if ocr_langs && !ocr_langs.strip.empty?
    args += ["--language", ocr_langs]
  end
  ocr_pdf = pdf.sub(/\.pdf$/i, ".ocr.tmp.pdf")
  args += [pdf, ocr_pdf]
  _, err, ok = run_cmd(args.map { |x| %("#{x}") }.join(" "))
  ok && File.exist?(ocr_pdf) ? ocr_pdf : nil
end

def extract_text_pages_with_cache(base_dir, pdf, ocr_langs)
  sha = sha256_file(pdf)
  cache_file = ocr_cache_path(base_dir, sha)

  if !$opts[:force_ocr] && (cached = load_json(cache_file))
    return [cached[:pages], sha, cached[:source] || "cache"]
  end

  pages = extract_pages_from_pdf(pdf)
  source = "pdftotext"

  if !$opts[:no_ocr] && need_ocr?(pages)
    if (ocr_pdf = ocrmypdf_once(pdf, ocr_langs))
      pages = extract_pages_from_pdf(ocr_pdf)
      source = "ocrmypdf"
      # FileUtils.rm_f(ocr_pdf) # keep for debugging if needed
    end
  end

  save_json(cache_file, {
    sha256: sha,
    pages: pages,
    source: source,
    created_at: Time.now.iso8601
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

# ===================== Filename parsing =====================
def parse_filename(fn)
  base = File.basename(fn, ".pdf")
  if base =~ /^(?<title>.+?)\s*[-–]\s*(?<year>\d{4})-. \s*[-–]\s*(?<issue>\d{1,5})$/i
    return { title:$~[:title].strip, year:$~[:year].to_i, month:$~[:month], issue:$~[:issue], source:"filename" }
  end
  if base =~ /^(?<title>.+?)\s+(?<year>\d{4})-. .*?(?<issue>\d{1,5})$/i
    return { title:$~[:title].strip, year:$~[:year].to_i, month:$~[:month], issue:$~[:issue], source:"filename(fuzzy)" }
  end
  { title: base.strip, source: "filename(min)" }
end

# ===================== HTTP & cache =====================
def http_get_json(url, headers: {})
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.read_timeout = TIMEOUT_SECONDS
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = "periodicals-getmeta/1.0 (#{USER_AGENT_EMAIL})"
  headers.each { |k,v| req[k] = v }
  res = http.request(req)
  raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

def cached_http_get_json(base_dir, provider, key, url, headers: {})
  path = http_cache_path(base_dir, provider, key)
  if File.exist?(path) && !$opts[:force_http]
    ttl_days = $opts[:ttl_days] || DEFAULT_CACHE_TTL_DAYS
    if (Time.now - File.mtime(path)) / (24*3600.0) <= ttl_days
      return JSON.parse(File.read(path)) rescue nil
    end
  end
  data = http_get_json(url, headers: headers)
  File.write(path, JSON.pretty_generate(data))
  data
rescue => e
  warn "HTTP GET/cache error (#{provider}/#{key}): #{e}"
  if File.exist?(path)
    JSON.parse(File.read(path)) rescue nil
  else
    nil
  end
end

# ===================== Lookup providers =====================
def crossref_candidates(base_dir:, title: nil, issn: nil)
  out = []
  if issn
    url = "https://api.crossref.org/journals/#{URI.encode_www_form_component(issn)}"
    data = cached_http_get_json(base_dir, "crossref_journal", issn, url)
    if (msg = data && data['message'])
      out << { source:"Crossref(journal)", title:msg['title'], issn:(Array(msg['ISSN']).first || issn), publisher:msg['publisher'], score:1.0 }
    end
  end
  if title && out.empty?
    url = "https://api.crossref.org/journals?query=#{URI.encode_www_form_component(title)}"
    data = cached_http_get_json(base_dir, "crossref_search", title, url)
    items = data && data.dig('message','items') || []
    items.first(MAX_CANDIDATES).each_with_index do |it, idx|
      out << { source:"Crossref(search)", title:it['title'], issn:Array(it['ISSN']).first, publisher:it['publisher'], score:0.8 - idx*0.05 }
    end
  end
  out
end

def wikidata_candidates(base_dir:, title:)
  return [] unless title && !title.strip.empty?
  out = []
  s_url = "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=#{URI.encode_www_form_component(title)}&language=en&type=item&limit=#{MAX_CANDIDATES}&format=json"
  s = cached_http_get_json(base_dir, "wikidata_search", title, s_url, headers: {"Accept"=>"application/json"})
  (s && s['search'] || []).first(MAX_CANDIDATES).each do |hit|
    qid = hit['id']
    ent = cached_http_get_json(base_dir, "wikidata_entity", qid, "https://www.wikidata.org/wiki/Special:EntityData/#{qid}.json")
    entity = ent && ent.dig('entities', qid) || {}
    claims = entity['claims'] || {}
    issn_vals = (claims['P236'] || []).map { |c| c.dig('mainsnak','datavalue','value') }.compact
    publisher_qids = (claims['P123'] || []).map { |c| c.dig('mainsnak','datavalue','value','id') }.compact
    pubname = nil
    publisher_qids.each do |pq|
      pjson = cached_http_get_json(base_dir, "wikidata_entity", pq, "https://www.wikidata.org/wiki/Special:EntityData/#{pq}.json")
      lab = pjson && (pjson.dig('entities', pq, 'labels', 'en', 'value') || pjson.dig('entities', pq, 'labels', 'da', 'value'))
      pubname ||= lab
    end
    out << { source:"Wikidata", title:(entity.dig('labels','en','value') || entity.dig('labels','da','value') || hit['label'] || title), issn:issn_vals&.first, publisher:pubname, score:0.7 }
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
def prompt_select(file, parsed, cands, folder_defaults)
  say "\n—"
  say "File: #{File.basename(file)}"
  say "From filename: title='#{parsed[:title]}' year='#{parsed[:year]}' month='#{parsed[:month]}' issue='#{parsed[:issue]}'"
  say "Folder defaults → title: #{folder_defaults[:publication_name] || '-'} | ISSN: #{folder_defaults[:issn] || '-'} | publisher: #{folder_defaults[:publisher] || '-'} | OCR language: #{folder_defaults[:ocr_language] || '(none)'}"

  if cands.empty?
    say "No candidates found. [M]anual / [S]kip / [A]bort?"
    print "> "
    inp = STDIN.gets&.strip&.upcase
    return { action: 'abort' } if inp == 'A'
    return { action: 'skip' }  if inp == 'S'
    return { action: 'manual' }
  end

  say "Candidates:"
  cands.each_with_index do |c, i|
    say "[#{i+1}] #{c[:title]}  | ISSN: #{c[:issn] || '-'}  | Publisher: #{c[:publisher] || '-'}  (#{c[:source]})"
  end
  say "[D] Use folder defaults    [M] Manual    [S] Skip    [A] Abort    [R] Re-search with another title"
  print "Choose (1-#{cands.length}/D/M/S/A/R): "
  inp = STDIN.gets&.strip
  return { action: 'abort' } if inp&.upcase == 'A'
  return { action: 'skip' }  if inp&.upcase == 'S'
  return { action: 'manual' } if inp&.upcase == 'M'
  return { action: 'defaults' } if inp&.upcase == 'D'
  return { action: 'rescan' } if inp&.upcase == 'R'
  idx = inp.to_i
  if idx >= 1 && idx <= cands.length
    { action: 'pick', pick: cands[idx-1] }
  else
    { action: 'manual' }
  end
end

def build_metadata(file, parsed, pick, defaults)
  pubname  = pick[:title] || defaults[:publication_name] || parsed[:title]
  issn     = pick[:issn] || defaults[:issn]
  publisher= pick[:publisher] || defaults[:publisher]
  year     = parsed[:year]
  month    = parsed[:month] || "01"
  pubdate  = [year, month].compact.join("-")
  {
    publication_name: pubname,
    issn: issn,
    publisher: publisher,
    year: year,
    month: month,
    pubdate: pubdate,
    issue: parsed[:issue],
    volume: nil,
    dc_title: nil
  }
end

def manual_edit(md)
  say "Manual edit (press Enter to keep current value):"
  print "publication_name [#{md[:publication_name]}]: "; t = STDIN.gets&.strip; md[:publication_name] = t unless t.nil? || t.empty?
  print "issn [#{md[:issn]}]: "; t = STDIN.gets&.strip; md[:issn] = t unless t.nil? || t.empty?
  print "publisher [#{md[:publisher]}]: "; t = STDIN.gets&.strip; md[:publisher] = t unless t.nil? || t.empty?
  print "year [#{md[:year]}]: "; t = STDIN.gets&.strip; md[:year] = t.to_i unless t.nil? || t.empty?
  print "month [#{md[:month]}]: "; t = STDIN.gets&.strip; md[:month] = t unless t.nil? || t.empty?
  print "issue [#{md[:issue]}]: "; t = STDIN.gets&.strip; md[:issue] = t unless t.nil? || t.empty?
  print "volume [#{md[:volume]}]: "; t = STDIN.gets&.strip; md[:volume] = t unless t.nil? || t.empty?
  print "dc_title (custom) [#{md[:dc_title]}]: "; t = STDIN.gets&.strip; md[:dc_title] = t unless t.nil? || t.empty?
  md[:pubdate] = [md[:year], md[:month]].compact.join("-")
  md
end

def requery_flow(base_dir, title)
  say "New search title (Enter to keep '#{title}'): "
  print "> "
  t = STDIN.gets&.strip
  t = title if t.nil? || t.empty?
  c1 = crossref_candidates(base_dir: base_dir, title: t)
  c2 = wikidata_candidates(base_dir: base_dir, title: t)
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

# ===================== Start menu =====================
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
    say "Runtime options:"
    say "  [2] Run WITHOUT OCR   : #{$opts[:no_ocr] ? 'ON' : 'OFF'}"
    say "  [3] Force OCR (re-OCR): #{$opts[:force_ocr] ? 'ON' : 'OFF'}"
    say "  [4] Force lookups     : #{$opts[:force_http] ? 'ON' : 'OFF'} (ignore HTTP cache/TTL)"
    say "  HTTP cache TTL        : #{$opts[:ttl_days]} days"
    say "-----------------------------------------"
    say " [1] Choose OCR language"
    say " [2] Toggle: run WITHOUT OCR (ON/OFF)"
    say " [3] Toggle: FORCE OCR for this run (ON/OFF)"
    say " [4] Toggle: FORCE lookups (ignore HTTP cache/TTL) (ON/OFF)"
    say " [5] Set TTL (days) for HTTP cache"
    say " [6] View/edit folder defaults (title/ISSN/publisher/ocr_language)"
    say " [7] Quick OCR test on first PDF"
    say " [8] Clear OCR cache for ONE file"
    say " [9] Clear OCR cache for ENTIRE folder"
    say " [10] Clear HTTP cache for ENTIRE folder"
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
      $opts[:no_ocr] = !$opts[:no_ocr]
      say "Run WITHOUT OCR: #{$opts[:no_ocr] ? 'ON' : 'OFF'}"
    when '3'
      $opts[:force_ocr] = !$opts[:force_ocr]
      say "Force OCR: #{$opts[:force_ocr] ? 'ON' : 'OFF'}"
    when '4'
      $opts[:force_http] = !$opts[:force_http]
      say "Force lookups: #{$opts[:force_http] ? 'ON' : 'OFF'}"
    when '5'
      print "New TTL in days (current #{$opts[:ttl_days]}): "
      t = STDIN.gets&.strip
      if t && t =~ /^\d+$/
        $opts[:ttl_days] = t.to_i
        say "TTL set to #{$opts[:ttl_days]} days."
      else
        warn "Invalid number."
      end
    when '6'
      say "Edit defaults (Enter keeps current):"
      print "publication_name [#{defaults[:publication_name]}]: "; t = STDIN.gets&.strip; defaults[:publication_name] = t unless t.nil? || t.empty?
      print "issn [#{defaults[:issn]}]: "; t = STDIN.gets&.strip; defaults[:issn] = t unless t.nil? || t.empty?
      print "publisher [#{defaults[:publisher]}]: "; t = STDIN.gets&.strip; defaults[:publisher] = t unless t.nil? || t.empty?
      print "ocr_language [#{defaults[:ocr_language]}]: "; t = STDIN.gets&.strip; defaults[:ocr_language] = t unless t.nil? || t.empty?
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
        if $opts[:no_ocr]
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
        warn "No PDFs in folder."
      else
        file = pick_pdf_interactively(pdfs)
        if file
          clear_ocr_cache_for_file(base_dir, file)
        else
          say "No file selected."
        end
      end
    when '9'
      print "Confirm deleting OCR cache for ENTIRE folder (type 'YES'): "
      conf = STDIN.gets&.strip
      if conf == 'YES'
        clear_ocr_cache_all(base_dir)
      else
        say "Cancelled."
      end
    when '10'
      print "Confirm deleting HTTP cache for ENTIRE folder (type 'YES'): "
      conf = STDIN.gets&.strip
      if conf == 'YES'
        clear_http_cache_all(base_dir)
      else
        say "Cancelled."
      end
    else
      warn "Unknown choice."
    end
  end
end

# ===================== Adopt defaults after first success =====================
def adopt_defaults_from_first_success!(base_dir, defaults, md)
  changed = false
  if defaults[:publication_name].to_s.strip.empty? && md[:publication_name] && !md[:publication_name].strip.empty?
    defaults[:publication_name] = md[:publication_name]; changed = true
  end
  if defaults[:issn].to_s.strip.empty? && md[:issn] && valid_issn?(md[:issn])
    defaults[:issn] = md[:issn]; changed = true
  end  end
  if defaults[:publisher].to_s.strip.empty? && md[:publisher] && !md[:publisher].strip.empty?
    defaults[:publisher] = md[:publisher]; changed = true
  end
  if changed
    save_folder_defaults(base_dir, defaults)
    say ">>> Folder defaults have been established from the first successful match:"
    say "    title='#{defaults[:publication_name]}', ISSN='#{defaults[:issn]}', publisher='#{defaults[:publisher]}'"
  end
end

# ===================== Main =====================
def main
  base_dir = ARGV[0]
  unless base_dir && Dir.exist?(base_dir)
    warn "Usage: ruby periodicals-getmeta.rb \"/path/to/folder/with/pdfs\""
    exit 1
  end

  ensure_cache_dir!(base_dir)
  acquire_lock!(base_dir)

  defaults = load_folder_defaults(base_dir)
  defaults[:ocr_language] ||= nil

  pdfs = Dir.glob(File.join(base_dir, "*.pdf")).sort

  # Interactive start menu
  show_start_menu!(base_dir, defaults, pdfs)

  if pdfs.empty?
    warn "No PDFs found in: #{base_dir}"
    release_lock!(base_dir)
    exit 0
  end

  pdfs.each do |pdf|
    sha = sha256_file(pdf)
    if already_embedded?(base_dir, pdf, sha)
      info "Skipping (already embedded): #{File.basename(pdf)}"
      next
    end

    parsed = parse_filename(pdf)
    pages, sha, ocr_source = extract_text_pages_with_cache(base_dir, pdf, defaults[:ocr_language])

    issn_hits = extract_issn_matches_per_page(pages)
    isbn_hits = extract_isbn_matches_per_page(pages)

    cands = []
    if defaults[:issn] && valid_issn?(defaults[:issn])
      cands += crossref_candidates(base_dir: base_dir, issn: defaults[:issn])
    end
    issn_hits.first(2).each { |h| cands += crossref_candidates(base_dir: base_dir, issn: h[:value]) }
    cands += crossref_candidates(base_dir: base_dir, title: parsed[:title])
    cands += wikidata_candidates(base_dir: base_dir, title: parsed[:title])
    cands = dedup_candidates(cands)

    loop do
      sel = prompt_select(pdf, parsed, cands, defaults)
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
        md = build_metadata(pdf, parsed, pick, defaults)
        md = manual_edit(md) if md[:publication_name].to_s.strip.empty? && md[:issn].to_s.strip.empty?
        ok = write_exiftool(pdf, md)
        append_state(base_dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha, status: (ok ? "embedded" : "error"),
          ocr_source: ocr_source, ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) }, metadata: md
        })
        adopt_defaults_from_first_success!(base_dir, defaults, md) if ok
        break
      when 'manual'
        pick = { title: parsed[:title], issn: issn_hits.first && issn_hits.first[:value], publisher: defaults[:publisher] }
        md = build_metadata(pdf, parsed, pick, defaults)
        md = manual_edit(md)
        ok = write_exiftool(pdf, md)
        append_state(base_dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha, status: (ok ? "embedded" : "error"),
          ocr_source: ocr_source, ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) }, metadata: md
        })
        adopt_defaults_from_first_success!(base_dir, defaults, md) if ok
        break
      when 'rescan'
        cands = requery_flow(base_dir, parsed[:title])
        cands = dedup_candidates(cands)
        next
      when 'pick'
        pick = sel[:pick]
        md = build_metadata(pdf, parsed, pick, defaults)
        if md[:publication_name].to_s.strip.empty? || md[:issn].to_s.strip.empty?
          say "Some fields are empty → manual fine-tuning:"
          md = manual_edit(md)
        end
        ok = write_exiftool(pdf, md)
        append_state(base_dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha, status: (ok ? "embedded" : "error"),
          ocr_source: ocr_source, ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) },
          metadata: md, pick: pick
        })
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
if __FILE__ == $0
  base_dir = ARGV[0]
  if !base_dir
    warn "Usage: ruby periodicals-getmeta.rb \"/path/to/folder/with/pdfs\""
    exit 1
  end
  main
end
