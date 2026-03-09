module Jekyll
  class DocumentGenerator < Generator
    safe true
    priority :normal

    def generate(site)
      docs_root = File.join(site.source, "assets", "documents")

      Dir.glob("#{docs_root}/**/*.*") do |filepath|
        next unless File.file?(filepath)

        rel_path = filepath.sub(site.source + "/", "")
        ext      = File.extname(filepath)
        next if ext.nil? || ext.empty?

        # Eksempel på filnavn:
        # 2026-03-01_Generalforsamling_Referat.pdf
        filename  = File.basename(filepath)
        basename  = File.basename(filepath, ext)

        if basename =~ /^(\d{4})-(\d{2})-(\d{2})_(.+)$/
          year, month, day, raw_title = $1, $2, $3, $4
          date = Date.parse("#{year}-#{month}-#{day}")
        else
          # fallback, hvis navnet ikke følger standarden
          raw_title = basename
          date = File.mtime(filepath)
        end

        # Læs kategori fra mappestrukturen
        category = File.dirname(rel_path).split("/")[-1]

        # Pæn titel: erstatter "_" med " "
        title = raw_title.gsub("_", " ")

        # Destinationen for den genererede Jekyll-side
        doc_file = "_documents/#{category}-#{basename}.md"

        document = Jekyll::Document.new(
          doc_file,
          site: site,
          collection: site.collections["documents"]
        )

        # Metadata til dokumentet
        document.data["title"]     = title
        document.data["date"]      = date
        document.data["category"]  = category.downcase
        document.data["file_url"]  = "/" + rel_path
        document.data["extension"] = ext.downcase

        # Indhold (valgfrit)
        document.content = "Dette dokument er automatisk oprettet ud fra filen."

        # Tilføj dokumentet til Jekyll
        site.collections["documents"].docs << document
      end
    end
  end
end
