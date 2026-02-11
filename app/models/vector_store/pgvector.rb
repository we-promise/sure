# Adapter that stores embeddings locally in PostgreSQL using the pgvector extension.
#
# This keeps all data on your own infrastructure — no external vector-store
# service required. You still need an embedding provider (e.g. OpenAI, or a
# local model served via an OpenAI-compatible endpoint) to turn text into
# vectors before insertion and at query time.
#
# Requirements (not yet wired up):
#   - PostgreSQL with the `vector` extension enabled
#   - gem "neighbor" (for ActiveRecord integration) or raw SQL
#   - An embedding model endpoint (EMBEDDING_MODEL_URL / EMBEDDING_MODEL_NAME)
#   - A chunking strategy (see #chunk_file below)
#
# Schema sketch (for reference — migration not included):
#
#   create_table :vector_store_chunks do |t|
#     t.string  :store_id,  null: false  # logical namespace
#     t.string  :file_id,   null: false
#     t.string  :filename
#     t.text    :content                 # the original text chunk
#     t.vector  :embedding, limit: 1536  # adjust dimensions to your model
#     t.jsonb   :metadata,  default: {}
#     t.timestamps
#   end
#   add_index :vector_store_chunks, :store_id
#   add_index :vector_store_chunks, :file_id
#
class VectorStore::Pgvector < VectorStore::Base
  def create_store(name:)
    with_response do
      # A "store" is just a logical namespace (a UUID).
      # No external resource to create.
      # { id: SecureRandom.uuid }
      raise VectorStore::Error, "Pgvector adapter is not yet implemented"
    end
  end

  def delete_store(store_id:)
    with_response do
      # TODO: DELETE FROM vector_store_chunks WHERE store_id = ?
      raise VectorStore::Error, "Pgvector adapter is not yet implemented"
    end
  end

  def upload_file(store_id:, file_content:, filename:)
    with_response do
      # 1. chunk_file(file_content, filename) → array of text chunks
      # 2. embed each chunk via the configured embedding model
      # 3. INSERT INTO vector_store_chunks (store_id, file_id, filename, content, embedding)
      raise VectorStore::Error, "Pgvector adapter is not yet implemented"
    end
  end

  def remove_file(store_id:, file_id:)
    with_response do
      # TODO: DELETE FROM vector_store_chunks WHERE store_id = ? AND file_id = ?
      raise VectorStore::Error, "Pgvector adapter is not yet implemented"
    end
  end

  def search(store_id:, query:, max_results: 10)
    with_response do
      # 1. embed(query) → vector
      # 2. SELECT content, filename, file_id,
      #           1 - (embedding <=> query_vector) AS score
      #    FROM   vector_store_chunks
      #    WHERE  store_id = ?
      #    ORDER  BY embedding <=> query_vector
      #    LIMIT  max_results
      raise VectorStore::Error, "Pgvector adapter is not yet implemented"
    end
  end

  private

    # Placeholder: split file content into overlapping text windows.
    # A real implementation would handle PDFs, DOCX, etc. via
    # libraries like `pdf-reader`, `docx`, or an extraction service.
    def chunk_file(file_content, filename)
      # TODO: implement format-aware chunking
      []
    end

    # Placeholder: call an embedding API to turn text into a vector.
    def embed(text)
      # TODO: call EMBEDDING_MODEL_URL or OpenAI embeddings endpoint
      raise VectorStore::Error, "Embedding model not configured"
    end
end
