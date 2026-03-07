#!/usr/bin/env ruby
# encoding: UTF-8
#
# periodicals-getmeta.rb
#
# Formål:
#  - Batch-annotere PDF-magasiner med indlejret XMP/PRISM-metadata.
#  - Parse filnavn -> (title, year, month, issue).
#  - Sideopdelt tekstudtræk + OCR (kun når nødvendigt), cache pr. PDF.
#  - Online opslag (Crossref/Wikidata) m. cache + TTL.
#  - Interaktiv top-5 kandidatvalg + folder defaults (ISSN, publisher, OCR-sprog).
#  - Log (JSONL) m. resume + page/position/kontekst for ISSN/ISBN til fejlfinding.
#
# Afhængigheder:
#   brew install exiftool ocrmypdf tesseract poppler
#   (valgfrit) brew install tesseract-lang  # flere OCR-sprog
#
# Brug:
#   ruby periodicals-getmeta.rb [/flags] "/sti/til/mappen/med/pdf"
#
# Flags (valgfri):
#   --set-lang          Tving valg af OCR-sprog for denne mappe (overskriver defaults)
#   --force             Ignorer HTTP/OCR-cache TTL (henter/ocr’er på ny)
#   --ttl-days=N        Sæt HTTP-cache-levetid i dage (default 14)
#   --no-ocr            Deaktiver OCR helt (kun pdftotext)
#   --debug             Udskriv ekstra INFO
#
# Bemærk:
#  - Angiv venligst din e-mail i USER_AGENT_EMAIL (bruges som User-Agent til Crossref/Wikidata).
#  - OCR-sprog kan være fx "eng", "dan" eller kombi "eng+dan".
#

require 'json'
require 'uri'
require 'net/http'
require 'openssl'
require 'open3'
require 'fileutils'
require 'time'
require 'digest'

# ============ Konfiguration (tilpas) ============
USER_AGENT_EMAIL = "din-email@eksempel.dk"   # <-- SÆT DIN E-MAIL HER
MAX_CANDIDATES   = 5

# Kun ÉN undermappe pr. rodmappe
CACHE_DIR          = ".periodicals_getmeta"
STATE_FILENAME     = "periodicals_getmeta.state.jsonl"
FOLDER_DEFAULTS_FN = "periodicals_getmeta.defaults.json"
LOCK_FILENAME      = "periodicals_getmeta.lock"

DEFAULT_CACHE_TTL_DAYS = 14
TIMEOUT_SECONDS         = 20

# ============ CLI flags ============
$options = {
  set_lang: false,
  force: false,
  ttl_days: DEFAULT_CACHE_TTL_DAYS,
  no_ocr: false,
  debug: false
}

def parse_args!
  args = ARGV.dup
  out = []
  args.each do |a|
    case a
    when '--set-lang'   then $options[:set_lang] = true
    when '--force'      then $options[:force] = true
    when '--no-ocr'     then $options[:no_ocr] = true
    when '--debug'      then $options[:debug] = true
    when /\A--ttl-days=(\d+)\z/ then $options[:ttl_days] = $1.to_i
    else out << a
    end
  end
  ARGV.replace(out)
end

def say(s) puts(s) end
def info(s) $stderr.puts("[INFO] #{s}") if $options[:debug] end
def warn(s) $stderr.puts("[WARN] #{s}") end

# ============ Filsystem-hjælpere ============
def cache_dir(base_dir) File.join(base_dir, CACHE_DIR) end
def ensure_cache_dir!(base_dir) FileUtils.mkdir_p(cache_dir(base_dir)) end
def state_path(base_dir) File.join(cache_dir(base_dir), STATE_FILENAME) end
def defaults_path(base_dir) File.join(cache_dir(base_dir), FOLDER_DEFAULTS_FN) end
def lock_path(base_dir) File.join(cache_dir(base_dir), LOCK_FILENAME) end

def http_cache_path(base_dir, provider, key)
  safe = key.downcase.gsub(/[^a-z0-9\-_:.]/i, '_')
  File.join(cache_dir(base_dir), "http_#{provider}__#{safe}.json")
