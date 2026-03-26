# drug_ontology.rb
# Lokalt farmakologisk ontologi

module DrugOntology
  CLASSES = {
    "betablokkere" => %w[metoprolol bisoprolol atenolol carvedilol nebivolol],
    "calciumantagonister" => %w[verapamil diltiazem amlodipin],
    "NSAID" => %w[ibuprofen naproxen diclofenac indomethacin celecoxib],
    "ACE-hæmmere" => %w[enalapril ramipril lisinopril captopril],
    "AT2-blokkere" => %w[losartan candesartan valsartan],
    "PDE5-hæmmere" => %w[sildenafil tadalafil vardenafil avanafil],
    "SSRI" => %w[citalopram escitalopram sertralin fluoxetin],
    "SNRI" => %w[venlafaxin duloxetin],
    "antikoagulantia" => %w[warfarin apixaban rivaroxaban dabigatran],
    "diuretika" => %w[furosemid bumetanid hydrochlorthiazid indapamid],
    "opioider" => %w[morfin oxycodon fentanyl tramadol buprenorphin],
    "antipsykotika" => %w[haloperidol olanzapin risperidon quetiapin],
  }
end
