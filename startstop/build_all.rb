#!/usr/bin/env ruby
# frozen_string_literal: true

require "pdf/reader"
require "json"

TEMPLATE     = "template.html"
OUTPUT       = "startstop.html"

# Find første PDF-fil i mappen
pdf_file = Dir.glob("*.pdf").first
abort "Ingen PDF-fil fundet." unless pdf_file

puts "Bruger PDF: #{pdf_file}"

reader = PDF::Reader.new(pdf_file)

items = []
current_section = nil
current_type    = nil

section_regex = /Sektion\s+([A-Z])/
stopp_regex   = /(STOPP)/
start_regex   = /(START)/

criteria_regex = /^(\d+)\.\s(.+)$/

# Ekstra regex til lægemidler/drug_class
drug_regex = /
  (betablokker|verapamil|diltiazem|
   NSAID|SSRI|loopdiuretika|ACE\-hæmmere|
   antikoagulantia|antipsykotika|opioidanalgetika|
   digoxin|PDE\-5\-hæmmere|thiazid|amiodaron|
   metformin|colchicin|nitrofurantoin|
   bisfosfonater|metoclopramid)
/ix

# Regex for eGFR og risikotrender
egfr_regex  = /eGFR\s*[<>\=]\s*\d+/i
risk_regex  = /(risiko for.+)$/i

reader.pages.each do |page|
  page.text.each_line do |line|
    line = line.strip
    next if line.empty?

    if line =~ section_regex
      current_section = "Sektion #{$1}"
      next
    end

    if line =~ stopp_regex
      current_type = "STOPP"
      next
    end

    if line =~ start_regex
      current_type = "START"
      next
    end

    if line =~ criteria_regex
      number = $1
      text   = $2

      drug_classes = text.scan(drug_regex).flatten.uniq
      egfr         = text[egfr_regex]
      obs          = text[risk_regex]

      items << {
        id: "#{current_section}-#{number}",
        section: current_section,
        type: current_type,
        description: text,
        drug_class: drug_classes,
        egfr: egfr,
        obs: obs,
        diagnoses: []
      }
    end
  end
end

puts "Fundet #{items.size} kriterier."

json_data = JSON.pretty_generate({ items: items })

# Indsæt i HTML-template
abort "template.html mangler." unless File.exist?(TEMPLATE)

template = File.read(TEMPLATE)
html     = template.gsub("__JSON_PLACEHOLDER__", json_data)

File.write(OUTPUT, html)

puts "Genereret HTML → #{OUTPUT}"
