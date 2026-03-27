#!/usr/bin/env ruby
# frozen_string_literal: true

require "pdf/reader"
require "json"

pdf_file = Dir.glob("*.pdf").first
abort "Ingen PDF-fil fundet." unless pdf_file

puts "Læser PDF: #{pdf_file}"

reader = PDF::Reader.new(pdf_file)

# Extract all text with line numbers
all_lines = []
line_number = 0

reader.pages.each_with_index do |page, page_num|
  page.text.each_line do |line|
    all_lines << {
      line_num: line_number,
      page: page_num + 1,
      text: line.chomp
    }
    line_number += 1
  end
end

# Save to JSON
output = {
  pdf_file: pdf_file,
  total_lines: all_lines.size,
  lines: all_lines
}

File.write("pdf_raw_text.json", JSON.pretty_generate(output))
puts "Gemt #{all_lines.size} linjer til pdf_raw_text.json"

# Also save a simple text version for easy viewing
File.write("pdf_raw_text.txt", all_lines.map { |l| "#{l[:line_num].to_s.rjust(5)}: #{l[:text]}" }.join("\n"))
puts "Gemt også til pdf_raw_text.txt for let læsning"
