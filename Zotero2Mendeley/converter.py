import zipfile
import re
import json
import base64
import uuid
import shutil
import os

# -----------------------------
# Helpers
# -----------------------------

def decode_mendeley(tag_value):
    prefix = "MENDELEY_CITATION_v3_"
    if not tag_value.startswith(prefix):
        return None
    b64 = tag_value[len(prefix):]
    decoded = base64.b64decode(b64).decode("utf-8")
    return json.loads(decoded)


def encode_mendeley(data):
    b64 = base64.b64encode(json.dumps(data).encode("utf-8")).decode("utf-8")
    return "MENDELEY_CITATION_v3_" + b64


def extract_zotero_json(field):
    match = re.search(r'CSL_CITATION\s*(\{.*\})', field)
    if match:
        return json.loads(match.group(1))
    return None


def build_zotero_field(data):
    return 'ADDIN ZOTERO_ITEM CSL_CITATION ' + json.dumps(data)


def new_citation_id(prefix):
    return f"{prefix}_{uuid.uuid4()}"


# -----------------------------
# Core conversion
# -----------------------------

def convert_mendeley_to_zotero(xml):
    def repl(match):
        tag = match.group(1)
        data = decode_mendeley(tag)

        if not data:
            return match.group(0)

        # generate Zotero citationID
        data["citationID"] = str(uuid.uuid4())

        zotero_json = build_zotero_field(data)

        # replace entire block with field code style
        return f'<w:instrText>{zotero_json}</w:instrText>'

    xml = re.sub(r'w:tag w:val="(MENDELEY_[^"]+)"', repl, xml)
    return xml


def convert_zotero_to_mendeley(xml):
    def repl(match):
        field = match.group(0)
        data = extract_zotero_json(field)

        if not data:
            return field

        # generate Mendeley citationID
        data["citationID"] = new_citation_id("MENDELEY_CITATION")

        tag_value = encode_mendeley(data)

        return f'<w:tag w:val="{tag_value}"/>'

    xml = re.sub(r'ADDIN ZOTERO_ITEM CSL_CITATION\s*\{.*?\}', repl, xml, flags=re.DOTALL)
    return xml


# -----------------------------
# DOCX handling
# -----------------------------

def process_docx(input_file, mode):
    output_file = input_file.replace(".docx", f"_{mode}.docx")

    # copy file (docx = zip)
    shutil.copyfile(input_file, output_file)

    with zipfile.ZipFile(output_file, 'a') as z:
        xml = z.read('word/document.xml').decode('utf-8')

        if mode == "zotero":
            xml = convert_mendeley_to_zotero(xml)
        elif mode == "mendeley":
            xml = convert_zotero_to_mendeley(xml)
        else:
            raise ValueError("Mode must be 'zotero' or 'mendeley'")

        z.writestr('word/document.xml', xml)

    print(f"✅ Output written: {output_file}")


# -----------------------------
# CLI
# -----------------------------

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Convert Mendeley ↔ Zotero citations in DOCX")
    parser.add_argument("file", help="Input DOCX file")
    parser.add_argument("mode", choices=["zotero", "mendeley"],
                        help="Target format")

    args = parser.parse_args()

    process_docx(args.file, args.mode)
