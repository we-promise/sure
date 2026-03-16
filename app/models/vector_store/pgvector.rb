# Adapter that stores embeddings locally in PostgreSQL using the pgvector extension.
#
# This keeps all data on your own infrastructure — no external vector-store
# service required. You still need an embedding provider (e.g. OpenAI, or a
# local model served via an OpenAI-compatible endpoint such as Ollama) to turn
# text into vectors before insertion and at query time.
#
# Requirements:
#   - PostgreSQL with the `vector` extension enabled (use pgvector/pgvector Docker image)
#   - An embedding model endpoint (EMBEDDING_URI_BASE / EMBEDDING_MODEL)
#   - Migration: CreateVectorStoreChunks (run with VECTOR_STORE_PROVIDER=pgvector)
#
class VectorStore::Pgvector < VectorStore::Base
  include VectorStore::Embeddable

  def create_store(name:)
    with_response do
      { id: SecureRandom.uuid }
    end
  end

  def delete_store(store_id:)
    with_response do
      connection.exec_delete(
        "DELETE FROM vector_store_chunks WHERE store_id = $1",
        "VectorStore::Pgvector DeleteStore",
        [ bind_param("store_id", store_id) ]
      )
    end
  end

  def upload_file(store_id:, file_content:, filename:)
    with_response do
      text = extract_text(file_content, filename)
      raise VectorStore::Error, "Could not extract text from #{filename}" if text.blank?

      chunks = chunk_text(text)
      raise VectorStore::Error, "No chunks produced from #{filename}" if chunks.empty?

      vectors = embed_batch(chunks)
      file_id = SecureRandom.uuid
      now = Time.current

      chunks.each_with_index do |chunk_content, index|
        embedding_literal = "[#{vectors[index].join(',')}]"

        connection.exec_insert(
          <<~SQL,
            INSERT INTO vector_store_chunks
              (id, store_id, file_id, filename, chunk_index, content, embedding, metadata, created_at, updated_at)
            VALUES
              ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
          "VectorStore::Pgvector InsertChunk",
          [
            bind_param("id", SecureRandom.uuid),
            bind_param("store_id", store_id),
            bind_param("file_id", file_id),
            bind_param("filename", filename),
            bind_param("chunk_index", index),
            bind_param("content", chunk_content),
            bind_param("embedding", embedding_literal, ActiveRecord::Type::String.new),
            bind_param("metadata", "{}"),
            bind_param("created_at", now),
            bind_param("updated_at", now)
          ]
        )
      end

      { file_id: file_id }
    end
  end

  def remove_file(store_id:, file_id:)
    with_response do
      connection.exec_delete(
        "DELETE FROM vector_store_chunks WHERE store_id = $1 AND file_id = $2",
        "VectorStore::Pgvector RemoveFile",
        [
          bind_param("store_id", store_id),
          bind_param("file_id", file_id)
        ]
      )
    end
  end

  def search(store_id:, query:, max_results: 10)
    with_response do
      query_vector = embed(query)
      vector_literal = "[#{query_vector.join(',')}]"

      results = connection.exec_query(
        <<~SQL,
          SELECT content, filename, file_id,
                 1 - (embedding <=> $1::vector) AS score
          FROM   vector_store_chunks
          WHERE  store_id = $2
          ORDER  BY embedding <=> $1::vector
          LIMIT  $3
        SQL
        "VectorStore::Pgvector Search",
        [
          bind_param("embedding", vector_literal, ActiveRecord::Type::String.new),
          bind_param("store_id", store_id),
          bind_param("limit", max_results)
        ]
      )

      results.map do |row|
        {
          content: row["content"],
          filename: row["filename"],
          score: row["score"].to_f,
          file_id: row["file_id"]
        }
      end
    end
  end

  private

    def connection
      ActiveRecord::Base.connection
    end

    def bind_param(name, value, type = nil)
      type ||= ActiveModel::Type::Value.new
      ActiveRecord::Relation::QueryAttribute.new(name, value, type)
    end
end
