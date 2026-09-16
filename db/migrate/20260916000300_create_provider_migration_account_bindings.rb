class CreateProviderMigrationAccountBindings < ActiveRecord::Migration[8.1]
  def up
    add_index :provider_migration_mappings, [ :id, :family_id ], unique: true, name: "idx_pmm_identity_tenant"
    create_table :provider_migration_account_bindings, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.uuid :provider_migration_mapping_id, null: false
      t.uuid :first_batch_id, null: false
      t.string :source_checksum, null: false
      t.integer :chunk_count, null: false
      t.string :binding_state, null: false
      # Historical identities, deliberately without live Account/AccountProvider FKs.
      t.uuid :financial_account_id
      t.uuid :account_provider_id
      t.datetime :created_at, null: false
    end
    add_index :provider_migration_account_bindings, [ :provider_migration_mapping_id, :source_checksum ],
      unique: true, name: "idx_pmab_archive"
    add_index :provider_migration_account_bindings, :first_batch_id, unique: true, name: "idx_pmab_first_batch"
    add_index :provider_migration_account_bindings, [ :family_id, :financial_account_id ], name: "idx_pmab_financial_owner"
    add_foreign_key :provider_migration_account_bindings, :provider_migration_mappings,
      column: [ :provider_migration_mapping_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_pmab_mapping_tenant"
    add_foreign_key :provider_migration_account_bindings, :ingestion_batches,
      column: [ :first_batch_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_pmab_batch_tenant"
    add_check_constraint :provider_migration_account_bindings, "source_checksum ~ '^v1-[0-9a-f]{64}$'", name: "chk_pmab_checksum"
    add_check_constraint :provider_migration_account_bindings, "chunk_count BETWEEN 1 AND 1024", name: "chk_pmab_chunks"
    add_check_constraint :provider_migration_account_bindings, <<~SQL.squish, name: "chk_pmab_binding"
      (binding_state = 'linked' AND financial_account_id IS NOT NULL AND account_provider_id IS NOT NULL) OR
      (binding_state = 'unlinked' AND financial_account_id IS NULL AND account_provider_id IS NULL)
    SQL

    execute <<~SQL
      CREATE FUNCTION guard_provider_migration_account_binding() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF NEW IS DISTINCT FROM OLD THEN
            RAISE EXCEPTION 'Retained account bindings are immutable' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END IF;
        PERFORM 1
          FROM provider_migration_mappings mapping
          JOIN provider_migration_controls control ON control.id = mapping.provider_migration_control_id
          JOIN external_accounts external ON external.id = mapping.external_account_id
          JOIN ingestion_batches batch ON batch.id = NEW.first_batch_id
          WHERE mapping.id = NEW.provider_migration_mapping_id AND mapping.role = 'external_account'
            AND mapping.family_id = NEW.family_id AND control.family_id = NEW.family_id
            AND external.family_id = NEW.family_id AND batch.family_id = NEW.family_id
            AND external.provider_connection_id = control.provider_connection_id
            AND external.provider_key = control.provider_key
            AND batch.provider_connection_id = control.provider_connection_id
            AND batch.external_account_id = mapping.external_account_id
            AND batch.origin_kind = 'migration' AND batch.stream = 'legacy_snapshot' AND batch.sequence = 0
            AND batch.scope_key = mapping.legacy_type || ':' || mapping.legacy_id::text
            AND batch.idempotency_key = 'migration:' || control.id::text || ':' || mapping.legacy_type || ':' ||
              mapping.legacy_id::text || ':' || NEW.source_checksum || ':0'
          FOR SHARE OF mapping, control, external, batch;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Retained account binding has no exact archive owner' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER provider_migration_account_binding_guard
        BEFORE INSERT OR UPDATE ON provider_migration_account_bindings
        FOR EACH ROW EXECUTE FUNCTION guard_provider_migration_account_binding();
    SQL
  end

  def down
    execute "LOCK TABLE provider_migration_account_bindings IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM provider_migration_account_bindings LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Retained account ownership must be dispositioned before rollback"
    end
    drop_table :provider_migration_account_bindings
    execute "DROP FUNCTION guard_provider_migration_account_binding()"
    remove_index :provider_migration_mappings, name: "idx_pmm_identity_tenant"
  end
end
