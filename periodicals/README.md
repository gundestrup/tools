# Periodicals
PDF scraper / loopup tool  

## Tools - OSX
Needs homebrew
```bash
brew install exiftool ocrmypdf tesseract poppler jq
```

Notes  
exiftool → writes XMP/PRISM metadata.  
ocrmypdf → OCR (uses tesseract under the hood).  
tesseract → OCR engine (you can add language packs later, e.g. brew install tesseract-lang).  
poppler → provides pdftotext.  
jq → useful for looking at JSON when debugging (the script uses Ruby stdlib for HTTP/JSON).  

Note: Crossref & Wikidata require a friendly User‑Agent. Please provide your email in the script (see the USER_AGENT_EMAIL constant) so that the APIs don't throttle you.  

## Usage - Functions in brief:

Reads a given folder.  
Creates/continues a state.jsonl in the folder (resume).  
Finds (and remembers) folder defaults (ISSN, publisher, canonical title) as you choose.  
Interactive prompt per file with top 5 candidates (title, ISSN, publisher, source).  
Writes selected metadata with exiftool (PRISM/XMP).  
Robust regex + checksum on ISSN/ISBN to avoid OCR artifacts.  

Save as e.g. periodicals-getmeta.rb, run: ruby ​​periodicals-getmeta.rb "/path/to/magazines"  

