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
      t.column :embedding, "vector(1024)", null: false
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

    # Check if the pgvector extension is installed in the PostgreSQL server,
    # not just whether it is enabled in this database. This lets the migration
    # run harmlessly on plain Postgres (CI, dev without pgvector) while still
    # creating the table on pgvector-capable servers.
    def pgvector_available?
      result = ActiveRecord::Base.connection.execute(
        "SELECT 1 FROM pg_available_extensions WHERE name = 'vector' LIMIT 1"
      )
      result.any?
    rescue
      false
    end
end
