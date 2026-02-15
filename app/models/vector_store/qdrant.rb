# Adapter for Qdrant — a dedicated open-source vector database.
#
# Qdrant can run locally (Docker), self-hosted, or as a managed cloud service.
# Like the Pgvector adapter you still supply your own embedding model; Qdrant
# handles storage, indexing, and fast ANN search.
#
# Requirements (not yet wired up):
#   - A running Qdrant instance (QDRANT_URL, default http://localhost:6333)
#   - Optional QDRANT_API_KEY for authenticated clusters
#   - An embedding model endpoint (EMBEDDING_MODEL_URL / EMBEDDING_MODEL_NAME)
#   - gem "qdrant-ruby" or raw Faraday HTTP calls
#
# Mapping:
#   store  → Qdrant collection
#   file   → set of points sharing a file_id payload field
#   search → query vector + payload filter on store_id
#
class VectorStore::Qdrant < VectorStore::Base
  def initialize(url: "http://localhost:6333", api_key: nil)
    @url = url
    @api_key = api_key
  end

  def create_store(name:)
    with_response do
      # POST /collections/{collection_name} { vectors: { size: 1536, distance: "Cosine" } }
      # collection_name could be a slugified version of `name` or a UUID.
      raise VectorStore::Error, "Qdrant adapter is not yet implemented"
    end
  end

  def delete_store(store_id:)
    with_response do
      # DELETE /collections/{store_id}
      raise VectorStore::Error, "Qdrant adapter is not yet implemented"
    end
  end

  def upload_file(store_id:, file_content:, filename:)
    with_response do
      # 1. chunk file → text chunks
      # 2. embed each chunk
      # 3. PUT /collections/{store_id}/points { points: [...] }
      #    each point: { id: uuid, vector: [...], payload: { file_id, filename, content } }
      raise VectorStore::Error, "Qdrant adapter is not yet implemented"
    end
  end

  def remove_file(store_id:, file_id:)
    with_response do
      # POST /collections/{store_id}/points/delete
      #   { filter: { must: [{ key: "file_id", match: { value: file_id } }] } }
      raise VectorStore::Error, "Qdrant adapter is not yet implemented"
    end
  end

  def search(store_id:, query:, max_results: 10)
    with_response do
      # 1. embed(query) → vector
      # 2. POST /collections/{store_id}/points/search
      #    { vector: [...], limit: max_results, with_payload: true }
      # 3. map results → [{ content:, filename:, score:, file_id: }]
      raise VectorStore::Error, "Qdrant adapter is not yet implemented"
    end
  end

  private

    def connection
      @connection ||= Faraday.new(url: @url) do |f|
        f.request :json
        f.response :json
        f.adapter Faraday.default_adapter
        f.headers["api-key"] = @api_key if @api_key.present?
      end
    end

    def embed(text)
      raise VectorStore::Error, "Embedding model not configured"
    end
end
