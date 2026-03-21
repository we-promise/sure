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

    # Only run this migration when pgvector is explicitly configured as the
    # vector store provider AND the extension is actually available on the
    # PostgreSQL server. Previously we only checked server availability,
    # which caused failures in production Docker environments where the
    # extension may be present but the DB user lacks superuser privileges
    # to enable it.
    def pgvector_available?
      return false unless ENV["VECTOR_STORE_PROVIDER"].to_s.downcase == "pgvector"

      result = ActiveRecord::Base.connection.execute(
        "SELECT 1 FROM pg_available_extensions WHERE name = 'vector' LIMIT 1"
      )
      result.any?
    rescue
      false
    end
end
