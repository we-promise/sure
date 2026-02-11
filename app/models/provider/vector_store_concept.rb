module Provider::VectorStoreConcept
  extend ActiveSupport::Concern

  # Supported file types for OpenAI vector stores.
  # Other providers should define their own supported types.
  SUPPORTED_EXTENSIONS = %w[
    .c .cpp .css .csv .docx .gif .go .html .java .jpeg .jpg .js .json
    .md .pdf .php .png .pptx .py .rb .sh .tar .tex .ts .txt .xlsx .xml .zip
  ].freeze

  def supports_vector_store?
    false
  end

  # Create a new vector store
  # @param name [String] human-readable name for the store
  # @return [Hash] { id: "vs_xxx" }
  def create_vector_store(name:)
    raise NotImplementedError, "Provider does not support vector stores"
  end

  # Delete an existing vector store
  # @param vector_store_id [String]
  def delete_vector_store(vector_store_id:)
    raise NotImplementedError, "Provider does not support vector stores"
  end

  # Upload a file and attach it to a vector store
  # @param vector_store_id [String]
  # @param file_content [String, IO] raw file content or IO object
  # @param filename [String] original filename with extension
  # @return [Hash] { file_id: "file-xxx", status: "completed" }
  def upload_file_to_vector_store(vector_store_id:, file_content:, filename:)
    raise NotImplementedError, "Provider does not support vector stores"
  end

  # Remove a file from a vector store
  # @param vector_store_id [String]
  # @param file_id [String]
  def remove_file_from_vector_store(vector_store_id:, file_id:)
    raise NotImplementedError, "Provider does not support vector stores"
  end

  # Search a vector store for relevant content
  # @param vector_store_id [String]
  # @param query [String] natural language search query
  # @param max_results [Integer] maximum number of results (default: 10)
  # @return [Array<Hash>] array of { content:, filename:, score:, file_id: }
  def search_vector_store(vector_store_id:, query:, max_results: 10)
    raise NotImplementedError, "Provider does not support vector stores"
  end
end
