module VectorStore::Embeddable
  extend ActiveSupport::Concern

  CHUNK_SIZE = 2000
  CHUNK_OVERLAP = 200
  EMBED_BATCH_SIZE = 50

  TEXT_EXTENSIONS = %w[
    .txt .md .csv .json .xml .html .css
    .js .ts .py .rb .go .java .php .c .cpp .sh .tex
  ].freeze

  private

    # Dispatch by extension: PDF via PDF::Reader, plain-text types as-is.
    # Returns nil for unsupported binary formats.
    def extract_text(file_content, filename)
      ext = File.extname(filename).downcase

      case ext
      when ".pdf"
        extract_pdf_text(file_content)
      when *TEXT_EXTENSIONS
        file_content.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      else
        nil
      end
    end

    def extract_pdf_text(file_content)
      Pdf::TextExtractor.pages(file_content).join("\n\n")
    rescue => e
      Rails.logger.error("VectorStore::Embeddable PDF extraction error: #{e.message}")
      nil
    end

    # Split text on paragraph boundaries (~2000 char chunks, ~200 char overlap).
    # Paragraphs longer than CHUNK_SIZE are hard-split to avoid overflowing
    # embedding model token limits.
    def chunk_text(text)
      return [] if text.blank?

      paragraphs = text.split(/\n\s*\n/)
      chunks = []
      current_chunk = +""

      paragraphs.each do |para|
        para = para.strip
        next if para.empty?

        # Hard-split oversized paragraphs into CHUNK_SIZE slices with overlap
        slices = if para.length > CHUNK_SIZE
          hard_split(para)
        else
          [ para ]
        end

        slices.each do |slice|
          if current_chunk.empty?
            current_chunk << slice
          elsif (current_chunk.length + slice.length + 2) <= CHUNK_SIZE
            current_chunk << "\n\n" << slice
          else
            chunks << current_chunk.freeze
            overlap = current_chunk.last(CHUNK_OVERLAP)
            current_chunk = +""
            current_chunk << overlap << "\n\n" << slice
          end
        end
      end

      chunks << current_chunk.freeze unless current_chunk.empty?
      chunks
    end

    # Hard-split a single long string into CHUNK_SIZE slices with CHUNK_OVERLAP.
    def hard_split(text)
      slices = []
      offset = 0
      while offset < text.length
        slices << text[offset, CHUNK_SIZE]
        offset += CHUNK_SIZE - CHUNK_OVERLAP
      end
      slices
    end
end
