require 'zip'
require 'json'
require 'securerandom'

INPUT_FILE  = "input.docx"
OUTPUT_FILE = "output_mendeley.docx"

# Finder Zotero field codes i XML
ZOTERO_REGEX = /ADDIN ZOTERO_ITEM CSL_CITATION\s+({.*?})/m

def convert_json(zotero_json_str)
  begin
    data = JSON.parse(zotero_json_str)

    new_items = (data["citationItems"] || []).map do |item|
      {
        "id" => SecureRandom.uuid,
        "itemData" => item["itemData"] || {}
      }
    end

    mendeley = {
      "citationItems" => new_items
    }

    return JSON.generate(mendeley)

  rescue => e
    puts "JSON fejl: #{e}"
    return zotero_json_str # fallback
  end
end

def process_document_xml(xml)
  xml.gsub(ZOTERO_REGEX) do |match|
    original_json = match.match(ZOTERO_REGEX)[1]

    converted_json = convert_json(original_json)

    "ADDIN Mendeley Cite #{converted_json}"
  end
end

# Åbn docx (zip)
Zip::File.open(INPUT_FILE) do |zip_file|

  # Kopiér til ny fil
  Zip::File.open(OUTPUT_FILE, create: true) do |out_zip|

    zip_file.each do |entry|
      content = entry.get_input_stream.read

      if entry.name == "word/document.xml"
        puts "Behandler document.xml..."
        content = process_document_xml(content)
      end

      out_zip.get_output_stream(entry.name) do |f|
        f.write(content)
      end
    end
  end
end

puts "✅ Færdig! Gemt som #{OUTPUT_FILE}"
