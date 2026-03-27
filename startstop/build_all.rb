#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

TEMPLATE = "template.html"
OUTPUT   = "startstop.html"

# Load the extracted PDF text
raw_data = JSON.parse(File.read("pdf_raw_text.json"))
lines = raw_data["lines"]

puts "Læser #{lines.size} linjer fra pdf_raw_text.json"

# ============================================================================
# DRUG DICTIONARY
# ============================================================================
DRUGS = [
  "betablokker", "betablokkere", "bisoprolol", "nebivolol", "metoprolol", "carvedilol",
  "verapamil", "diltiazem",
  "NSAID", "NSAID-præparater",
  "SSRI", "SSRI-præparater", "SNRI", "citalopram", "escitalopram",
  "loopdiuretika", "loop-diuretika", "thiaziddiuretika", "thiazid",
  "ACE-hæmmere", "ACE-hæmmer",
  "AT2-antagonist", "AT2-blokkere", "AT-2 blokker",
  "antikoagulantia", "VKA", "DOAK", "marevan", "apixaban", "dabigatran", "edoxaban", "rivaroxaban",
  "antipsykotika", "haloperidol",
  "opioidanalgetika", "opioider", "morfin", "oxycodon", "fentanyl", "buprenorfin", "methadon", "tramadol", "pethidin",
  "digoxin",
  "PDE-5-hæmmere", "sildenafil", "tadalafil", "vardenafil",
  "amiodaron",
  "metformin",
  "colchicin",
  "nitrofurantoin",
  "bisfosfonater", "bisfosfonat",
  "metoclopramid",
  "statiner", "statinbehandling",
  "ASA", "acetylsalicylsyre",
  "clopidogrel", "ticagrelor", "prasugrel",
  "pladehæmmer", "pladehæmmere", "pladehæmmerbehandling",
  "benzodiazepiner", "zopiclone", "zolpidem",
  "antiepileptika",
  "antihistaminer",
  "antidepressiva", "TCA", "tricykliske antidepressivae",
  "alfablokker",
  "antikolinergika", "antikolinerg",
  "paracetamol",
  "gabapentinoider", "gabapentin", "pregabalin",
  "levodopa", "dopaminagonist", "ropinirol", "pramipexol", "rotigotin",
  "acethylcholinsterasehæmmer", "donepezil", "rivastigmine", "galantamine",
  "PPI", "protonpumpehæmmer",
  "laksantia", "laksantium", "lactulose", "macrogol", "sorbitol",
  "probiotika",
  "aldosteronantagonist", "spironolakton", "eplerenone",
  "SGLT-2 hæmmer", "canagliflozin", "dapagliflozin", "empagliflozin", "ertugliflozin",
  "sacubitril/valsartan", "sacubitril", "valsartan",
  "erytropoietin", "EPO",
  "vitamin D", "calcium", "calciumtilskud", "vitamin D-tilskud",
  "denosumab",
  "propranolol",
  "antihypertensiv", "antihypertensivae", "antihypertensivum"
].freeze

# ============================================================================
# DISEASE DICTIONARY
# ============================================================================
DISEASES = [
  "hjertesvigt", "HfREF", "NYHA",
  "hypertension", "hypotension", "ortostatisk hypotension",
  "atrieflimren", "atrieflimren/flagren", "bradykardi", "bradyarytmier", "takykardi", "supraventrikulær takykardi",
  "angina pectoris", "coronarkarsygdom", "koronar", "AKS", "akut koronar syndrom",
  "aortastenose", "aortaaneurisme", "mitralstenose",
  "stroke", "TCI", "TIA",
  "DVT", "dyb venetrombose", "lungeemboli", "venøs tromboemboli",
  "hyperkaliæmi", "hypokaliæmi", "hyponatriæmi", "hypercalkæmi",
  "artritis urica", "urinsyregigt",
  "urininkontinens", "urgeinkontinens", "overaktiv blære",
  "nyresygdom", "nyreinsufficiens", "kronisk nyreinsufficiens",
  "leversygdom", "leversvigt", "kronisk leversygdom",
  "diabetes", "type 2-diabetes",
  "demens", "Alzheimers demens", "Lewy body demens", "kognitiv svækkelse",
  "Parkinsons sygdom", "Parkinsonisme",
  "depression", "angst",
  "Restless Legs Syndrome", "RLS", "essentiel tremor",
  "osteoporose", "osteoartrit", "artrose",
  "GORD", "gastroøsofageal refluxsygdom", "refluxøsofagitis", "ulcussygdom",
  "forstoppelse", "divertikulose",
  "KOL", "astma", "respiratorisk insufficiens",
  "anæmi", "jernmangel",
  "skrøbelighed", "frailty",
  "fald", "faldtilfælde", "tilbagevendende faldtilfælde",
  "blødning", "blødningsrisiko", "GI blødning",
  "QTc-forlængelse", "arytmi",
  "glaukom", "katarakt",
  "BPH", "benign prostatahyperplasi", "forstørret prostata",
  "insomni", "søvnløshed",
  "kvalme", "opkastning"
].freeze

# ============================================================================
# SECTION TO DRUG_CLASS MAPPING
# ============================================================================
SECTION_DRUG_CLASS = {
  "Indikation for behandling" => "generel",
  "Det kardiovaskulære system" => "kardiovaskulær",
  "Koagulationssystemet" => "antikoagulation",
  "Centralnervesystemet" => "psykofarmaka",
  "Det renale system" => "renal",
  "Det gastrointestinale system" => "gastrointestinal",
  "Det respiratoriske system" => "respiratorisk",
  "Det muskuloskeletale system" => "muskuloskeletalt",
  "Det urogenitale system" => "urogenital",
  "Det endokrine system" => "endokrin",
  "Lægemiddelklasser, som øger risikoen for fald blandt sårbare ældre" => "faldrisiko",
  "Antikolinerg lægemiddelbyrde" => "antikolinerg",
  "Analgetika" => "smertestillende",
  "Anbefalede lægemidler" => "generel",
  "Vacciner" => "vaccine"
}.freeze

