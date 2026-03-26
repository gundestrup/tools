# combo_engine.rb
# Regelmotor for kombinations- og diagnoseinteraktioner

require_relative "drug_ontology"
require_relative "drug_classifier"

module ComboEngine

  # Eksempelregler – du kan udvide frit
  COMBO_RULES = [
    {
      classes: %w[betablokkere calciumantagonister],
      message: "Betablokker + calciumantagonist → risiko for AV-blok / bradykardi"
    },
    {
      classes: %w[NSAID antikoagulantia],
      message: "NSAID + antikoagulant → høj risiko for GI-blødning"
    },
    {
      classes: %w[ACE-hæmmere diuretika NSAID],
      message: "ACE + diuretika + NSAID → 'triple whammy' og risiko for AKI"
    }
  ]

  def self.check(selected_classes)
    normalized = selected_classes.map(&:downcase)

    COMBO_RULES.map do |rule|
      if rule[:classes].all? { |c| normalized.include?(c.downcase) }
        rule[:message]
      end
    end.compact
  end

end
