#!/usr/bin/env bash

set -euo pipefail

### --- CONFIGURATION ---
# Default OCR language (change as needed: dan, eng, deu, etc.)
OCR_LANG="dan"

# Directory to scan for PDFs
INPUT_DIR="."

# Locate Tesseract
TESSERACT_BIN="$(command -v tesseract || true)"

# Placeholder for Calibre binary
CALIBRE_BIN=""

### --- LOCATE CALIBRE BINARY ---
# Linux
if [[ -x "/usr/bin/ebook-convert" ]]; then
    CALIBRE_BIN="/usr/bin/ebook-convert"

# macOS
elif [[ -x "/Applications/calibre.app/Contents/MacOS/ebook-convert" ]]; then
    CALIBRE_BIN="/Applications/calibre.app/Contents/MacOS/ebook-convert"

# Windows via WSL
elif [[ -x "/mnt/c/Program Files/Calibre2/ebook-convert.exe" ]]; then
    CALIBRE_BIN="/mnt/c/Program Files/Calibre2/ebook-convert.exe"

else
    echo "❌ Could not locate ebook-convert. Please install Calibre."
    exit 1
fi

### --- CHECK TESSERACT ---
if [[ -z "$TESSERACT_BIN" ]]; then
    echo "❌ Tesseract not found. Please install tesseract-ocr."
    exit 1
fi

echo "Using Calibre: $CALIBRE_BIN"
echo "Using Tesseract: $TESSERACT_BIN"
echo "OCR language: $OCR_LANG"
echo

### --- FUNCTION: Detect if PDF contains text ---
# Uses pdftotext to extract text to stdout and checks for alphanumeric characters.
has_text() {
    local file="$1"
    if pdftotext "$file" - 2>/dev/null | grep -q '[A-Za-z0-9]'; then
        return 0
    else
        return 1
    fi
}

### --- MAIN LOOP: Process all PDF files ---
find "$INPUT_DIR" -maxdepth 1 -type f -iname "*.pdf" | while read -r pdf; do
    base="${pdf%.*}"
    echo "📄 Processing: $pdf"

    # 1) Check if PDF already contains text
    if has_text "$pdf"; then
        echo "   ✔ PDF contains text (OCR not required)"
        ocr_pdf="$pdf"
    else
        echo "   ⚠ No text detected → running OCR"

        # 2) Rename original file to .org.pdf (only once)
        orig="${base}.org.pdf"
        if [[ ! -f "$orig" ]]; then
            mv "$pdf" "$orig"
        fi

        # 3) Run Tesseract OCR
        ocr_pdf="${base}.pdf"
        "$TESSERACT_BIN" "$