# ============================================================================
# PROCESS ITEM - creates one entry per drug mentioned
# ============================================================================
def process_item(items, number, description, section, section_full, category, drug_class)
  return if description.nil? || description.strip.empty?
  
  description = description.strip
  
  # Extract all drugs mentioned
  drugs_found = []
  DRUGS.each do |drug|
    # Case-insensitive word boundary match
    if description =~ /\b#{Regexp.escape(drug)}\b/i
      drugs_found << drug
    end
  end
  
  # Extract all diseases mentioned
  diseases_found = []
  DISEASES.each do |disease|
    if description =~ /\b#{Regexp.escape(disease)}\b/i
      diseases_found << disease
    end
  end
  
  # Extract eGFR if present
  egfr = description[/eGFR\s*[<>=]\s*\d+/i]
  
  # Extract risk/obs if present
  obs = description[/(risiko for[^.()]+)/i, 1]
  
  # If no specific drugs found, create one general entry
  if drugs_found.empty?
    items << {
      id: "#{category}-#{section}-#{number}",
      section: section,
      section_full: section_full,
      category: category,
      color: category == "STOPP" ? "red" : "green",
      number: number,
      name: nil,
      type: "general",
      drug_class: drug_class,
      description: description,
      diseases: diseases_found.uniq,
      egfr: egfr,
      obs: obs,
      stopp: category == "STOPP",
      start: category == "START"
    }
  else
    # Create one entry per drug found
    drugs_found.uniq.each do |drug|
      items << {
        id: "#{category}-#{section}-#{number}-#{drug.gsub(/[^a-zA-Z0-9]/, '')}",
        section: section,
        section_full: section_full,
        category: category,
        color: category == "STOPP" ? "red" : "green",
        number: number,
        name: drug,
        type: "drug",
        drug_class: drug_class,
        description: description,
        diseases: diseases_found.uniq,
        egfr: egfr,
        obs: obs,
        stopp: category == "STOPP",
        start: category == "START"
      }
    end
  end
end

# ============================================================================
# EXTRACTION
# ============================================================================

items = []
current_category = nil
current_section = nil
current_section_full = nil
current_drug_class = nil
i = 0

while i < lines.size
  line_obj = lines[i]
  text = line_obj["text"]  # Don't strip yet - need to preserve structure
  text_stripped = text.strip
  
  # Detect STOPP section
  if text =~ /Persons.*Prescriptions.*\(STOPP\)/
    current_category = "STOPP"
    puts "Found STOPP at line #{line_obj['line_num']}"
    i += 1
    next
  end
  
  # Detect START section
  if text =~ /\(START\).*version 3/
    current_category = "START"
    puts "Found START at line #{line_obj['line_num']}"
    i += 1
    next
  end
  
  # Skip until we have a category
  unless current_category
    i += 1
    next
  end
  
  # Detect section header (e.g., " Sektion A: Indikation for behandling")
  if text_stripped =~ /^Sektion\s+([A-Z]):\s*(.+)$/
    section_letter = $1
    section_name = $2.strip
    
    current_section = "Sektion #{section_letter}"
    current_section_full = text_stripped
    current_drug_class = SECTION_DRUG_CLASS[section_name] || section_name
    
    puts "Found section: #{current_section_full} -> drug_class: #{current_drug_class}"
    i += 1
    next
  end
  
  # Detect numbered criteria (e.g., " 1. Description...")
  if text_stripped =~ /^(\d+)\.?\s+(.+)$/
    number = $1
    description = $2
    
    # Accumulate multi-line description
    j = i + 1
    empty_line_count = 0
    while j < lines.size
      next_text = lines[j]["text"].strip
      
      # Stop at next numbered item or section
      break if next_text =~ /^\d+\.?\s+/
      break if next_text =~ /^Sektion\s+[A-Z]:/
      break if next_text =~ /^Appendix/
      break if next_text =~ /^Screeningsværktøj/
      
      # Allow one empty line, but stop at two consecutive empty lines
      if next_text.empty?
        empty_line_count += 1
        break if empty_line_count >= 2
        j += 1
        next
      end
      
      # Reset empty line counter and add text
      empty_line_count = 0
      description += " " + next_text
      j += 1
    end
    
    # Process this item
    process_item(items, number, description, current_section, current_section_full, 
                 current_category, current_drug_class)
    
    i = j
    next
  end
  
  i += 1
end

puts "\nFundet #{items.size} entries (drug-centric)."
puts "STOPP entries: #{items.count { |i| i[:stopp] }}"
puts "START entries: #{items.count { |i| i[:start] }}"

# Generate JSON
json_data = JSON.pretty_generate({ items: items })

# Save debug JSON file
debug_file = "startstop_debug.json"
File.write(debug_file, json_data)
puts "Debug JSON gemt → #{debug_file}"

# Insert into HTML template
abort "template.html mangler." unless File.exist?(TEMPLATE)

template = File.read(TEMPLATE)
html = template.gsub("__JSON_PLACEHOLDER__", json_data)

File.write(OUTPUT, html)

puts "Genereret HTML → #{OUTPUT}"
