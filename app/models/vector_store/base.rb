class VectorStore::Base
  SUPPORTED_EXTENSIONS = %w[
    .c .cpp .css .csv .docx .gif .go .html .java .jpeg .jpg .js .json
    .md .pdf .php .png .pptx .py .rb .sh .tar .tex .ts .txt .xlsx .xml .zip
  ].freeze

  # The score under which a search result isn't a match; without it every search returned
  # something. Calibrated on OpenAI's store (the relevant hit scored 0.84, unrelated ones
  # 0.14-0.17). Embedding models score differently (unrelated text: 0.47 on gemini-embedding-001,
  # 0.77 on granite), so it's meant to become a setting per embedding model.
  MIN_SCORE = 0.3

  # Create a new vector store / collection / namespace
  # @param name [String] human-readable name
  # @return [Hash] { id: "store-identifier" }
  def create_store(name:)
    raise NotImplementedError
  end

  # Delete a vector store and all its files
  # @param store_id [String]
  def delete_store(store_id:)
    raise NotImplementedError
  end

  # Upload and index a file
  # @param store_id [String]
  # @param file_content [String] raw file bytes
  # @param filename [String] original filename with extension
  # @param family [Family] whose `embed` route embeds the chunks, and whose usage it is
  # @return [Hash] { file_id: "file-identifier", status: "ready" | "processing" }
  def upload_file(store_id:, file_content:, filename:, family: nil)
    raise NotImplementedError
  end

  # Remove a previously uploaded file
  # @param store_id [String]
  # @param file_id [String]
  def remove_file(store_id:, file_id:)
    raise NotImplementedError
  end

  # Semantic search across indexed files, dropping weak matches
  # @param store_id [String]
  # @param query [String] natural-language search query
  # @param max_results [Integer]
  # @param family, user [Family, User] whose `search_documents` route embeds the query
  # @return [Array<Hash>] each { content:, filename:, score:, file_id: }
  def search(store_id:, query:, max_results: 10, family: nil, user: nil)
    raise NotImplementedError
  end

  # Where indexing of a file stands, for adapters that index asynchronously.
  # @return [Hash] { status: "ready" | "processing" | "unreadable" | "error", error: }
  def file_status(store_id:, file_id:)
    success(status: "ready")
  end

  # Which file extensions this adapter can ingest
  def supported_extensions
    SUPPORTED_EXTENSIONS
  end

  private

    def success(data)
      VectorStore::Response.new(success?: true, data: data, error: nil)
    end

    def failure(error)
      wrapped = error.is_a?(VectorStore::Error) ? error : VectorStore::Error.new(error.message)
      VectorStore::Response.new(success?: false, data: nil, error: wrapped)
    end

    def with_response(&block)
      data = yield
      success(data)
    rescue => e
      Rails.logger.error("#{self.class.name} error: #{e.class} - #{e.message}")
      failure(e)
    end
end
