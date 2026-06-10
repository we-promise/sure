class CreateVectorStoreChunks < ActiveRecord::Migration[7.2]
  def up
    return unless pgvector_available?

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
    drop_table :vector_store_chunks, if_exists: true
    disable_extension "vector" if extension_enabled?("vector")
  end

  private

    # Only run this migration when pgvector is the effective vector store AND
    # the extension is actually available on the PostgreSQL server.
    #
    # Provider selection goes through VectorStore::Registry.pgvector_effective?
    # (the single source of truth) rather than a raw VECTOR_STORE_PROVIDER check,
    # so an Anthropic-default install — which selects pgvector implicitly via
    # Setting.llm_provider without setting VECTOR_STORE_PROVIDER — still
    # provisions the table instead of failing later on a missing relation.
    #
    # The server-availability check stays: production Docker environments may
    # have the extension present but the DB user may lack superuser privileges
    # to enable it.
    def pgvector_available?
      return false unless VectorStore::Registry.pgvector_effective?

      result = ActiveRecord::Base.connection.execute(
        "SELECT 1 FROM pg_available_extensions WHERE name = 'vector' LIMIT 1"
      )
      result.any?
    rescue
      false
    end
end