end

def ocr_cache_path(base_dir, sha) File.join(cache_dir(base_dir), "ocr_#{sha}.json") end

def acquire_lock!(base_dir)
  lp = lock_path(base_dir)
  if File.exist?(lp)
    warn "Lock-fil findes allerede: #{lp}. En anden proces kører måske. Slet filen hvis du vil overstyre."
    exit 2
  end
  File.write(lp, "#{Process.pid}\n")
end

def release_lock!(base_dir)
  lp = lock_path(base_dir)
  FileUtils.rm_f(lp)
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

def load_folder_defaults(base_dir)
  load_json(defaults_path(base_dir)) || {}
end

def save_folder_defaults(base_dir, hash)
  save_json(defaults_path(base_dir), hash)
end

# ============ Kommandoafvikling ============
def run_cmd(cmd, stdin_data:nil)
  info "CMD: #{cmd}"
  stdout, stderr, status = Open3.capture3(cmd, stdin_data: stdin_data)
  [stdout, stderr, status.success?]
end

# ============ PDF utils ============
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
  # Byg ocrmypdf-kommando
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

  if !$options[:force] && (cached = load_json(cache_file))
    return [cached[:pages], sha, cached[:source] || "cache"]
  end

  # 1) uden OCR
  pages = extract_pages_from_pdf(pdf)
  source = "pdftotext"

  # 2) hvis behov og OCR er tilladt
  if !$options[:no_ocr] && need_ocr?(pages)
    if (ocr_pdf = ocrmypdf_once(pdf, ocr_langs))
      pages = extract_pages_from_pdf(ocr_pdf)
      source = "ocrmypdf"
      # ryd op hvis du vil:
      # FileUtils.rm_f(ocr_pdf)
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

# ============ Regex & matches ============
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
    # først eksplicit "ISSN"
    hits = find_with_positions(pg[:text], rx)
    # så fallback hvis intet fundet
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

