class AddVectorStoreSupport < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :vector_store_id, :string

    create_table :family_documents, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :filename, null: false
      t.string :content_type
      t.integer :file_size
      t.string :provider_file_id
      t.string :status, null: false, default: "pending"
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :family_documents, :status
    add_index :family_documents, :provider_file_id
  end
end
