require 'json'
require 'zip'
require 'digest'
require 'securerandom'

ZOTERO_RIS = "Mit Bibliotek-zotero.ris.txt"
MENDELEY_RIS = "library.ris.txt"

# -----------------------------
# RIS PARSER (fælles)
# -----------------------------
def parse_ris(file)
  records = []
  current = {}

  File.foreach(file) do |line|
    line = line.strip

    if line.start_with?("TY")
      current = {}
    elsif line.start_with?("ER")
      records << current
    else
      if line =~ /^([A-Z0-9]{2})\s+-\s+(.*)/
        tag = $1
        val = $2

        case tag
        when "TI"
          current["title"] = val.strip
        when "PY"
          current["year"] = val[0..3]
        when "DO"
          current["doi"] = val.downcase
        when "AU"
          (current["authors"] ||= []) << val
        end
      end
    end
  end

  records
end

ZOTERO_DB  = parse_ris(ZOTERO_RIS)
MENDELEY_DB = parse_ris(MENDELEY_RIS)

# -----------------------------
# NORMALISERING
# -----------------------------
def clean(str)
  str.to_s.downcase.gsub(/[^a-z0-9]/, "")
end

# -----------------------------
