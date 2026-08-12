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

  PGVECTOR_SUPPORTED_EXTENSIONS = (VectorStore::Embeddable::TEXT_EXTENSIONS + [ ".pdf" ]).uniq.freeze

  TABLE_NAME = "vector_store_chunks"

  # True when this adapter can actually operate: the chunks table already
  # exists, or the server has the pgvector extension available so
  # ensure_schema! can provision it on first use. The Registry consults this
  # before building the adapter, so an install without pgvector degrades to
  # the assistant's friendly "provider_not_configured" message instead of
  # raising raw PG errors mid-chat.
  def self.available?
    conn = ActiveRecord::Base.connection
    return true if conn.table_exists?(TABLE_NAME)

    conn.select_value(
      "SELECT 1 FROM pg_available_extensions WHERE name = 'vector' LIMIT 1"
    ).present?
  rescue StandardError
    false
  end

  def supported_extensions
    PGVECTOR_SUPPORTED_EXTENSIONS
  end

  def create_store(name:)
    with_response do
      { id: SecureRandom.uuid }
    end
  end

  def delete_store(store_id:)
    with_response do
      ensure_schema!
      connection.exec_delete(
        "DELETE FROM vector_store_chunks WHERE store_id = $1",
        "VectorStore::Pgvector DeleteStore",
        [ bind_param("store_id", store_id) ]
      )
    end
  end

  def upload_file(store_id:, file_content:, filename:)
    with_response do
      ensure_schema!
      text = extract_text(file_content, filename)
      raise VectorStore::Error, "Could not extract text from #{filename}" if text.blank?

      chunks = chunk_text(text)
      raise VectorStore::Error, "No chunks produced from #{filename}" if chunks.empty?

      vectors = embed_batch(chunks)
      file_id = SecureRandom.uuid
      now = Time.current

      connection.transaction do
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
      end

      { file_id: file_id }
    end
  end

  def remove_file(store_id:, file_id:)
    with_response do
      ensure_schema!
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
      ensure_schema!
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

    # Provisions the chunks table on first use, mirroring the
    # CreateVectorStoreChunks migration. Migrations cover db:migrate
    # upgrades, but fresh installs go through db:prepare → schema:load
    # (bin/docker-entrypoint), which marks conditional migrations as applied
    # without running them — and the table can't live in schema.rb because it
    # requires the vector extension. Idempotent; memoized per instance.
    def ensure_schema!
      return if @schema_ensured
      if connection.table_exists?(TABLE_NAME)
        @schema_ensured = true
        return
      end

      connection.enable_extension("vector") unless connection.extension_enabled?("vector")
      # if_not_exists on the DDL (not a Mutex) is the right concurrency guard
      # here: adapter instances are built per call and never shared across
      # threads, so the realistic race is two *processes* (e.g. web + Sidekiq)
      # provisioning at once. IF NOT EXISTS makes the loser's DDL a no-op
      # instead of a duplicate-relation error.
      connection.create_table(TABLE_NAME, id: :uuid, if_not_exists: true) do |t|
        t.string :store_id, null: false
        t.string :file_id, null: false
        t.string :filename
        t.integer :chunk_index, null: false, default: 0
        t.text :content, null: false
        t.column :embedding, "vector(#{ENV.fetch('EMBEDDING_DIMENSIONS', '1024')})", null: false
        t.jsonb :metadata, null: false, default: {}
        t.timestamps null: false
      end
      connection.add_index TABLE_NAME, :store_id, if_not_exists: true
      connection.add_index TABLE_NAME, :file_id, if_not_exists: true
      connection.add_index TABLE_NAME, [ :store_id, :file_id, :chunk_index ], unique: true,
        name: "index_vector_store_chunks_on_store_file_chunk", if_not_exists: true
      @schema_ensured = true
    rescue StandardError => e
      raise VectorStore::Error, "pgvector store unavailable: #{e.message}"
    end

    def connection
      ActiveRecord::Base.connection
    end

    def bind_param(name, value, type = nil)
      type ||= ActiveModel::Type::Value.new
      ActiveRecord::Relation::QueryAttribute.new(name, value, type)
    end
end
