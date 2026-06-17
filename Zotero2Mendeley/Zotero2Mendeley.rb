require 'zip'
require 'json'
require 'securerandom'

INPUT_FILE  = "input.docx"
OUTPUT_FILE = "output_mendeley.docx"
RIS_FILE    = "library.ris.txt"

ZOTERO_REGEX = /ADDIN ZOTERO_ITEM CSL_CITATION\s+({.*?})/m

# -----------------------------
# RIS PARSER
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
      current = {}
    else
      if line =~ /^([A-Z0-9]{2})\s+-\s+(.*)/
        tag, value = $1, $2

        case tag
        when "TI"
          current["title"] = value
        when "PY"
          current["year"] = value[0..3]
        when "DO"
          current["doi"] = value.downcase
        when "AU"
          (current["authors"] ||= []) << value
        end
      end
    end
  end

  records
end

RIS_DB = parse_ris(RIS_FILE)

# -----------------------------
# MATCHING
# -----------------------------
def normalize(str)
  str.to_s.downcase.gsub(/[^a-z0-9]/, "")
end

def match_item(itemData)
  title = normalize(itemData["title"])
  year  = itemData.dig("issued", "date-parts", 0, 0).to_s rescue ""
  doi   = itemData["DOI"]&.downcase

  # 1. DOI match (BEST)
  if doi
    match = RIS_DB.find { |r| r["doi"] == doi }
    return match if match
  end

  # 2. Title + year
  RIS_DB.find do |r|
    normalize(r["title"]) == title &&
    r["year"].to_s == year
  end
end

# -----------------------------
# CONVERT JSON
# -----------------------------
def convert_json(zotero_json_str)
  data = JSON.parse(zotero_json_str)

  new_items = data["citationItems"].map do |item|
    itemData = item["itemData"] || {}

    match = match_item(itemData)

    {
      "id" => match ? Digest::MD5.hexdigest(match["title"]) : SecureRandom.uuid,
      "itemData" => itemData
    }
  end

  # behold prefix/suffix/pages
  output = {
    "citationItems" => new_items
  }

  if data["properties"]
    output["properties"] = data["properties"]
  end

  JSON.generate(output)
end

# -----------------------------
# XML processing
# -----------------------------
def process_document_xml(xml)
  xml.gsub(ZOTERO_REGEX) do |match|
    original_json = match.match(ZOTERO_REGEX)[1]

    begin
      converted_json = convert_json(original_json)
      "ADDIN Mendeley Cite #{converted_json}"
    rescue => e
      puts "Fejl: #{e}"
      match
    end
  end
end

# -----------------------------
# DOCX processing
# -----------------------------
Zip::File.open(INPUT_FILE) do |zip_file|
  Zip::File.open(OUTPUT_FILE, create: true) do |out_zip|

    zip_file.each do |entry|
      content = entry.get_input_stream.read

      if entry.name == "word/document.xml"
        puts "Behandler document.xml..."
        content = process_document_xml(content)
      end

      out_zip.get_output_stream(entry.name) { |f| f.write(content) }
    end
  end
end

puts "✅ DONE: #{OUTPUT_FILE}"
