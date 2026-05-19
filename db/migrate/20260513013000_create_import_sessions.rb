class CreateImportSessions < ActiveRecord::Migration[7.2]
  def change
    create_table :import_sessions, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :import_type, null: false, default: "SureImport"
      t.string :status, null: false, default: "pending"
      t.string :client_session_id, limit: 255
      t.integer :expected_chunks
      t.jsonb :summary, null: false, default: {}
      t.jsonb :error_details, null: false, default: {}

      t.timestamps

      t.index [ :family_id, :client_session_id ],
              unique: true,
              where: "client_session_id IS NOT NULL",
              name: "idx_import_sessions_on_family_client_session"
      t.index [ :family_id, :status ]
      t.index [ :id, :family_id ],
              unique: true,
              name: "idx_import_sessions_on_id_family"
    end

    create_table :import_source_mappings, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :import_session, null: false, type: :uuid
      t.string :source_type, null: false, limit: 64
      t.string :source_id, null: false, limit: 255
      t.references :target,
                   polymorphic: true,
                   null: false,
                   type: :uuid,
                   index: { name: "idx_import_source_mappings_on_target" }

      t.timestamps

      t.index [ :import_session_id, :source_type, :source_id ],
              unique: true,
              name: "index_import_source_mappings_on_session_type_and_source"
      t.index [ :family_id, :source_type, :source_id ],
              name: "idx_import_source_mappings_on_family_source"
    end

    add_foreign_key :import_source_mappings,
                    :import_sessions,
                    column: [ :import_session_id, :family_id ],
                    primary_key: [ :id, :family_id ],
                    on_delete: :cascade,
                    name: "fk_import_source_mappings_session_family"

    add_reference :imports,
                  :import_session,
                  type: :uuid,
                  foreign_key: { on_delete: :cascade }
    add_column :imports, :sequence, :integer
    add_column :imports, :client_chunk_id, :string, limit: 255
    add_column :imports, :checksum, :string, limit: 64
    add_column :imports, :summary, :jsonb, null: false, default: {}
    add_column :imports, :error_details, :jsonb, null: false, default: {}

    add_index :imports,
              [ :import_session_id, :sequence ],
              unique: true,
              where: "import_session_id IS NOT NULL AND sequence IS NOT NULL",
              name: "idx_imports_on_session_sequence"
    add_index :imports,
              [ :import_session_id, :client_chunk_id ],
              unique: true,
              where: "import_session_id IS NOT NULL AND client_chunk_id IS NOT NULL",
              name: "idx_imports_on_session_client_chunk"
  end
end
