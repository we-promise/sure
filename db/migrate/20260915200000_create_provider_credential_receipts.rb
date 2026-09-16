class CreateProviderCredentialReceipts < ActiveRecord::Migration[8.1]
  def up
    create_table :provider_credential_receipts, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :provider_connection, type: :uuid, null: false, foreign_key: true
      t.references :provider_sync_generation, type: :uuid, null: false, foreign_key: true, index: { name: "idx_pcr_generation" }
      t.references :sync, type: :uuid, null: false, foreign_key: true
      t.string :provider_sync_type, null: false, default: "ProviderConnection"
      t.uuid :preceding_batch_id
      t.string :request_key, null: false
      t.uuid :attempt_id, null: false
      t.integer :page_sequence, null: false
      t.integer :ordinal, null: false
      t.bigint :writer_epoch, null: false
      t.string :lease_owner, null: false
      t.bigint :from_revision, null: false
      t.bigint :to_revision, null: false
      t.string :kind, null: false
      t.text :evidence, null: false
      t.timestamps
    end
    add_index :provider_credential_receipts, [ :provider_connection_id, :to_revision ], unique: true, name: "idx_pcr_revision"
    add_index :provider_credential_receipts, [ :attempt_id, :ordinal ], unique: true, name: "idx_pcr_attempt"
    add_index :provider_credential_receipts, [ :provider_sync_generation_id, :page_sequence, :to_revision ], name: "idx_pcr_page"
    add_foreign_key :provider_credential_receipts, :provider_connections,
      column: [ :provider_connection_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_pcr_connection"
    add_foreign_key :provider_credential_receipts, :provider_sync_generations,
      column: [ :provider_sync_generation_id, :provider_connection_id, :family_id ], primary_key: [ :id, :provider_connection_id, :family_id ], name: "fk_pcr_generation"
    add_index :provider_sync_generations, [ :id, :sync_id ], unique: true, name: "idx_psg_receipt_sync"
    add_foreign_key :provider_credential_receipts, :provider_sync_generations,
      column: [ :provider_sync_generation_id, :sync_id ], primary_key: [ :id, :sync_id ], name: "fk_pcr_generation_sync"
    add_foreign_key :provider_credential_receipts, :syncs,
      column: [ :sync_id, :provider_connection_id, :provider_sync_type ], primary_key: [ :id, :syncable_id, :syncable_type ], name: "fk_pcr_sync"
    add_foreign_key :provider_credential_receipts, :ingestion_batches, column: :preceding_batch_id
    add_check_constraint :provider_credential_receipts,
      "kind = 'session' AND provider_sync_type = 'ProviderConnection' AND from_revision >= 0 AND to_revision = from_revision + 1 AND writer_epoch > 0 AND page_sequence >= 0 AND ordinal >= 0 AND ordinal < 64", name: "chk_pcr_transition"
    execute <<~SQL
      CREATE FUNCTION prevent_provider_credential_receipt_update() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          RAISE EXCEPTION 'Credential receipts are immutable' USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM provider_sync_generations g WHERE g.id = NEW.provider_sync_generation_id AND g.stream = 'activities') THEN
          RAISE EXCEPTION 'Credential receipts require an activity generation' USING ERRCODE = '23514';
        END IF;
        IF (NEW.page_sequence = 0 AND NEW.preceding_batch_id IS NOT NULL) OR
           (NEW.page_sequence > 0 AND NOT EXISTS (
             SELECT 1 FROM ingestion_batches b WHERE b.id = NEW.preceding_batch_id
               AND b.provider_sync_generation_id = NEW.provider_sync_generation_id
               AND b.provider_connection_id = NEW.provider_connection_id AND b.family_id = NEW.family_id
               AND b.sync_id = NEW.sync_id AND b.sequence = NEW.page_sequence - 1
               AND b.generation_role = 'page' AND b.stream = 'activity_groups'
           )) THEN
          RAISE EXCEPTION 'Credential receipt prefix has another owner or position' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER provider_credential_receipts_immutable
        BEFORE INSERT OR UPDATE ON provider_credential_receipts
        FOR EACH ROW EXECUTE FUNCTION prevent_provider_credential_receipt_update();
    SQL
  end

  def down
    if select_value("SELECT 1 FROM provider_credential_receipts LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Credential receipt retention must be resolved before rollback"
    end
    drop_table :provider_credential_receipts
    execute "DROP FUNCTION prevent_provider_credential_receipt_update()"
    remove_index :provider_sync_generations, name: "idx_psg_receipt_sync"
  end
end
