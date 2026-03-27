# Library Mappings

This folder contains configuration files for the STOPP/START extraction system.

## Files

- **`drugs.json`** - List of drug names and synonyms for extraction
- **`diseases.json`** - List of disease/condition names for tagging
- **`section_drug_class_mapping.json`** - Maps PDF section names to drug class categories

## Usage

These JSON files are loaded by `build_all.rb` during the extraction process. You can edit these files to:

- Add new drug names or synonyms
- Update disease terminology
- Modify section-to-drug-class mappings

## Format

All files use standard JSON format. Arrays for drugs/diseases, key-value object for section mappings.

## Reloading

After editing any of these files, simply run `ruby build_all.rb` again to use the updated mappings.
