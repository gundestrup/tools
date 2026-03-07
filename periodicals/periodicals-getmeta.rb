#!/usr/bin/env ruby
# encoding: UTF-8

require 'json'
require 'uri'
require 'net/http'
require 'openssl'
require 'open3'
require 'fileutils'
require 'time'

# ============ Konfiguration ============
USER_AGENT_EMAIL = "din-email@eksempel.dk"  # <-- sæt din e-mail (bruges i API User-Agent)
MAX_CANDIDATES   = 5
STATE_FILENAME   = ".magmeta_state.jsonl"   # log/resume-fil i mappen
FOLDER_DEFAULTS  = ".magmeta_folder_defaults.json"
TIMEOUT_SECONDS  = 20

# ============ Hjælpefunktioner ============

def say(s) puts(s) end
def warn(s) $stderr.puts("[WARN] #{s}") end
def info(s) $stderr.puts("[INFO] #{s}") end

def run_cmd(cmd, stdin_data:nil)
  stdout, stderr, status = Open3.capture3(cmd, stdin_data: stdin_data)
  [stdout, stderr, status.success?]
end

def issn_candidate?(s)
  !!(s =~ /\bISSN\s*[: ]?\s*([0-9]{4})-([0-9Xx]{4})\b/)
end

def extract_issn_all(text)
  issns = text.scan(/\bISSN\s*[: ]?\s*([0-9]{4})-([0-9Xx]{4})\b/i).map { |a,b| "#{a}-#{b.upcase}" }
  issns += text.scan(/\b([0-9]{4})-([0-9Xx]{4})\b/).map { |a,b| "#{a}-#{b.upcase}" }
  issns.uniq.select { |x| valid_issn?(x) }
end

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
  remainder = sum % 11
  check = (11 - remainder) % 11
  expected = (check == 10 ? 'X' : check.to_s)
  digits[7] == expected
end

def extract_isbn_all(text)
  # Simpel ISBN 10/13 finder uden hyppig normalisering
  raw = text.scan(/\bISBN(?:-1[03])?\s*[: ]?\s*([0-9][0-9\- ]{8,}[0-9Xx])\b/i).flatten
  # Rens og valider groft (fuld ISBN-validering kan tilføjes senere)
  raw.map { |s| s.gsub(/[^0-9Xx]/, '') }.select { |s| s.length == 10 || s.length == 13 }.uniq
end

def month_from_text(s)
  map = {
    /jan(uary)?/i => "01", /feb(ruary)?/i => "02", /mar(ch)?/i => "03",
    /apr(il)?/i   => "04", /may/i        => "05", /jun(e)?/i   => "06",
    /jul(y)?/i    => "07", /aug(ust)?/i  => "08", /sep(t(ember)?)?/i => "09",
    /oct(ober)?/i => "10", /nov(ember)?/i=> "11", /dec(ember)?/i => "12"
  }
  map.each { |rx, m| return m if s =~ rx }
  nil
end