# ============ Filnavn parsing ============
def parse_filename(fn)
  base = File.basename(fn, ".pdf")
  # Mønster: Title - YYYY-MM - ISSUE
  if base =~ /^(?<title>.+?)\s*[-–]\s*(?<year>\d{4})-. \s*[-–]\s*(?<issue>\d{1,5})$/i
    return {
      title: $~[:title].strip,
      year: $~[:year].to_i,
      month: $~[:month],
      issue: $~[:issue],
      source: "filename"
    }
  end
  # Tolerant variant: Title YYYY-MM ... ISSUE
  if base =~ /^(?<title>.+?)\s+(?<year>\d{4})[-..*?(?<issue>\d{1,5})$/i
    return {
      title: $~[:title].strip,
      year: $~[:year].to_i,
      month: $~[:month],
      issue: $~[:issue],
      source: "filename(fuzzy)"
    }
  end
  # Minimal
  { title: base.strip, source: "filename(min)" }
end

# ============ HTTP utils + cache ============
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
  # respectér TTL, med mindre --force
  if File.exist?(path) && !$options[:force]
    ttl_days = $options[:ttl_days] || DEFAULT_CACHE_TTL_DAYS
    if (Time.now - File.mtime(path)) / (24*3600.0) <= ttl_days
      return JSON.parse(File.read(path)) rescue nil
    end
  end
  data = http_get_json(url, headers: headers)
  File.write(path, JSON.pretty_generate(data))
  data
rescue => e
  warn "HTTP GET/cache-fejl (#{provider}/#{key}): #{e}"
  # Returnér evt. stale cache hvis findes
  if File.exist?(path)
    JSON.parse(File.read(path)) rescue nil
  else
    nil
  end
end

# ============ Opslagskilder ============
def crossref_candidates(base_dir:, title: nil, issn: nil)
  out = []
  if issn
    url = "https://api.crossref.org/journals/#{URI.encode_www_form_component(issn)}"
    data = cached_http_get_json(base_dir, "crossref_journal", issn, url)
    if (msg = data && data['message'])
      out << {
        source: "Crossref(journal)",
        title: msg['title'],
        issn: (Array(msg['ISSN']).first || issn),
        publisher: msg['publisher'],
        score: 1.0
      }
    end
  end
  if title && out.empty?
    url = "https://api.crossref.org/journals?query=#{URI.encode_www_form_component(title)}"
    data = cached_http_get_json(base_dir, "crossref_search", title, url)
    items = data && data.dig('message', 'items') || []
    items.first(MAX_CANDIDATES).each_with_index do |it, idx|
      out << {
        source: "Crossref(search)",
        title: it['title'],
        issn: Array(it['ISSN']).first,
        publisher: it['publisher'],
        score: 0.8 - idx * 0.05
      }
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
    out << {
      source: "Wikidata",
      title: (entity.dig('labels','en','value') || entity.dig('labels','da','value') || hit['label'] || title),
      issn: issn_vals&.first,
      publisher: pubname,
      score: 0.7
    }
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

# ============ OCR-sprog (Tesseract) ============
def tesseract_installed_languages
  out, err, ok = run_cmd("tesseract --list-langs")
  return [] unless ok
  lines = out.split(/\r?\n/).map(&:strip)
  # første linje kan være "List of available languages (4):"
  langs = lines.select { |l| l =~ /\A[a-z]{3}(\+[a-z]{3})*\z/i || l =~ /\A[a-z_]+\z/i }
  # tesseract kan også vise aliaser, vi tager alt der ikke ligner header
  if langs.empty?
    langs = lines.reject { |l| l.empty? || l =~ /list of/i }
  end
  langs.uniq
end

def choose_ocr_language_interactively!(base_dir, defaults)
  installed = tesseract_installed_languages
  if installed.empty?
    warn "Ingen Tesseract-sprog fundet. Installer fx: brew install tesseract-lang dan"
    print "Vil du køre videre UDEN OCR? (y/N): "
    ans = STDIN.gets&.strip&.downcase
    if ans == 'y'
      defaults[:ocr_language] = nil
      save_folder_defaults(base_dir, defaults)
      return
    else
      warn "Afbryder. Installer Tesseract sprogpakker og kør igen."
      exit 3
    end
  end

  say "\nInstallerede OCR-sprog (tesseract):"
  installed.each_with_index do |l, i|
    say "  [#{i+1}] #{l}"
  end
  say "\nVælg sprog-koder (fx 'eng' eller 'eng+dan')."
  say "Du kan også indtaste numre separeret med '+', fx '1+2'."
  print "Vælg: "
  inp = STDIN.gets&.strip

  chosen = nil
  if inp && inp =~ /\A(\d+(\+\d+)*)\z/
    parts = inp.split('+').map { |x| x.to_i }
    codes = parts.map { |idx| installed[idx-1] }.compact
    chosen = codes.join('+') unless codes.empty?
  else
    chosen = inp
  end

  chosen = chosen.to_s.strip
  if chosen.empty?
    warn "Intet valgt. Bevarer eksisterende: #{defaults[:ocr_language] || '(ingen)'}"
    return
  end

  # simpel validering: split på '+', check at alle findes i installed
  codes = chosen.split('+')
  invalid = codes.any? { |c| !installed.include?(c) }
  if invalid
    warn "Nogle koder ikke fundet i installerede sprog. Valgt: #{chosen}, installeret: #{installed.join(', ')}"
    print "Fortsæt alligevel med '#{chosen}'? (y/N): "
    ans = STDIN.gets&.strip&.downcase
    unless ans == 'y'
      warn "Afbryder valg. Prøv igen med --set-lang."
      exit 4
    end
  end

  defaults[:ocr_language] = chosen
  save_folder_defaults(base_dir, defaults)
  say "OCR-sprog sat til: #{chosen}"
end

# ============ Metadata-skrivning ============
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
  stdout, stderr, ok = run_cmd(cmd)
  unless ok
    warn "ExifTool fejl: #{stderr}"
  end
  ok
end

# ============ Interaktivt valg ============
def prompt_select(file, parsed, cands, folder_defaults)
  say "\n—"
  say "Fil: #{File.basename(file)}"
  say "Fundet fra navn: title='#{parsed[:title]}' year='#{parsed[:year]}' month='#{parsed[:month]}' issue='#{parsed[:issue]}'"
  say "Folder defaults: #{folder_defaults.transform_values { |v| v.to_s[0,60] }}"

  if cands.empty?
    say "Ingen kandidater fundet. [M]anuel / [S]kip / [A]bort?"
    print "> "
    inp = STDIN.gets&amp;.strip&amp;.upcase
    return { action: 'abort' } if inp == 'A'
    return { action: 'skip' }  if inp == 'S'
    return { action: 'manual' }
  end

  say "Kandidater:"
  cands.each_with_index do |c, i|
    say "[#{i+1}] #{c[:title]}  | ISSN: #{c[:issn] || '-'}  | Publisher: #{c[:publisher] || '-'}  (#{c[:source]})"
  end
  say "[D] Brug folder defaults    [M] Manuel    [S] Skip    [A] Abort    [R] Re-søg med anden titel"
  print "Vælg (1-#{cands.length}/D/M/S/A/R): "
  inp = STDIN.gets&.strip
  return { action: 'abort' } if inp&.upcase == 'A'
  return { action: 'skip' }  if inp&.upcase == 'S'
  return { action: 'manual' } if inp&.upcase == 'M'
  return { action: 'defaults' } if inp&.upcase == 'D'
  return { action: 'rescan' } if inp&.upcase == 'R'
  idx = inp.to_i
  if idx >= 1 && idx <= cands.length
    return { action: 'pick', pick: cands[idx-1] }
  else
    { action: 'manual' }
  end
end

def build_metadata(file, parsed, pick, folder_defaults)
  pubname = pick[:title] || folder_defaults[:publication_name] || parsed[:title]
  issn = pick[:issn] || folder_defaults[:issn]
  publisher = pick[:publisher] || folder_defaults[:publisher]

  year  = parsed[:year]
  month = parsed[:month] || "01"
  pubdate = [year, month].compact.join("-")

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
  say "Manuel redigering (tryk Enter for at beholde nuværende værdi)"
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
  say "Ny søgetitel (Enter for '#{title}'): "
  print "> "
  t = STDIN.gets&.strip
  t = title if t.nil? || t.empty?
  c1 = crossref_candidates(base_dir: base_dir, title: t)
  c2 = wikidata_candidates(base_dir: base_dir, title: t)
  dedup_candidates(c1 + c2)
end

# ============ Hovedprogram ============
def main
  parse_args!
  dir = ARGV[0]
  unless dir && Dir.exist?(dir)
    warn "Brug: ruby periodicals-getmeta.rb [/flags] /sti/til/mappen/med/pdf"
    exit 1
  end

  ensure_cache_dir!(dir)
  acquire_lock!(dir)
  defaults = load_folder_defaults(dir) || {}

  # OCR-sprog: kræv/tilbyd valg hvis ikke sat eller hvis --set-lang
  if $options[:set_lang] || !defaults.key?(:ocr_language)
    choose_ocr_language_interactively!(dir, defaults)
  else
    say "OCR-sprog (folder default): #{defaults[:ocr_language] || '(ingen)'}"
  end

  pdfs = Dir.glob(File.join(dir, "*.pdf")).sort
  if pdfs.empty?
    warn "Ingen PDF-filer fundet i: #{dir}"
    release_lock!(dir)
    exit 0
  end

  pdfs.each do |pdf|
    sha = sha256_file(pdf)
    if already_embedded?(dir, pdf, sha)
      info "Springer over (allerede embedded): #{File.basename(pdf)}"
      next
    end

    parsed = parse_filename(pdf)

    # Sideopdelt tekst (med cache og valgt OCR-sprog)
    pages, sha, ocr_source = extract_text_pages_with_cache(dir, pdf, defaults[:ocr_language])

    issn_hits = extract_issn_matches_per_page(pages)
    isbn_hits = extract_isbn_matches_per_page(pages)

    cands = []
    if defaults[:issn] && valid_issn?(defaults[:issn])
      cands += crossref_candidates(base_dir: dir, issn: defaults[:issn])
    end
    issn_hits.first(2).each { |h| cands += crossref_candidates(base_dir: dir, issn: h[:value]) }
    cands += crossref_candidates(base_dir: dir, title: parsed[:title])
    cands += wikidata_candidates(base_dir: dir, title: parsed[:title])
    cands = dedup_candidates(cands)

    loop do
      sel = prompt_select(pdf, parsed, cands, defaults)
      case sel[:action]
      when 'abort'
        info "Afbrudt af bruger."
        release_lock!(dir)
        exit 0
      when 'skip'
        append_state(dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha, status: "skipped",
          ocr_source: ocr_source,
          ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) }
        })
        break
      when 'defaults'
        pick = {
          title: defaults[:publication_name] || parsed[:title],
          issn: defaults[:issn],
          publisher: defaults[:publisher],
          source: "defaults",
          score: 0.6
        }
        md = build_metadata(pdf, parsed, pick, defaults)
        md = manual_edit(md) if md[:publication_name].to_s.strip.empty? && md[:issn].to_s.strip.empty?
        ok = write_exiftool(pdf, md)
        append_state(dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha,
          status: (ok ? "embedded" : "error"),
          ocr_source: ocr_source,
          ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) },
          metadata: md
        })
        if ok
          defaults[:publication_name] ||= md[:publication_name]
          defaults[:issn] ||= md[:issn] if md[:issn] && valid_issn?(md[:issn])
          defaults[:publisher] ||= md[:publisher]
          save_folder_defaults(dir, defaults)
        end
        break
      when 'manual'
        pick = { title: parsed[:title], issn: issn_hits.first && issn_hits.first[:value], publisher: defaults[:publisher] }
        md = build_metadata(pdf, parsed, pick, defaults)
        md = manual_edit(md)
        ok = write_exiftool(pdf, md)
        append_state(dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha,
          status: (ok ? "embedded" : "error"),
          ocr_source: ocr_source,
          ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) },
          metadata: md
        })
        if ok
          defaults[:publication_name] ||= md[:publication_name]
          defaults[:issn] ||= md[:issn] if md[:issn] && valid_issn?(md[:issn])
          defaults[:publisher] ||= md[:publisher]
          save_folder_defaults(dir, defaults)
        end
        break
      when 'rescan'
        cands = requery_flow(dir, parsed[:title])
        cands = dedup_candidates(cands)
        next
      when 'pick'
        pick = sel[:pick]
        md = build_metadata(pdf, parsed, pick, defaults)
        if md[:publication_name].to_s.strip.empty? || md[:issn].to_s.strip.empty?
          say "Nogle felter er tomme → manuel finpudsning:"
          md = manual_edit(md)
        end
        ok = write_exiftool(pdf, md)
        append_state(dir, {
          time: Time.now.iso8601, file: pdf, sha256: sha,
          status: (ok ? "embedded" : "error"),
          ocr_source: ocr_source,
          ocr_hits: { issn: issn_hits.first(5), isbn: isbn_hits.first(5) },
          metadata: md, pick: pick
        })
        if ok
          defaults[:publication_name] ||= md[:publication_name]
          defaults[:issn] ||= md[:issn] if md[:issn] && valid_issn?(md[:issn])
          defaults[:publisher] ||= md[:publisher]
          save_folder_defaults(dir, defaults)
        end
        break
      else
        warn "Ukendt valg."
      end
    end
  end

  say "\nFærdig. Log: #{state_path(dir)}. Defaults: #{defaults_path(dir)}. Cachemappe: #{cache_dir(dir)}"
  release_lock!(dir)
end

# Start
main if __FILE__ == $0
