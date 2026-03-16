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
      io = StringIO.new(file_content)
      reader = PDF::Reader.new(io)
      reader.pages.map(&:text).join("\n\n")
    rescue => e
      Rails.logger.error("VectorStore::Embeddable PDF extraction error: #{e.message}")
      nil
    end

    # Split text on paragraph boundaries (~2000 char chunks, ~200 char overlap).
    def chunk_text(text)
      return [] if text.blank?

      paragraphs = text.split(/\n\s*\n/)
      chunks = []
      current_chunk = +""

      paragraphs.each do |para|
        para = para.strip
        next if para.empty?

        if current_chunk.empty?
          current_chunk << para
        elsif (current_chunk.length + para.length + 2) <= CHUNK_SIZE
          current_chunk << "\n\n" << para
        else
          chunks << current_chunk.freeze
          # Start new chunk with overlap from the end of the previous chunk
          overlap = current_chunk.last(CHUNK_OVERLAP)
          current_chunk = +""
          current_chunk << overlap << "\n\n" << para
        end
      end

      chunks << current_chunk.freeze unless current_chunk.empty?
      chunks
    end

    # Embed a single text string → vector array.
    def embed(text)
      response = embedding_client.post("embeddings") do |req|
        req.body = {
          model: embedding_model,
          input: text
        }
      end

      data = response.body
      raise VectorStore::Error, "Embedding request failed: #{data}" unless data.is_a?(Hash) && data["data"]

      data["data"].first["embedding"]
    end

    # Batch embed, processing in groups of EMBED_BATCH_SIZE.
    def embed_batch(texts)
      vectors = []

      texts.each_slice(EMBED_BATCH_SIZE) do |batch|
        response = embedding_client.post("embeddings") do |req|
          req.body = {
            model: embedding_model,
            input: batch
          }
        end

        data = response.body
        raise VectorStore::Error, "Batch embedding request failed: #{data}" unless data.is_a?(Hash) && data["data"]

        # Sort by index to preserve order
        sorted = data["data"].sort_by { |d| d["index"] }
        vectors.concat(sorted.map { |d| d["embedding"] })
      end

      vectors
    end

    def embedding_client
      @embedding_client ||= Faraday.new(url: embedding_uri_base) do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{embedding_access_token}" if embedding_access_token.present?
        f.options.timeout = 120
        f.options.open_timeout = 10
      end
    end

    def embedding_model
      ENV.fetch("EMBEDDING_MODEL", "nomic-embed-text")
    end

    def embedding_dimensions
      ENV.fetch("EMBEDDING_DIMENSIONS", "1024").to_i
    end

    def embedding_uri_base
      ENV["EMBEDDING_URI_BASE"].presence || ENV["OPENAI_URI_BASE"].presence || "https://api.openai.com/v1/"
    end

    def embedding_access_token
      ENV["EMBEDDING_ACCESS_TOKEN"].presence || ENV["OPENAI_ACCESS_TOKEN"].presence
    end
end
