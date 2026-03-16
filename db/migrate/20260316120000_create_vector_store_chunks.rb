class CreateVectorStoreChunks < ActiveRecord::Migration[7.2]
  def up
    return unless ENV["VECTOR_STORE_PROVIDER"] == "pgvector"

    enable_extension "vector"

    create_table :vector_store_chunks, id: :uuid do |t|
      t.string :store_id, null: false
      t.string :file_id, null: false
      t.string :filename
      t.integer :chunk_index, null: false, default: 0
      t.text :content
      t.column :embedding, "vector(1024)"
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :vector_store_chunks, :store_id
    add_index :vector_store_chunks, :file_id
    add_index :vector_store_chunks, [ :store_id, :file_id ]
  end

  def down
    return unless table_exists?(:vector_store_chunks)

    drop_table :vector_store_chunks
    disable_extension "vector"
  end
end
