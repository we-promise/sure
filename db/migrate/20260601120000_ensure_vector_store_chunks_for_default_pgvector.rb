class EnsureVectorStoreChunksForDefaultPgvector < ActiveRecord::Migration[7.2]
  # CreateVectorStoreChunks only provisions the table when
  # VECTOR_STORE_PROVIDER == "pgvector" is set explicitly. Since #1986 makes
  # pgvector the *default* vector store for Anthropic installs (no
  # VECTOR_STORE_PROVIDER needed), a fresh Anthropic-only install would migrate
  # without the table and then fail on uploads/searches. Backfill it whenever
  # pgvector is the effective store, idempotently, so fresh and already-migrated
  # installs converge. Gating uses the same VectorStore::Registry predicate as
  # the runtime adapter selection, so the two can't drift again.
  def up
    return unless pgvector_effective?
    return unless pgvector_extension_available?
    return if table_exists?(:vector_store_chunks)

    enable_extension "vector" unless extension_enabled?("vector")

    create_table :vector_store_chunks, id: :uuid do |t|
      t.string :store_id, null: false
      t.string :file_id, null: false
      t.string :filename
      t.integer :chunk_index, null: false, default: 0
      t.text :content, null: false
      t.column :embedding, "vector(#{ENV.fetch('EMBEDDING_DIMENSIONS', '1024')})", null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :vector_store_chunks, :store_id
    add_index :vector_store_chunks, :file_id
    add_index :vector_store_chunks, [ :store_id, :file_id, :chunk_index ], unique: true,
      name: "index_vector_store_chunks_on_store_file_chunk"
  end

  def down
    # No-op: the table's lifecycle is owned by CreateVectorStoreChunks. This
    # migration only backfills it for the pgvector-by-default case, so reverting
    # must not drop a table other installs rely on.
  end

  private

    def pgvector_effective?
      VectorStore::Registry.pgvector_effective?
    rescue StandardError
      false
    end

    def pgvector_extension_available?
      ActiveRecord::Base.connection.execute(
        "SELECT 1 FROM pg_available_extensions WHERE name = 'vector' LIMIT 1"
      ).any?
    rescue StandardError
      false
    end
end
