# spec/regex_spec.rb

require_relative "../pdf_extractor"
require_relative "../drug_classifier"

RSpec.describe "Regex & AI Extraction" do

  it "finder sektion" do
    line = "Sektion B: Det kardiovaskulære system"
    expect(line =~ PDFExtractor::SECTION_RE).not_to be_nil
  end

  it "identificerer kriterielinje" do
    line = "3. Betablokker kombineret med verapamil"
    expect(line =~ PDFExtractor::CRITERION_RE).not_to be_nil
  end

  it "klassificerer drug classes" do
    classes = DrugClassifier.classify("Betablokker kombineret med verapamil")
    expect(classes).to include("betablokkere", "calciumantagonister")
  end

  it "kombinationsmotor virker" do
    selected = %w[betablokkere calciumantagonister]
    expect(ComboEngine.check(selected))
      .to include(/AV-blok/i)
  end

end
