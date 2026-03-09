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

        # Example of filename:
        # 2026-03-01_Generalforsamling_Referat.pdf
        filename  = File.basename(filepath)
        basename  = File.basename(filepath, ext)

        if basename =~ /^(\d{4})-(\d{2})-(\d{2})_(.+)$/
          year, month, day, raw_title = $1, $2, $3, $4
          date = Date.parse("#{year}-#{month}-#{day}")
        else
          # fallback, if names does not fit standard
          raw_title = basename
          date = File.mtime(filepath)
        end

        # Read Category from folder structure
        category = File.dirname(rel_path).split("/")[-1]

        # Title Cleanup: replaces "_" with " "
        title = raw_title.gsub("_", " ")

        # Destination for generated Jekyll-side
        doc_file = "_documents/#{category}-#{basename}.md"

        document = Jekyll::Document.new(
          doc_file,
          site: site,
          collection: site.collections["documents"]
        )

        # Metadata for document
        document.data["title"]     = title
        document.data["date"]      = date
        document.data["category"]  = category.downcase
        document.data["file_url"]  = "/" + rel_path
        document.data["extension"] = ext.downcase

        # Content (optional)
        document.content = "Dette dokument er automatisk oprettet ud fra filen."

        # Add document to Jekyll
        site.collections["documents"].docs << document
      end
    end
  end
end
