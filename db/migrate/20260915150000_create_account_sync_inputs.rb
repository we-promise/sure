class CreateAccountSyncInputs < ActiveRecord::Migration[8.1]
  def up
    add_column :syncs, :account_inputs_sealed_at, :datetime
    add_column :syncs, :account_inputs_digest, :string
    add_column :syncs, :account_request_key, :string
    add_column :syncs, :account_materialized_at, :datetime
    remove_check_constraint :syncs, name: "chk_sync_predecessor_origin"
    add_check_constraint :syncs, "predecessor_id IS NULL OR (predecessor_id <> id AND syncable_type IN ('ProviderConnection', 'Account'))",
      name: "chk_sync_predecessor_origin"
    add_check_constraint :syncs, "account_inputs_sealed_at IS NULL OR (syncable_type = 'Account' AND account_inputs_digest IS NOT NULL)",
      name: "chk_sync_account_seal"
    add_check_constraint :syncs, "account_materialized_at IS NULL OR (syncable_type = 'Account' AND account_inputs_sealed_at IS NOT NULL)",
      name: "chk_sync_account_materialized"
    add_index :syncs, [ :syncable_id, :account_request_key ], unique: true,
      where: "syncable_type = 'Account' AND account_request_key IS NOT NULL", name: "idx_sync_account_request"

    create_table :account_sync_inputs, id: :uuid do |t|
      t.references :account, type: :uuid, null: false
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :sync, type: :uuid, null: false
      t.string :syncable_type, null: false, default: "Account"
      t.references :provider_sync, type: :uuid, null: false, foreign_key: { to_table: :syncs }
      t.references :source_batch, type: :uuid, null: false
      t.string :resource, null: false
      t.string :kind, null: false
      t.text :payload, null: false
      t.string :payload_digest, null: false
      t.timestamps
    end
    add_index :account_sync_inputs, [ :sync_id, :resource ], unique: true
    add_index :account_sync_inputs, [ :id, :account_id, :family_id, :resource ], unique: true, name: "idx_account_sync_input_owner"
    add_foreign_key :account_sync_inputs, :accounts, column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ]
    add_foreign_key :account_sync_inputs, :syncs, column: [ :sync_id, :account_id, :syncable_type ],
      primary_key: [ :id, :syncable_id, :syncable_type ], name: "fk_account_sync_input_sync", on_delete: :cascade
    add_foreign_key :account_sync_inputs, :ingestion_batches, column: [ :source_batch_id, :family_id ], primary_key: [ :id, :family_id ]
    add_check_constraint :account_sync_inputs, "syncable_type = 'Account' AND resource = 'historical_balances' AND kind = 'ibkr_equity'",
      name: "chk_account_sync_input_kind"

    create_table :account_sync_sources, id: :uuid do |t|
      t.references :account, type: :uuid, null: false
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :resource, null: false
      t.uuid :account_sync_input_id, null: false
      t.timestamps
    end
    add_index :account_sync_sources, [ :account_id, :resource ], unique: true
    add_foreign_key :account_sync_sources, :account_sync_inputs,
      column: [ :account_sync_input_id, :account_id, :family_id, :resource ],
      primary_key: [ :id, :account_id, :family_id, :resource ], name: "fk_account_sync_source_input"

    create_table :account_sync_preparations, id: :uuid do |t|
      t.references :sync, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :input_digest, null: false
      t.text :payload, null: false
      t.timestamps
    end

    # Model validations are insufficient for sealed evidence: callbacks and
    # bulk writes must not replace the inputs of a queued or running job.
    execute <<~SQL
      CREATE FUNCTION guard_account_sync_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          IF EXISTS (SELECT 1 FROM syncs WHERE id = OLD.sync_id) THEN
            RAISE EXCEPTION 'Account sync evidence is retained with its execution';
          END IF;
          RETURN OLD;
        END IF;
        IF TG_OP = 'UPDATE' THEN
          RAISE EXCEPTION 'Account sync evidence is immutable';
        END IF;
        IF TG_TABLE_NAME = 'account_sync_inputs' THEN
          PERFORM 1 FROM syncs WHERE id = NEW.sync_id AND account_inputs_sealed_at IS NULL FOR UPDATE;
          IF NOT FOUND THEN RAISE EXCEPTION 'Account sync inputs are sealed'; END IF;
        ELSE
          PERFORM 1 FROM syncs WHERE id = NEW.sync_id AND account_inputs_sealed_at IS NOT NULL
            AND account_inputs_digest = NEW.input_digest AND status = 'syncing' FOR UPDATE;
          IF NOT FOUND THEN RAISE EXCEPTION 'Account sync preparation has no admitted input'; END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER account_sync_inputs_immutable BEFORE INSERT OR UPDATE OR DELETE ON account_sync_inputs
        FOR EACH ROW EXECUTE FUNCTION guard_account_sync_evidence();
      CREATE TRIGGER account_sync_preparations_immutable BEFORE INSERT OR UPDATE OR DELETE ON account_sync_preparations
        FOR EACH ROW EXECUTE FUNCTION guard_account_sync_evidence();
      CREATE FUNCTION guard_account_sync_seal() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.account_inputs_sealed_at IS NOT NULL AND
          ROW(NEW.account_inputs_sealed_at, NEW.account_inputs_digest, NEW.account_request_key,
              NEW.syncable_id, NEW.syncable_type, NEW.window_start_date, NEW.window_end_date, NEW.parent_id, NEW.predecessor_id)
          IS DISTINCT FROM
          ROW(OLD.account_inputs_sealed_at, OLD.account_inputs_digest, OLD.account_request_key,
              OLD.syncable_id, OLD.syncable_type, OLD.window_start_date, OLD.window_end_date, OLD.parent_id, OLD.predecessor_id) THEN
          RAISE EXCEPTION 'Account sync execution inputs are sealed';
        END IF;
        IF OLD.account_materialized_at IS NOT NULL AND NEW.account_materialized_at IS DISTINCT FROM OLD.account_materialized_at THEN
          RAISE EXCEPTION 'Account materialization completion is immutable';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER sync_account_seal BEFORE UPDATE ON syncs FOR EACH ROW EXECUTE FUNCTION guard_account_sync_seal();
    SQL
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM syncs WHERE syncable_type = 'Account' AND predecessor_id IS NOT NULL)")
      raise ActiveRecord::IrreversibleMigration, "Account sync chains must be drained and their retained history explicitly dispositioned before rollback"
    end
    execute "DROP TRIGGER sync_account_seal ON syncs; DROP FUNCTION guard_account_sync_seal();"
    drop_table :account_sync_preparations
    drop_table :account_sync_sources
    drop_table :account_sync_inputs
    execute "DROP FUNCTION guard_account_sync_evidence();"
    remove_index :syncs, name: "idx_sync_account_request"
    remove_check_constraint :syncs, name: "chk_sync_account_seal"
    remove_check_constraint :syncs, name: "chk_sync_account_materialized"
    remove_check_constraint :syncs, name: "chk_sync_predecessor_origin"
    add_check_constraint :syncs, "predecessor_id IS NULL OR (predecessor_id <> id AND syncable_type = 'ProviderConnection')",
      name: "chk_sync_predecessor_origin"
    remove_column :syncs, :account_materialized_at
    remove_column :syncs, :account_request_key
    remove_column :syncs, :account_inputs_digest
    remove_column :syncs, :account_inputs_sealed_at
  end
end
