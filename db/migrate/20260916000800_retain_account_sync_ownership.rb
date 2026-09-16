class RetainAccountSyncOwnership < ActiveRecord::Migration[8.1]
  def up
    execute "LOCK TABLE accounts, account_ingestion_identities, syncs, account_sync_inputs, account_sync_preparations, account_sync_sources IN SHARE ROW EXCLUSIVE MODE"
    add_column :syncs, :account_family_id, :uuid

    # The live owner, immutable inputs and retained identity are independent
    # proofs. Disagreement is an error; ancestry is not an ownership proof.
    if select_value(<<~SQL.squish)
      WITH owners AS (#{owner_proof_sql})
      SELECT 1 FROM owners GROUP BY sync_id HAVING COUNT(DISTINCT family_id) > 1 LIMIT 1
    SQL
      raise ActiveRecord::MigrationError, "Account sync ownership proofs disagree"
    end
    execute <<~SQL
      WITH owners AS (#{owner_proof_sql})
      UPDATE syncs SET account_family_id = owners.family_id
      FROM (SELECT DISTINCT sync_id, family_id FROM owners) owners
      WHERE syncs.id = owners.sync_id
    SQL
    # A proofless historical orphan remains NULL, rather than acquiring its
    # parent's current family or an invented account identity.
    add_check_constraint :syncs, "account_family_id IS NULL OR syncable_type = 'Account'", name: "chk_sync_account_family"
    # Family erasure is a distinct operation: this FK allows an eventual whole-
    # family erase, but existing evidence/source family FKs still require their
    # own coordinated disposition. This migration does not implement that flow.
    add_foreign_key :syncs, :families, column: :account_family_id, name: "fk_sync_account_family", on_delete: :cascade
    add_index :syncs, [ :account_family_id, :syncable_id ], where: "syncable_type = 'Account'", name: "idx_sync_account_family"
    add_index :syncs, [ :id, :syncable_id, :syncable_type, :account_family_id ], unique: true, name: "idx_sync_account_owner_family"

    # Existing inputs still have their original Account FK. Preparation or
    # materialization also constitutes evidence when its live owner is proven;
    # an empty seal alone does not create a retained identity.
    execute <<~SQL
      INSERT INTO account_ingestion_identities (id, family_id, live_account_id, created_at, updated_at)
      SELECT DISTINCT accounts.id, accounts.family_id, accounts.id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM accounts JOIN syncs ON syncs.syncable_id = accounts.id AND syncs.syncable_type = 'Account'
        AND syncs.account_family_id = accounts.family_id
      WHERE syncs.account_materialized_at IS NOT NULL OR
        EXISTS (SELECT 1 FROM account_sync_inputs WHERE sync_id = syncs.id) OR
        EXISTS (SELECT 1 FROM account_sync_preparations WHERE sync_id = syncs.id)
      ON CONFLICT (id) DO NOTHING
    SQL
    remove_foreign_key :account_sync_inputs, :accounts, column: [ :account_id, :family_id ]
    add_foreign_key :account_sync_inputs, :account_ingestion_identities,
      column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_account_sync_input_identity"
    remove_foreign_key :account_sync_inputs, name: "fk_account_sync_input_sync"
    add_foreign_key :account_sync_inputs, :syncs,
      column: [ :sync_id, :account_id, :syncable_type, :family_id ],
      primary_key: [ :id, :syncable_id, :syncable_type, :account_family_id ],
      name: "fk_account_sync_input_sync", on_delete: :cascade

    execute <<~SQL
      CREATE FUNCTION guard_account_sync_ownership() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        owner_family uuid;
        owner_status text;
        identity_row record;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          IF OLD.syncable_type = 'Account' THEN
            IF OLD.account_family_id IS NULL AND (OLD.account_materialized_at IS NOT NULL OR
                EXISTS (SELECT 1 FROM account_sync_inputs WHERE sync_id = OLD.id) OR
                EXISTS (SELECT 1 FROM account_sync_preparations WHERE sync_id = OLD.id)) THEN
              RAISE EXCEPTION 'Unknown account sync evidence requires an explicit disposition' USING ERRCODE = '23514';
            END IF;
            SELECT family_id, retired_at INTO identity_row FROM account_ingestion_identities
              WHERE id = OLD.syncable_id FOR SHARE NOWAIT;
            -- Check the original UUID even for a NULL/malformed historical
            -- family binding. Missing ownership cannot bypass retention.
            IF FOUND AND identity_row.retired_at IS NOT NULL AND EXISTS (SELECT 1 FROM families WHERE id = identity_row.family_id) THEN
              RAISE EXCEPTION 'Retired account sync history must be retained' USING ERRCODE = '23514';
            END IF;
          END IF;
          RETURN OLD;
        END IF;
        IF TG_OP = 'UPDATE' THEN
          IF OLD.syncable_type = 'Account' AND
              ROW(NEW.id, NEW.syncable_type, NEW.syncable_id, NEW.account_family_id) IS DISTINCT FROM
              ROW(OLD.id, OLD.syncable_type, OLD.syncable_id, OLD.account_family_id) THEN
            RAISE EXCEPTION 'Account sync ownership is immutable' USING ERRCODE = '23514';
          END IF;
          IF OLD.syncable_type <> 'Account' AND NEW.syncable_type = 'Account' THEN
            RAISE EXCEPTION 'An existing sync cannot acquire account ownership' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END IF;
        IF NEW.syncable_type <> 'Account' THEN
          RETURN NEW;
        END IF;
        SELECT family_id, status INTO owner_family, owner_status FROM accounts
          WHERE id = NEW.syncable_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account sync has no live owner' USING ERRCODE = '23503';
        END IF;
        IF owner_status IS NULL OR owner_status NOT IN ('active', 'draft', 'disabled') OR
            (NEW.account_family_id IS NOT NULL AND NEW.account_family_id <> owner_family) THEN
          RAISE EXCEPTION 'Account sync owner is unavailable or changed' USING ERRCODE = '23514';
        END IF;
        SELECT family_id, live_account_id, retired_at INTO identity_row FROM account_ingestion_identities
          WHERE id = NEW.syncable_id FOR SHARE NOWAIT;
        IF FOUND AND (identity_row.family_id <> owner_family OR identity_row.live_account_id IS DISTINCT FROM NEW.syncable_id OR
            identity_row.retired_at IS NOT NULL) THEN
          RAISE EXCEPTION 'Account sync retained identity is unavailable' USING ERRCODE = '23514';
        END IF;
        NEW.account_family_id := owner_family;
        RETURN NEW;
      END $$;
      CREATE TRIGGER sync_account_ownership BEFORE INSERT OR UPDATE OR DELETE ON syncs
        FOR EACH ROW EXECUTE FUNCTION guard_account_sync_ownership();

      CREATE OR REPLACE FUNCTION guard_account_sync_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        financial_account_uuid uuid;
        owner_family uuid;
        owner_status text;
        identity_row record;
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
          financial_account_uuid := NEW.account_id;
          owner_family := NEW.family_id;
          -- Queue already owns the provider parent. Direct SQL/model callers
          -- must not acquire its FK lock only after the financial Account.
          PERFORM 1 FROM syncs provider_run JOIN ingestion_batches source_batch ON source_batch.sync_id = provider_run.id
            WHERE provider_run.id = NEW.provider_sync_id AND source_batch.id = NEW.source_batch_id
              AND source_batch.family_id = owner_family
            FOR KEY SHARE OF provider_run, source_batch NOWAIT;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Account sync input has different provider evidence' USING ERRCODE = '23503';
          END IF;
        ELSE
          SELECT syncable_id, account_family_id INTO financial_account_uuid, owner_family FROM syncs
            WHERE id = NEW.sync_id AND syncable_type = 'Account';
          IF NOT FOUND OR owner_family IS NULL THEN
            RAISE EXCEPTION 'Account sync preparation has no original owner' USING ERRCODE = '23514';
          END IF;
        END IF;
        -- Runtime callers already hold provider/grant locks before this short
        -- Account -> identity -> Sync admission. SQL callers fail on contention.
        SELECT status INTO owner_status FROM accounts
          WHERE id = financial_account_uuid AND family_id = owner_family FOR UPDATE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account sync evidence has no live owner' USING ERRCODE = '23503';
        END IF;
        IF owner_status IS NULL OR owner_status NOT IN ('active', 'draft', 'disabled') THEN
          RAISE EXCEPTION 'Account sync evidence owner is unavailable' USING ERRCODE = '23514';
        END IF;
        SELECT live_account_id, retired_at INTO identity_row FROM account_ingestion_identities
          WHERE id = financial_account_uuid AND family_id = owner_family FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account sync evidence has no retained identity' USING ERRCODE = '23503';
        END IF;
        IF identity_row.live_account_id IS DISTINCT FROM financial_account_uuid OR identity_row.retired_at IS NOT NULL THEN
          RAISE EXCEPTION 'Retired account cannot receive sync evidence' USING ERRCODE = '23514';
        END IF;
        IF TG_TABLE_NAME = 'account_sync_inputs' THEN
          PERFORM 1 FROM syncs WHERE id = NEW.sync_id AND syncable_type = 'Account' AND syncable_id = financial_account_uuid
            AND account_family_id = owner_family AND account_inputs_sealed_at IS NULL AND status IN ('pending', 'syncing')
            FOR UPDATE NOWAIT;
          IF NOT FOUND THEN RAISE EXCEPTION 'Account sync inputs are sealed or unavailable'; END IF;
        ELSE
          PERFORM 1 FROM syncs WHERE id = NEW.sync_id AND syncable_type = 'Account' AND syncable_id = financial_account_uuid
            AND account_family_id = owner_family AND account_inputs_sealed_at IS NOT NULL
            AND account_inputs_digest = NEW.input_digest AND status = 'syncing' FOR UPDATE NOWAIT;
          IF NOT FOUND THEN RAISE EXCEPTION 'Account sync preparation has no admitted input'; END IF;
        END IF;
        RETURN NEW;
      END $$;

      CREATE FUNCTION guard_account_sync_source() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        owner_status text;
        identity_row record;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          SELECT family_id, retired_at INTO identity_row FROM account_ingestion_identities
            WHERE id = OLD.account_id FOR SHARE NOWAIT;
          IF FOUND AND identity_row.retired_at IS NOT NULL AND EXISTS (SELECT 1 FROM families WHERE id = identity_row.family_id) THEN
            RAISE EXCEPTION 'Retired account source selection must be retained' USING ERRCODE = '23514';
          END IF;
          RETURN OLD;
        END IF;
        IF TG_OP = 'UPDATE' AND
            ROW(NEW.id, NEW.account_id, NEW.family_id, NEW.resource, NEW.created_at) IS DISTINCT FROM
            ROW(OLD.id, OLD.account_id, OLD.family_id, OLD.resource, OLD.created_at) THEN
          RAISE EXCEPTION 'Account source selection ownership is immutable' USING ERRCODE = '23514';
        END IF;
        SELECT status INTO owner_status FROM accounts
          WHERE id = NEW.account_id AND family_id = NEW.family_id FOR UPDATE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account source selection has no live owner' USING ERRCODE = '23503';
        END IF;
        IF owner_status IS NULL OR owner_status NOT IN ('active', 'draft', 'disabled') THEN
          RAISE EXCEPTION 'Account source selection owner is unavailable' USING ERRCODE = '23514';
        END IF;
        SELECT live_account_id, retired_at INTO identity_row FROM account_ingestion_identities
          WHERE id = NEW.account_id AND family_id = NEW.family_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account source selection has no retained identity' USING ERRCODE = '23503';
        END IF;
        IF identity_row.live_account_id IS DISTINCT FROM NEW.account_id OR identity_row.retired_at IS NOT NULL THEN
          RAISE EXCEPTION 'Retired account source selection is immutable' USING ERRCODE = '23514';
        END IF;
        PERFORM 1 FROM account_sync_inputs WHERE id = NEW.account_sync_input_id AND account_id = NEW.account_id
          AND family_id = NEW.family_id AND resource = NEW.resource FOR KEY SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account source selection has different input ownership' USING ERRCODE = '23503';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER account_sync_source_owner BEFORE INSERT OR UPDATE OR DELETE ON account_sync_sources
        FOR EACH ROW EXECUTE FUNCTION guard_account_sync_source();
    SQL
  end

  def down
    execute "LOCK TABLE accounts, account_ingestion_identities, syncs, account_sync_inputs, account_sync_preparations, account_sync_sources IN ACCESS EXCLUSIVE MODE"
    if select_value(<<~SQL.squish)
      SELECT 1 FROM syncs
        LEFT JOIN accounts ON accounts.id = syncs.syncable_id AND accounts.family_id = syncs.account_family_id
        LEFT JOIN account_ingestion_identities identities ON identities.id = syncs.syncable_id
      WHERE syncs.syncable_type = 'Account' AND
        (syncs.account_family_id IS NULL OR accounts.id IS NULL OR identities.retired_at IS NOT NULL) LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration, "Retired or unknown account sync history requires an explicit retention disposition"
    end
    execute "DROP TRIGGER account_sync_source_owner ON account_sync_sources; DROP FUNCTION guard_account_sync_source();"
    execute "DROP TRIGGER sync_account_ownership ON syncs; DROP FUNCTION guard_account_sync_ownership();"
    restore_original_evidence_guard
    remove_foreign_key :account_sync_inputs, name: "fk_account_sync_input_sync"
    add_foreign_key :account_sync_inputs, :syncs, column: [ :sync_id, :account_id, :syncable_type ],
      primary_key: [ :id, :syncable_id, :syncable_type ], name: "fk_account_sync_input_sync", on_delete: :cascade
    remove_foreign_key :account_sync_inputs, name: "fk_account_sync_input_identity"
    add_foreign_key :account_sync_inputs, :accounts, column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ]
    remove_index :syncs, name: "idx_sync_account_owner_family"
    remove_index :syncs, name: "idx_sync_account_family"
    remove_foreign_key :syncs, name: "fk_sync_account_family"
    remove_check_constraint :syncs, name: "chk_sync_account_family"
    remove_column :syncs, :account_family_id
  end

  private
    def owner_proof_sql
      <<~SQL
        SELECT syncs.id AS sync_id, accounts.family_id FROM syncs JOIN accounts ON accounts.id = syncs.syncable_id
          WHERE syncs.syncable_type = 'Account'
        UNION ALL
        SELECT syncs.id AS sync_id, inputs.family_id FROM syncs JOIN account_sync_inputs inputs ON inputs.sync_id = syncs.id
          WHERE syncs.syncable_type = 'Account'
        UNION ALL
        SELECT syncs.id AS sync_id, identities.family_id FROM syncs
          JOIN account_ingestion_identities identities ON identities.id = syncs.syncable_id
          WHERE syncs.syncable_type = 'Account'
      SQL
    end

    def restore_original_evidence_guard
      execute <<~SQL
        CREATE OR REPLACE FUNCTION guard_account_sync_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            IF EXISTS (SELECT 1 FROM syncs WHERE id = OLD.sync_id) THEN
              RAISE EXCEPTION 'Account sync evidence is retained with its execution';
            END IF;
            RETURN OLD;
          END IF;
          IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'Account sync evidence is immutable'; END IF;
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
      SQL
    end
end
