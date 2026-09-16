class RetainFinancialIdentityBootstrapEvidence < ActiveRecord::Migration[8.1]
  def up
    add_column :entry_sources, :bootstrap_batch_id, :uuid
    add_column :entry_sources, :bootstrap_external_account_id, :uuid
    add_column :entry_sources, :bootstrap_identity_role, :string
    add_column :entry_sources, :bootstrap_entryable_type, :string
    add_column :entry_sources, :bootstrap_identity_state, :jsonb
    add_index :entry_sources, :bootstrap_batch_id
    add_index :source_records, [ :id, :external_account_id, :account_id, :family_id ], unique: true,
      name: "idx_source_records_bootstrap_owner"
    add_foreign_key :entry_sources, :ingestion_batches,
      column: [ :bootstrap_batch_id, :bootstrap_external_account_id, :family_id ],
      primary_key: [ :id, :external_account_id, :family_id ], name: "fk_entry_sources_bootstrap_batch"
    add_foreign_key :entry_sources, :source_records,
      column: [ :source_record_id, :bootstrap_external_account_id, :account_id, :family_id ],
      primary_key: [ :id, :external_account_id, :account_id, :family_id ], name: "fk_entry_sources_bootstrap_source"
    add_check_constraint :entry_sources, <<~SQL.squish, name: "chk_entry_sources_bootstrap"
      num_nonnulls(bootstrap_batch_id, bootstrap_external_account_id, bootstrap_identity_role, bootstrap_entryable_type, bootstrap_identity_state) = 0 OR
      (num_nonnulls(bootstrap_batch_id, bootstrap_external_account_id, bootstrap_identity_role, bootstrap_entryable_type, bootstrap_identity_state) = 5 AND
        role = 'posting' AND bootstrap_identity_role IN ('current', 'retired_alias') AND bootstrap_entryable_type IN ('Transaction', 'Trade') AND
        jsonb_typeof(bootstrap_identity_state) = 'object')
    SQL
    execute <<~SQL
      CREATE FUNCTION guard_financial_identity_bootstrap() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_TABLE_NAME = 'ingestion_batches' THEN
          IF (OLD.origin_kind = 'migration' AND OLD.stream = 'legacy_financial_identities') OR
             (NEW.origin_kind = 'migration' AND NEW.stream = 'legacy_financial_identities') THEN
            IF (to_jsonb(NEW) - ARRAY['status', 'applied_at', 'updated_at', 'error_code']) IS DISTINCT FROM
               (to_jsonb(OLD) - ARRAY['status', 'applied_at', 'updated_at', 'error_code']) THEN
              RAISE EXCEPTION 'Financial identity bootstrap capture is immutable';
            END IF;
            IF OLD.status = 'applied' AND ROW(NEW.status, NEW.applied_at) IS DISTINCT FROM ROW(OLD.status, OLD.applied_at) THEN
              RAISE EXCEPTION 'Financial identity bootstrap publication is immutable';
            END IF;
          END IF;
        ELSE
          IF OLD.bootstrap_batch_id IS NULL AND NEW.bootstrap_batch_id IS NOT NULL THEN
            RAISE EXCEPTION 'Bootstrap provenance must be captured when evidence is created';
          END IF;
          IF OLD.bootstrap_batch_id IS NOT NULL THEN
            IF ROW(NEW.source_record_id, NEW.entry_identity, NEW.account_id, NEW.family_id, NEW.role, NEW.match_method,
                   NEW.bootstrap_batch_id, NEW.bootstrap_external_account_id, NEW.bootstrap_identity_role, NEW.bootstrap_entryable_type, NEW.bootstrap_identity_state) IS DISTINCT FROM
               ROW(OLD.source_record_id, OLD.entry_identity, OLD.account_id, OLD.family_id, OLD.role, OLD.match_method,
                   OLD.bootstrap_batch_id, OLD.bootstrap_external_account_id, OLD.bootstrap_identity_role, OLD.bootstrap_entryable_type, OLD.bootstrap_identity_state) THEN
              RAISE EXCEPTION 'Financial identity bootstrap mapping is immutable';
            END IF;
            IF NEW.entry_id IS DISTINCT FROM OLD.entry_id AND NOT (NEW.entry_id IS NULL AND NOT NEW.active) THEN
              RAISE EXCEPTION 'Financial identity bootstrap cannot select another entry';
            END IF;
          END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER ingestion_bootstrap_capture BEFORE UPDATE ON ingestion_batches
        FOR EACH ROW EXECUTE FUNCTION guard_financial_identity_bootstrap();
      CREATE TRIGGER entry_source_bootstrap_identity BEFORE UPDATE ON entry_sources
        FOR EACH ROW EXECUTE FUNCTION guard_financial_identity_bootstrap();
    SQL
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM entry_sources WHERE bootstrap_batch_id IS NOT NULL)")
      raise ActiveRecord::IrreversibleMigration, "Retained financial identity evidence needs an explicit disposition before schema rollback"
    end
    execute "DROP TRIGGER entry_source_bootstrap_identity ON entry_sources; DROP TRIGGER ingestion_bootstrap_capture ON ingestion_batches; DROP FUNCTION guard_financial_identity_bootstrap();"
    remove_check_constraint :entry_sources, name: "chk_entry_sources_bootstrap"
    remove_foreign_key :entry_sources, name: "fk_entry_sources_bootstrap_source"
    remove_foreign_key :entry_sources, name: "fk_entry_sources_bootstrap_batch"
    remove_index :source_records, name: "idx_source_records_bootstrap_owner"
    remove_column :entry_sources, :bootstrap_identity_role
    remove_column :entry_sources, :bootstrap_entryable_type
    remove_column :entry_sources, :bootstrap_identity_state
    remove_column :entry_sources, :bootstrap_external_account_id
    remove_column :entry_sources, :bootstrap_batch_id
  end
end
