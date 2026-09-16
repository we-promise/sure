class RetainIngestionAccountIdentities < ActiveRecord::Migration[8.1]
  def up
    create_table :account_ingestion_identities, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :live_account_id
      t.datetime :retired_at
      t.timestamps
    end
    add_index :account_ingestion_identities, [ :id, :family_id ], unique: true, name: "idx_ingestion_account_identity_tenant"
    add_index :account_ingestion_identities, :live_account_id, unique: true, name: "idx_ingestion_account_identity_live"
    add_foreign_key :account_ingestion_identities, :accounts,
      column: [ :live_account_id, :family_id ], primary_key: [ :id, :family_id ],
      name: "fk_ingestion_account_identity_live", on_delete: :restrict
    add_check_constraint :account_ingestion_identities, <<~SQL.squish, name: "chk_ingestion_account_identity_state"
      (live_account_id IS NOT NULL AND live_account_id = id AND retired_at IS NULL) OR
      (live_account_id IS NULL AND retired_at IS NOT NULL)
    SQL

    # Serialize old bound observations through the backfill and FK replacement.
    # The original Account FK still proves every copied identity's live owner.
    execute "LOCK TABLE source_records IN SHARE ROW EXCLUSIVE MODE"
    execute <<~SQL
      INSERT INTO account_ingestion_identities (id, family_id, live_account_id, created_at, updated_at)
      SELECT DISTINCT accounts.id, accounts.family_id, accounts.id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM source_records JOIN accounts
        ON accounts.id = source_records.account_id AND accounts.family_id = source_records.family_id
      WHERE source_records.account_id IS NOT NULL
    SQL
    remove_foreign_key :source_records, :accounts, column: [ :account_id, :family_id ]
    add_foreign_key :source_records, :account_ingestion_identities,
      column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_source_records_ingestion_identity"
    # Admission and retirement look up evidence by its financial owner. The
    # earlier identity indexes start with a source/row UUID and cannot serve it.
    add_index :source_records, [ :account_id, :family_id ], where: "account_id IS NOT NULL", name: "idx_source_records_account_family"
    add_index :entry_sources, [ :account_id, :family_id ], name: "idx_entry_sources_account_family"
    add_index :holding_sources, [ :account_id, :family_id ], name: "idx_holding_sources_account_family"

    execute <<~SQL
      CREATE FUNCTION guard_account_ingestion_identity() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          IF OLD.retired_at IS NOT NULL AND EXISTS (SELECT 1 FROM families WHERE id = OLD.family_id) THEN
            RAISE EXCEPTION 'Retired ingestion account identity must be retained' USING ERRCODE = '23514';
          END IF;
          RETURN OLD;
        END IF;
        IF TG_OP = 'INSERT' THEN
          IF NEW.live_account_id IS DISTINCT FROM NEW.id OR NEW.retired_at IS NOT NULL THEN
            RAISE EXCEPTION 'An ingestion identity must begin with its live account' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END IF;
        IF ROW(NEW.id, NEW.family_id, NEW.created_at) IS DISTINCT FROM ROW(OLD.id, OLD.family_id, OLD.created_at) THEN
          RAISE EXCEPTION 'Ingestion account identity is immutable' USING ERRCODE = '23514';
        END IF;
        IF OLD.retired_at IS NOT NULL AND
           (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at') THEN
          RAISE EXCEPTION 'Retired ingestion account identity is immutable' USING ERRCODE = '23514';
        END IF;
        IF OLD.retired_at IS NULL AND NEW.retired_at IS NOT NULL THEN
          IF EXISTS (SELECT 1 FROM entry_sources WHERE account_id = OLD.id AND
              (family_id <> OLD.family_id OR active OR entry_id IS NOT NULL)) OR
             EXISTS (SELECT 1 FROM holding_sources WHERE account_id = OLD.id AND
              (family_id <> OLD.family_id OR active OR holding_id IS NOT NULL)) THEN
            RAISE EXCEPTION 'Retirement requires detached inactive financial evidence' USING ERRCODE = '23514';
          END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER account_ingestion_identity_guard BEFORE INSERT OR UPDATE OR DELETE ON account_ingestion_identities
        FOR EACH ROW EXECUTE FUNCTION guard_account_ingestion_identity();

      CREATE FUNCTION guard_source_record_ingestion_identity() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        identity_row account_ingestion_identities%ROWTYPE;
      BEGIN
        IF TG_OP = 'UPDATE' AND OLD.account_id IS NOT NULL AND NEW.account_id IS DISTINCT FROM OLD.account_id THEN
          RAISE EXCEPTION 'Published source account identity is immutable' USING ERRCODE = '23514';
        END IF;
        IF NEW.account_id IS NULL THEN
          RETURN NEW;
        END IF;
        SELECT * INTO identity_row FROM account_ingestion_identities
          WHERE id = NEW.account_id AND family_id = NEW.family_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Source record has no retained account identity' USING ERRCODE = '23503';
        END IF;
        IF identity_row.retired_at IS NOT NULL THEN
          IF TG_OP = 'INSERT' THEN
            RAISE EXCEPTION 'Retired account cannot receive source observations' USING ERRCODE = '23514';
          END IF;
          IF (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at') THEN
            RAISE EXCEPTION 'Retired account observations are immutable' USING ERRCODE = '23514';
          END IF;
        ELSIF EXISTS (SELECT 1 FROM accounts WHERE id = identity_row.id AND family_id = identity_row.family_id
            AND status = 'pending_deletion') THEN
          -- The identity SHARE lock serializes with deletion scheduling. Do not
          -- acquire the Account row in the reverse order from the scheduler.
          RAISE EXCEPTION 'Account pending deletion cannot receive source observations' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER source_record_ingestion_identity_guard BEFORE INSERT OR UPDATE ON source_records
        FOR EACH ROW EXECUTE FUNCTION guard_source_record_ingestion_identity();

      CREATE FUNCTION guard_financial_source_ingestion_identity() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        identity_row account_ingestion_identities%ROWTYPE;
        retained_key text;
        live_key text;
      BEGIN
        IF TG_TABLE_NAME = 'entry_sources' THEN
          retained_key := 'entry_identity';
          live_key := 'entry_id';
        ELSE
          retained_key := 'holding_identity';
          live_key := 'holding_id';
        END IF;
        IF TG_OP = 'UPDATE' AND
           (ROW(NEW.id, NEW.source_record_id, NEW.account_id, NEW.family_id) IS DISTINCT FROM
             ROW(OLD.id, OLD.source_record_id, OLD.account_id, OLD.family_id) OR
            to_jsonb(NEW) -> retained_key IS DISTINCT FROM to_jsonb(OLD) -> retained_key) THEN
          RAISE EXCEPTION 'Financial source identity is immutable' USING ERRCODE = '23514';
        END IF;
        SELECT * INTO identity_row FROM account_ingestion_identities
          WHERE id = NEW.account_id AND family_id = NEW.family_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Financial source has no retained account identity' USING ERRCODE = '23503';
        END IF;
        IF to_jsonb(NEW) -> live_key <> 'null'::jsonb AND
           to_jsonb(NEW) -> live_key IS DISTINCT FROM to_jsonb(NEW) -> retained_key THEN
          RAISE EXCEPTION 'Financial source pointer differs from its retained identity' USING ERRCODE = '23514';
        END IF;
        IF identity_row.retired_at IS NOT NULL THEN
          IF TG_OP = 'INSERT' THEN
            RAISE EXCEPTION 'Retired account cannot receive financial source mappings' USING ERRCODE = '23514';
          END IF;
          IF NEW.active OR to_jsonb(NEW) -> live_key <> 'null'::jsonb OR
             (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at') THEN
            RAISE EXCEPTION 'Retired account financial evidence is immutable' USING ERRCODE = '23514';
          END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER entry_source_ingestion_identity_guard BEFORE INSERT OR UPDATE ON entry_sources
        FOR EACH ROW EXECUTE FUNCTION guard_financial_source_ingestion_identity();
      CREATE TRIGGER holding_source_ingestion_identity_guard BEFORE INSERT OR UPDATE ON holding_sources
        FOR EACH ROW EXECUTE FUNCTION guard_financial_source_ingestion_identity();

      CREATE FUNCTION prevent_ingestion_account_resurrection() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'UPDATE' AND NEW.id IS NOT DISTINCT FROM OLD.id THEN
          RETURN NEW;
        END IF;
        IF EXISTS (SELECT 1 FROM account_ingestion_identities WHERE id = NEW.id) THEN
          RAISE EXCEPTION 'Account UUID has a retained ingestion identity' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER account_ingestion_identity_no_resurrection BEFORE INSERT OR UPDATE OF id ON accounts
        FOR EACH ROW EXECUTE FUNCTION prevent_ingestion_account_resurrection();

      CREATE FUNCTION require_ingestion_account_retirement() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        -- Check final persisted state, not an earlier event in this transaction.
        IF EXISTS (SELECT 1 FROM account_ingestion_identities identity_row JOIN accounts ON accounts.id = identity_row.id
            WHERE identity_row.id = NEW.id AND identity_row.retired_at IS NOT NULL) THEN
          RAISE EXCEPTION 'Ingestion identity retirement must delete its live account atomically' USING ERRCODE = '23514';
        END IF;
        RETURN NULL;
      END $$;
      CREATE CONSTRAINT TRIGGER account_ingestion_identity_retirement
        AFTER UPDATE ON account_ingestion_identities DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION require_ingestion_account_retirement();
    SQL
  end

  def down
    execute "LOCK TABLE account_ingestion_identities, source_records, accounts IN ACCESS EXCLUSIVE MODE"
    if select_value(<<~SQL.squish)
      SELECT 1 FROM account_ingestion_identities identity_row
        LEFT JOIN accounts ON accounts.id = identity_row.live_account_id AND accounts.family_id = identity_row.family_id
      WHERE identity_row.retired_at IS NOT NULL OR accounts.id IS NULL LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration, "Retired ingestion account identities require an explicit retention disposition"
    end
    remove_foreign_key :source_records, name: "fk_source_records_ingestion_identity"
    add_foreign_key :source_records, :accounts, column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ]
    remove_index :holding_sources, name: "idx_holding_sources_account_family"
    remove_index :entry_sources, name: "idx_entry_sources_account_family"
    remove_index :source_records, name: "idx_source_records_account_family"
    execute "DROP TRIGGER account_ingestion_identity_retirement ON account_ingestion_identities"
    execute "DROP TRIGGER account_ingestion_identity_no_resurrection ON accounts"
    execute "DROP TRIGGER holding_source_ingestion_identity_guard ON holding_sources"
    execute "DROP TRIGGER entry_source_ingestion_identity_guard ON entry_sources"
    execute "DROP TRIGGER source_record_ingestion_identity_guard ON source_records"
    execute "DROP TRIGGER account_ingestion_identity_guard ON account_ingestion_identities"
    execute "DROP FUNCTION require_ingestion_account_retirement()"
    execute "DROP FUNCTION prevent_ingestion_account_resurrection()"
    execute "DROP FUNCTION guard_financial_source_ingestion_identity()"
    execute "DROP FUNCTION guard_source_record_ingestion_identity()"
    execute "DROP FUNCTION guard_account_ingestion_identity()"
    drop_table :account_ingestion_identities
  end
end
