# pdf_extractor.rb
# Regex baseret STOPP/START parser

require "pdf/reader"
require_relative "drug_classifier"

module PDFExtractor

  SECTION_RE = /Sektion\s+([A-Z])/
  CRITERION_RE = /^(\d+)\.\s(.+)$/

  def self.extract(file)
    reader = PDF::Reader.new(file)
    items = []

    current_section = nil
    current_type    = nil

    reader.pages.each do |page|
      page.text.each_line do |line|
        line.strip!
        next if line.empty?

        if line =~ /STOPP/i
          current_type = "STOPP"
          next
        elsif line =~ /START/i
          current_type = "START"
          next
        end

        if line =~ SECTION_RE
          current_section = "Sektion #{$1}"
          next
        end

        if line =~ CRITERION_RE
          number, text = $1, $2
          drug_classes = DrugClassifier.classify(text)

          items << {
            id: "#{current_section}-#{number}",
            section: current_section,
            type: current_type,
            description: text,
            drug_class: drug_classes,
          }
        end
      end
    end

    items
  end
end
