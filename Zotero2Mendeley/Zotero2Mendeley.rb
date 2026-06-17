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
# MATCH: Zotero → Mendeley
# -----------------------------
def find_in_mendeley(item)
  title = clean(item["title"])
  year  = item["year"]

  MENDELEY_DB.find do |m|
    clean(m["title"]) == title &&
    m["year"].to_s == year.to_s
  end
end

# -----------------------------
# MATCH via Zotero RIS først
# -----------------------------
def match_item(itemData)
  title = clean(itemData["title"])
  year  = itemData.dig("issued", "date-parts", 0, 0).to_s rescue ""

  zotero_match = ZOTERO_DB.find do |z|
    clean(z["title"]) == title &&
    z["year"].to_s == year
  end

  return nil unless zotero_match

  find_in_mendeley(zotero_match)
end

# -----------------------------
# KONVERTER JSON
# -----------------------------
def convert_json(json_str)
  data = JSON.parse(json_str)

  new_items = data["citationItems"].map do |item|
    itemData = item["itemData"]

    match = match_item(itemData)

    {
      "id" => match ? Digest::MD5.hexdigest(match["title"]) : SecureRandom.uuid,
      "itemData" => itemData
    }
  end

  output = { "citationItems" => new_items }

  output["properties"] = data["properties"] if data["properties"]

  JSON.generate(output)
end

# -----------------------------
# DOCX processing
# -----------------------------
REGEX = /ADDIN ZOTERO_ITEM CSL_CITATION\s+({.*?})/m

def process_xml(xml)
  xml.gsub(REGEX) do |m|
    json = m.match(REGEX)[1]
    "ADDIN Mendeley Cite #{convert_json(json)}"
  end
end

Zip::File.open("input.docx") do |zip|
  Zip::File.open("output.docx", create: true) do |out|

    zip.each do |e|
      content = e.get_input_stream.read

      if e.name == "word/document.xml"
        content = process_xml(content)
      end

      out.get_output_stream(e.name) { |f| f.write(content) }
    end
  end
end

puts "✅ DONE"
