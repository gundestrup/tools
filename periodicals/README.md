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

## What the script delivers

Parses filename and extracts: title, year, month, issue.
OCRs only when necessary.
Finds ISSN/ISBN in text and validates ISSN with checksum.
Look up metadata in Crossref and Wikidata (free, robust for many journals).
Shows top 5 candidates and saves your selection in log.
Embeds XMP/PRISM in PDF via exiftool.
Saves defaults per folder (ISSN/publisher/title), so the rest of the folder runs faster.
Summary: You can interrupt at any time; the script skips already-embedded files.

## Extensions and tips
ISSN Portal (official): If you get API access, we can add a “resolver” with your API key for even more authoritative lookups.

Date/Volume heuristics:  
Extend the parser to catch “Spring 2014”, “April–May 2014” → normalize to 2014-04.  

Volume/Issue mapping may be found in some Crossref/Wikidata fields, but the variation is large for journals.

Language packs in OCR:  
Tesseract extra languages: brew install tesseract-lang and run ocrmypdf --language eng+dan.

Automation:  
Use Hazel/Automator to trigger the script when new PDFs land in the folder.
