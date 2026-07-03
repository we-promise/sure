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
      t.index [ :id, :family_id ], unique: true, name: "idx_import_sessions_on_id_family"
      t.check_constraint "expected_chunks IS NULL OR expected_chunks > 0", name: "chk_import_sessions_expected_chunks_positive"
      t.check_constraint "client_session_id IS NULL OR btrim(client_session_id) <> ''",
                         name: "chk_import_sessions_client_session_id_present"
      t.check_constraint "import_type = 'SureImport'", name: "chk_import_sessions_import_type"
      t.check_constraint "status IN ('pending', 'importing', 'complete', 'failed')", name: "chk_import_sessions_status"
      t.check_constraint "jsonb_typeof(summary) = 'object'", name: "chk_import_sessions_summary_object"
      t.check_constraint "jsonb_typeof(error_details) = 'object'", name: "chk_import_sessions_error_details_object"
    end

    create_table :import_source_mappings, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :import_session, null: false, type: :uuid
      t.string :source_type, null: false, limit: 64
      t.string :source_id, null: false, limit: 255
      t.references :target, polymorphic: true, null: false, type: :uuid,
                            index: { name: "idx_import_source_mappings_on_target" }

      t.timestamps

      t.index [ :import_session_id, :source_type, :source_id ],
              unique: true,
              name: "index_import_source_mappings_on_session_type_and_source"
      t.index [ :family_id, :source_type, :source_id ], name: "idx_import_source_mappings_on_family_source"
      t.check_constraint "btrim(source_type) <> ''", name: "chk_import_source_mappings_source_type_present"
      t.check_constraint "source_type IN ('Account', 'Category', 'Tag', 'Merchant', 'RecurringTransaction', 'Transaction', 'Budget', 'Security', 'Rule')",
                         name: "chk_import_source_mappings_source_type"
      t.check_constraint "btrim(source_id) <> ''", name: "chk_import_source_mappings_source_id_present"
      t.check_constraint "btrim(target_type) <> ''", name: "chk_import_source_mappings_target_type_present"
      t.check_constraint "target_type IN ('Account', 'Category', 'Tag', 'Merchant', 'RecurringTransaction', 'Transaction', 'Budget', 'Security', 'Rule')",
                         name: "chk_import_source_mappings_target_type"
    end

    add_foreign_key :import_source_mappings, :import_sessions,
                    column: [ :import_session_id, :family_id ], primary_key: [ :id, :family_id ],
                    on_delete: :cascade, name: "fk_import_source_mappings_session_family"

    add_reference :imports, :import_session, type: :uuid
    add_column :imports, :sequence, :integer
    add_column :imports, :client_chunk_id, :string, limit: 255
    add_column :imports, :checksum, :string, limit: 64
    add_column :imports, :summary, :jsonb, null: false, default: {}
    add_column :imports, :error_details, :jsonb, null: false, default: {}

    add_index :imports, [ :import_session_id, :sequence ], unique: true,
              where: "import_session_id IS NOT NULL AND sequence IS NOT NULL", name: "idx_imports_on_session_sequence"
    add_index :imports, [ :import_session_id, :client_chunk_id ], unique: true,
              where: "import_session_id IS NOT NULL AND client_chunk_id IS NOT NULL", name: "idx_imports_on_session_client_chunk"
    add_foreign_key :imports, :import_sessions,
                    column: [ :import_session_id, :family_id ], primary_key: [ :id, :family_id ],
                    on_delete: :cascade, name: "fk_imports_session_family"
    add_check_constraint :imports, "sequence IS NULL OR sequence > 0", name: "chk_imports_session_sequence_positive"
    add_check_constraint :imports, "client_chunk_id IS NULL OR btrim(client_chunk_id) <> ''", name: "chk_imports_client_chunk_id_present"
    add_check_constraint :imports, "checksum IS NULL OR length(checksum) = 64", name: "chk_imports_checksum_sha256_length"
    add_check_constraint :imports, "import_session_id IS NULL OR sequence IS NOT NULL", name: "chk_imports_session_sequence_present"
    add_check_constraint :imports, "import_session_id IS NULL OR checksum IS NOT NULL", name: "chk_imports_session_checksum_present"
    add_check_constraint :imports, "jsonb_typeof(summary) = 'object'", name: "chk_imports_summary_object"
    add_check_constraint :imports, "jsonb_typeof(error_details) = 'object'", name: "chk_imports_error_details_object"
  end
end