def parse_filename(fn)
  base = File.basename(fn, ".pdf")
  # Generisk: Title - YYYY-MM - ISSUE
  if base =~ /^(?<title>.+?)\s*[-–]\s*(?<year>\d{4})[-. ](?<month>\d{2sue>\d{1,5})$/i
    return {
      title: $~[:title].strip,
      year: $~[:year].to_i,
      month: $~[:month],
      issue: $~[:issue],
      source: "filename"
    }
  end
  # Tolerant fallback: Title YYYY-MM (Issue)
  if base =~ /^(?<title>.+?)\s+(?<year>\d{4})[-. ](?<month>\\d{1,5})$/i
    return {
      title: $~[:title].strip,
      year: $~[:year].to_i,
      month: $~[:month],
      issue: $~[:issue],
      source: "filename(fuzzy)"
    }
  end
  { title: base.strip, source: "filename(min)" }
end

def pdftotext(pdf, txt_out)
  cmd = %(pdftotext -layout "#{pdf}" "#{txt_out}")
  _, stderr, ok = run_cmd(cmd)
  ok
end

def ocr_to_text(pdf)
  ocr_pdf = pdf.sub(/\.pdf$/i, ".ocr.tmp.pdf")
  txt = pdf.sub(/\.pdf$/i, ".ocr.tmp.txt")
  FileUtils.rm_f([ocr_pdf, txt])
  # OCR PDF med tekstlag
  cmd = %(ocrmypdf --skip-text "#{pdf}" "#{ocr_pdf}")
  _, _, ok = run_cmd(cmd)
  if ok && File.exist?(ocr_pdf)
    return txt if pdftotext(ocr_pdf, txt) && File.exist?(txt)
  end
  nil
ensure
  # lad tmp-filer blive for debug? ellers ryd op:
  # FileUtils.rm_f([ocr_pdf])
end

def extract_text(pdf)
  txt = pdf.sub(/\.pdf$/i, ".tmp.txt")
  FileUtils.rm_f(txt)
  if pdftotext(pdf, txt) && File.exist?(txt)
    content = File.read(txt, mode:"r:UTF-8")
    return content unless content.strip.empty?
  end
  # Prøv OCR
  ocr_txt = ocr_to_text(pdf)
  if ocr_txt && File.exist?(ocr_txt)
    return File.read(ocr_txt, mode:"r:UTF-8")
  end
  ""
end

def http_get_json(url, headers: {})
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.read_timeout = TIMEOUT_SECONDS
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = "magmeta/1.0 (#{USER_AGENT_EMAIL})"
  headers.each { |k,v| req[k] = v }
  res = http.request(req)
  raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

def crossref_candidates(title: nil, issn: nil)
  out = []
  begin
    if issn
      jurl = "https://api.crossref.org/journals/#{URI.encode_www_form_component(issn)}"
      data = http_get_json(jurl)
      if (msg = data['message'])
        out << {
          source: "Crossref(journal)",
          title: msg['title'],
          issn: (Array(msg['ISSN']).first || issn),
          publisher: msg['publisher'],
          score: 1.0
        }
      end
    end
  rescue => e
    warn "Crossref journal lookup fejl: #{e}"
  end

  if title && (out.empty?)
    # Søg blandt journals (ikke works)
    begin
      s = "https://api.crossref.org/journals?query=#{URI.encode_www_form_component(title)}"
      data = http_get_json(s)
      items = data.dig('message', 'items') || []
      items.first(MAX_CANDIDATES).each_with_index do |it, idx|
        out << {
          source: "Crossref(search)",
          title: it['title'],
          issn: Array(it['ISSN']).first,
          publisher: it['publisher'],
          score: 0.8 - idx * 0.05
        }
      end
    rescue => e
      warn "Crossref search fejl: #{e}"
    end
  end
  out
end

def wikidata_candidates(title)
  return [] unless title && !title.strip.empty?
  out = []
  begin
    # 1) Find kandidater via wbsearchentities
    s = "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=#{URI.encode_www_form_component(title)}&language=en&type=item&limit=#{MAX_CANDIDATES}&format=json"
    data = http_get_json(s, headers: {"Accept"=>"application/json"})
    (data['search'] || []).first(MAX_CANDIDATES).each do |hit|
      qid = hit['id']
      # 2) Hent claims for ISSN (P236) og publisher (P123)
      ent = http_get_json("https://www.wikidata.org/wiki/Special:EntityData/#{qid}.json")
      entity = ent.dig('entities', qid) || {}
      claims = entity['claims'] || {}
      issn_vals = (claims['P236'] || []).map { |c| c.dig('mainsnak','datavalue','value') }.compact
      publisher_qids = (claims['P123'] || []).map { |c| c.dig('mainsnak','datavalue','value','id') }.compact
      publisher_names = []
      publisher_qids.each do |pq|
        begin
          pjson = http_get_json("https://www.wikidata.org/wiki/Special:EntityData/#{pq}.json")
          lab = pjson.dig('entities', pq, 'labels', 'en', 'value') || pjson.dig('entities', pq, 'labels', 'da', 'value')
          publisher_names << lab if lab
        rescue
        end
      end
      out << {
        source: "Wikidata",
        title: (entity.dig('labels','en','value') || entity.dig('labels','da','value') || hit['label'] || title),
        issn: issn_vals&.first,
        publisher: publisher_names&.first,
        score: 0.7
      }
    end
  rescue => e
    warn "Wikidata lookup fejl: #{e}"
  end
  out
end

def dedup_candidates(cands)
  # Prioritér med ISSN, titellighed, score
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

def load_folder_defaults(dir)
  path = File.join(dir, FOLDER_DEFAULTS)
  return {} unless File.exist?(path)
  JSON.parse(File.read(path), symbolize_names: true)
rescue
  {}
end

def save_folder_defaults(dir, hash)
  path = File.join(dir, FOLDER_DEFAULTS)
  File.write(path, JSON.pretty_generate(hash))
end

def write_exiftool(pdf, md)
  # Byg exiftool-kommando
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

def append_state(dir, entry)
  path = File.join(dir, STATE_FILENAME)
  File.open(path, "a", encoding:"UTF-8") { |f| f.puts(entry.to_json) }
end

def already_processed?(dir, pdf)
  path = File.join(dir, STATE_FILENAME)
  return false unless File.exist?(path)
  File.foreach(path) do |line|
    begin
      j = JSON.parse(line)
      return true if j["file"] == pdf && j["status"] == "embedded"
    rescue
    end
  end
  false
end

def prompt_select(file, parsed, cands, folder_defaults)
  say "\n—"
  say "Fil: #{File.basename(file)}"
  say "Fundet fra navn: title='#{parsed[:title]}' year='#{parsed[:year]}' month='#{parsed[:month]}' issue='#{parsed[:issue]}'"
  say "Folder defaults: #{folder_defaults.transform_values { |v| v.to_s[0,60] }}"

  if cands.empty?
    say "Ingen kandidater fundet. [M]anuel / [S]kip / [A]bort?"
    print "> "
    inp = STDIN.gets&.strip&.upcase
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
  # Kombinér valgte kandidater med parsed
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
    volume: nil,   # Kan sættes via manuel edit el. ekstra heuristik
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

def requery_flow(title)
  say "Ny søgetitel (Enter for '#{title}'): "
  print "> "
  t = STDIN.gets&.strip
  t = title if t.nil? || t.empty?
  c1 = crossref_candidates(title: t)
  c2 = wikidata_candidates(t)
  dedup_candidates(c1 + c2)
end

# ============ Hovedprogram ============

def main
  dir = ARGV[0]
  unless dir && Dir.exist?(dir)
    warn "Brug: ruby magmeta.rb /sti/til/mappen/med/pdf"
    exit 1
  end

  folder_defaults = load_folder_defaults(dir)
  say "Folder defaults indlæst: #{folder_defaults}"

  pdfs = Dir.glob(File.join(dir, "*.pdf")).sort
  pdfs.each do |pdf|
    next if already_processed?(dir, pdf)

    parsed = parse_filename(pdf)
    text = extract_text(pdf)

    issns = extract_issn_all(text)
    isbns = extract_isbn_all(text) # mest for debug/rapport

    # Byg kandidater
    cands = []
    # 1) Crossref med sikker (folder) ISSN først
    if folder_defaults[:issn] && valid_issn?(folder_defaults[:issn])
      cands += crossref_candidates(issn: folder_defaults[:issn])
    end
    # 2) OCR-fundet ISSN
    issns.first(2).each { |i| cands += crossref_candidates(issn: i) }
    # 3) Titel-søg
    title_for_search = parsed[:title]
    cands += crossref_candidates(title: title_for_search)
    cands += wikidata_candidates(title_for_search)
    cands = dedup_candidates(cands)

    loop do
      sel = prompt_select(pdf, parsed, cands, folder_defaults)
      case sel[:action]
      when 'abort'
        info "Afbrudt af bruger."
        exit 0
      when 'skip'
        append_state(File.dirname(pdf), { time: Time.now.iso8601, file: pdf, status: "skipped" })
        break
      when 'defaults'
        pick = {
          title: folder_defaults[:publication_name] || parsed[:title],
          issn: folder_defaults[:issn],
          publisher: folder_defaults[:publisher],
          source: "defaults",
          score: 0.6
        }
        md = build_metadata(pdf, parsed, pick, folder_defaults)
        md = manual_edit(md) if md[:publication_name].nil? && md[:issn].nil?
        ok = write_exiftool(pdf, md)
        append_state(File.dirname(pdf), { time: Time.now.iso8601, file: pdf, status: (ok ? "embedded" : "error"), metadata: md })
        # opdater defaults hvis gode
        if ok
          folder_defaults[:publication_name] ||= md[:publication_name]
          folder_defaults[:issn] ||= md[:issn]
          folder_defaults[:publisher] ||= md[:publisher]
          save_folder_defaults(File.dirname(pdf), folder_defaults)
        end
        break
      when 'manual'
        # Byg tom pick ud fra parsed + defaults
        pick = { title: parsed[:title], issn: issns.first, publisher: folder_defaults[:publisher] }
        md = build_metadata(pdf, parsed, pick, folder_defaults)
        md = manual_edit(md)
        ok = write_exiftool(pdf, md)
        append_state(File.dirname(pdf), { time: Time.now.iso8601, file: pdf, status: (ok ? "embedded" : "error"), metadata: md })
        if ok
          folder_defaults[:publication_name] ||= md[:publication_name]
          folder_defaults[:issn] ||= md[:issn] if md[:issn] && valid_issn?(md[:issn])
          folder_defaults[:publisher] ||= md[:publisher]
          save_folder_defaults(File.dirname(pdf), folder_defaults)
        end
        break
      when 'rescan'
        cands = requery_flow(title_for_search)
        cands = dedup_candidates(cands)
        next
      when 'pick'
        pick = sel[:pick]
        md = build_metadata(pdf, parsed, pick, folder_defaults)
        # hvis noget mangler, tilbyd manuel finpudsning
        if md[:publication_name].to_s.strip.empty? || md[:issn].to_s.strip.empty?
          say "Nogle felter er tomme → manuel finpudsning:"
          md = manual_edit(md)
        end
        ok = write_exiftool(pdf, md)
        append_state(File.dirname(pdf), { time: Time.now.iso8601, file: pdf, status: (ok ? "embedded" : "error"), metadata: md, pick: pick })
        if ok
          # Opdater defaults aggressivt efter første gode match
          folder_defaults[:publication_name] ||= md[:publication_name]
          folder_defaults[:issn] ||= md[:issn] if md[:issn] && valid_issn?(md[:issn])
          folder_defaults[:publisher] ||= md[:publisher]
          save_folder_defaults(File.dirname(pdf), folder_defaults)
        end
        break
      else
        warn "Ukendt valg."
      end
    end
  end

  say "\nFærdig. Log: #{File.join(dir, STATE_FILENAME)}. Folder defaults: #{File.join(dir, FOLDER_DEFAULTS)}"
end

main if __FILE__ == $0
