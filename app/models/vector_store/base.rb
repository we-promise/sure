class VectorStore::Base
  SUPPORTED_EXTENSIONS = %w[
    .c .cpp .css .csv .docx .gif .go .html .java .jpeg .jpg .js .json
    .md .pdf .php .png .pptx .py .rb .sh .tar .tex .ts .txt .xlsx .xml .zip
  ].freeze

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
  # @return [Hash] { file_id: "file-identifier" }
  def upload_file(store_id:, file_content:, filename:)
    raise NotImplementedError
  end

  # Remove a previously uploaded file
  # @param store_id [String]
  # @param file_id [String]
  def remove_file(store_id:, file_id:)
    raise NotImplementedError
  end

  # Semantic search across indexed files
  # @param store_id [String]
  # @param query [String] natural-language search query
  # @param max_results [Integer]
  # @return [Array<Hash>] each { content:, filename:, score:, file_id: }
  def search(store_id:, query:, max_results: 10)
    raise NotImplementedError
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
