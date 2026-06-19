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


def extract_zotero_bibl(instr):
    m = re.search(r'ZOTERO_BIBL\s*(\{.*?\})', instr)
    return json.loads(m.group(1)) if m else None


# --------------------------------------------------
# Conversion: Mendeley → Zotero
# --------------------------------------------------

def mendeley_to_zotero(xml):

    # --- Citation ---
    def convert_citation(match):
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

    xml = re.sub(
        r'<w:sdt[^>]*>.*?<w:tag w:val="(MENDELEY_[^"]+)".*?</w:sdt>',
        convert_citation,
        xml,
        flags=re.DOTALL
    )

    # --- Bibliografi ---
    xml = re.sub(
        r'MENDELEY_BIBLIOGRAPHY',
        'ADDIN ZOTERO_BIBL {"uncited":[],"omitted":[],"custom":[]} CSL_BIBLIOGRAPHY',
        xml
    )

    return xml


# --------------------------------------------------
# Conversion: Zotero → Mendeley
# --------------------------------------------------

def zotero_to_mendeley(xml):

    # --- Citation ---
    def convert_citation(match):
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

    xml = re.sub(
        r'<w:fldSimple[^>]*w:instr="([^"]*ZOTERO_ITEM[^"]*)".*?</w:fldSimple>',
        convert_citation,
        xml,
        flags=re.DOTALL
    )

    # --- Bibliografi ---
    xml = re.sub(
        r'ADDIN ZOTERO_BIBL.*?CSL_BIBLIOGRAPHY',
        'MENDELEY_BIBLIOGRAPHY',
        xml,
        flags=re.DOTALL
    )

    return xml


# --------------------------------------------------
# DOCX handling
# --------------------------------------------------

def process_docx(input_file, mode):

    output_file = input_file.replace(".docx", f"_{mode}.docx")
    shutil.copyfile(input_file, output_file)

    with zipfile.ZipFile(output_file, 'a') as z:
        xml = z.read("word/document.xml").decode("utf-8")

        if mode == "zotero":
            xml = mendeley_to_zotero(xml)
        elif mode == "mendeley":
            xml = zotero_to_mendeley(xml)
        else:
            raise ValueError("Mode must be 'zotero' or 'mendeley'")

        z.writestr("word/document.xml", xml)

    print(f"✅ Done: {output_file}")


# --------------------------------------------------
# CLI
# --------------------------------------------------

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("file")
    parser.add_argument("mode", choices=["zotero", "mendeley"])

    args = parser.parse_args()

    process_docx(args.file, args.mode)
