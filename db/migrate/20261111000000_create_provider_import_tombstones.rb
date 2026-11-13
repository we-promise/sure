class CreateProviderImportTombstones < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_import_tombstones, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :source, null: false
      t.string :external_id, null: false

      t.timestamps
    end

    add_index :provider_import_tombstones, [ :account_id, :source, :external_id ],
              unique: true, name: "index_provider_import_tombstones_on_account_source_external_id"
  end
end
