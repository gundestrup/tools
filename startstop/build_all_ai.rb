#!/usr/bin/env ruby
# build_all.rb – komplet STOPP/START generator

require "json"
require_relative "pdf_extractor"
require_relative "combo_engine"

TEMPLATE = "template.html"
OUTPUT   = "startstop.html"

pdf = Dir.glob("*.pdf").first
abort "Ingen PDF i mappen!" unless pdf

puts "Parser: #{pdf}"

items = PDFExtractor.extract(pdf)

puts "Fundet #{items.size} STOPP/START kriterier"

# Inject combos:
items.each do |item|
  item[:combo_warnings] = ComboEngine.check(item[:drug_class])
end

json = JSON.pretty_generate({ items: items })

template = File.read(TEMPLATE)
html = template.gsub("__JSON_PLACEHOLDER__", json)

File.write(OUTPUT, html)
puts "✔︎ Genereret #{OUTPUT}"
