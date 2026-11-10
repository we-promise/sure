class CreateFamilyDocumentStores < ActiveRecord::Migration[8.1]
  def change
    create_table :family_document_stores, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :credential_fingerprint, null: false
      t.string :provider_store_id
      t.timestamps
    end

    add_index :family_document_stores, [ :family_id, :provider, :credential_fingerprint ], unique: true, name: "index_family_document_stores_on_credential_context"
    add_check_constraint :family_document_stores, "provider = 'openai'", name: "chk_family_document_stores_provider"

    # Null continues to mean installation-managed. Do not infer ownership of
    # existing remote IDs, migrate files, or overwrite families.vector_store_id.
    add_reference :family_documents, :family_document_store, type: :uuid, foreign_key: true
  end
end
