import zipfile
import re
import json
import base64
import uuid
import shutil

# --------------------------------------------------
# Helpers
# --------------------------------------------------

def new_uuid():
    return str(uuid.uuid4())

def new_mendeley_id():
    return "MENDELEY_CITATION_" + new_uuid()

def decode_mendeley(val):
    prefix = "MENDELEY_CITATION_v3_"
    if not val.startswith(prefix):
        return None
    b64 = val[len(prefix):]
    return json.loads(base64.b64decode(b64).decode("utf-8"))

def encode_mendeley(data):
    raw = json.dumps(data, separators=(',', ':'))
    return "MENDELEY_CITATION_v3_" + base64.b64encode(raw.encode()).decode()

def extract_zotero_json(instr):
    m = re.search(r'CSL_CITATION\s*(\{.*\})', instr, re.DOTALL)
    return json.loads(m.group(1)) if m else None


# --------------------------------------------------
# Detection
# --------------------------------------------------

def detect_format(xml):
    has_mendeley = "MENDELEY_CITATION_v3_" in xml
    has_zotero = "ZOTERO_ITEM CSL_CITATION" in xml

    if has_mendeley and has_zotero:
        return "mixed"
    elif has_mendeley:
        return "mendeley"
    elif has_zotero:
        return "zotero"
    else:
        return "none"


# --------------------------------------------------
# Conversion functions
# --------------------------------------------------

def mendeley_to_zotero(xml):

    def convert(match):
        tag_val = match.group(1)
        data = decode_mendeley(tag_val)
        if not data:
            return match.group(0)

        data["citationID"] = new_uuid()
        json_str = json.dumps(data)

        return (
            '<w:fldSimple w:instr="ADDIN ZOTERO_ITEM CSL_CITATION '
            + json_str.replace('"', '&quot;')
            + '"><w:r><w:t>[?]</w:t></w:r></w:fldSimple>'
        )

    return re.sub(
        r'<w:sdt[^>]*>.*?<w:tag w:val="(MENDELEY_[^"]+)".*?</w:sdt>',
        convert,
        xml,
        flags=re.DOTALL
    )


def zotero_to_mendeley(xml):

    def convert(match):
        instr = match.group(1)
        data = extract_zotero_json(instr)
        if not data:
            return match.group(0)

        data["citationID"] = new_mendeley_id()
        tag_val = encode_mendeley(data)

        return f"""
<w:sdt>
  <w:sdtPr>
    <w:tag w:val="{tag_val}"/>
    <w:id w:val="{uuid.uuid4().int % 2**31}"/>
  </w:sdtPr>
  <w:sdtContent>
    <w:r><w:t>[?]</w:t></w:r>
  </w:sdtContent>
</w:sdt>
"""

    return re.sub(
        r'<w:fldSimple[^>]*w:instr="([^"]*ZOTERO_ITEM[^"]*)".*?</w:fldSimple>',
        convert,
        xml,
        flags=re.DOTALL
    )


def convert_all(xml, target):
    if target == "zotero":
        xml = mendeley_to_zotero(xml)
    elif target == "mendeley":
        xml = zotero_to_mendeley(xml)
    return xml


# --------------------------------------------------
# Interactive decision
# --------------------------------------------------

def ask_user(detected):

    print(f"\n📄 Dokument indeholder: {detected}\n")

    if detected == "mendeley":
        print("👉 Fundet: Mendeley citationer")
        return input("Konverter til Zotero? (y/n): ").lower() == "y", "zotero"

    elif detected == "zotero":
        print("👉 Fundet: Zotero citationer")
        return input("Konverter til Mendeley? (y/n): ").lower() == "y", "mendeley"

    elif detected == "mixed":
        print("⚠️ Dokument indeholder BÅDE Mendeley og Zotero\n")
        print("Vælg mål:")
        print("1: Konverter ALT til Mendeley")
        print("2: Konverter ALT til Zotero")

        choice = input("Dit valg (1/2): ")

        if choice == "1":
            return True, "mendeley"
        elif choice == "2":
            return True, "zotero"
        else:
            return False, None

    else:
        print("❌ Ingen citationer fundet")
        return False, None


# --------------------------------------------------
# Main DOCX processing
# --------------------------------------------------

def process_docx(input_file):

    with zipfile.ZipFile(input_file) as z:
        xml = z.read("word/document.xml").decode("utf-8")

    detected = detect_format(xml)

    proceed, target = ask_user(detected)

    if not proceed:
        print("🚫 Ingen ændringer lavet")
        return

    xml = convert_all(xml, target)

    output_file = input_file.replace(".docx", f"_{target}.docx")
    shutil.copyfile(input_file, output_file)

    with zipfile.ZipFile(output_file, 'a') as z:
        z.writestr("word/document.xml", xml)

    print(f"\n✅ Konvertering færdig: {output_file}")
    print("👉 Husk i Word: CTRL+A → F9")


# --------------------------------------------------
# Run
# --------------------------------------------------

if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print("Brug: python convert_citations_auto.py fil.docx")
        exit()

    process_docx(sys.argv[1])
