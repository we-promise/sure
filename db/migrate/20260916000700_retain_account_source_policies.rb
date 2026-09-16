class RetainAccountSourcePolicies < ActiveRecord::Migration[8.1]
  def up
    execute "LOCK TABLE account_source_policies, account_providers, accounts IN SHARE ROW EXCLUSIVE MODE"
    add_column :account_source_policies, :source_binding, :jsonb, null: false, default: {}
    add_check_constraint :account_source_policies,
      "jsonb_typeof(source_binding) = 'object' AND octet_length(source_binding::text) <= 16384",
      name: "chk_source_policy_binding_object_size"

    # The old composite link FK proves these owners. Never manufacture a
    # historical source binding from a link's present state during this backfill.
    execute <<~SQL
      INSERT INTO account_ingestion_identities (id, family_id, live_account_id, created_at, updated_at)
      SELECT DISTINCT accounts.id, accounts.family_id, accounts.id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM account_source_policies policies
      JOIN account_providers links ON links.id = policies.account_provider_id
        AND links.account_id = policies.account_id AND links.family_id = policies.family_id
      JOIN accounts ON accounts.id = links.account_id AND accounts.family_id = links.family_id
      ON CONFLICT (id) DO NOTHING
    SQL
    add_foreign_key :account_source_policies, :account_ingestion_identities,
      column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_source_policy_account_identity"

    add_column :account_source_policies, :required_account_provider_id, :virtual, type: :uuid,
      as: "CASE WHEN active OR source_binding = '{}'::jsonb THEN account_provider_id ELSE NULL END", stored: true
    add_column :account_source_policies, :source_external_account_id, :virtual, type: :uuid,
      as: "(source_binding->>'external_account_id')::uuid", stored: true
    add_column :account_source_policies, :source_provider_connection_id, :virtual, type: :uuid,
      as: "(source_binding->>'provider_connection_id')::uuid", stored: true
    add_column :account_source_policies, :source_provider_key, :virtual, type: :string,
      as: "source_binding->>'provider_key'", stored: true
    remove_foreign_key :account_source_policies, :account_providers,
      column: [ :account_provider_id, :account_id, :family_id ]
    add_foreign_key :account_source_policies, :account_providers,
      column: [ :required_account_provider_id, :account_id, :family_id ], primary_key: [ :id, :account_id, :family_id ],
      name: "fk_source_policy_required_link"
    add_foreign_key :account_source_policies, :external_accounts,
      column: [ :source_external_account_id, :family_id, :source_provider_key ], primary_key: [ :id, :family_id, :provider_key ],
      name: "fk_source_policy_external_origin"
    add_foreign_key :account_source_policies, :provider_connections,
      column: [ :source_provider_connection_id, :family_id, :source_provider_key ], primary_key: [ :id, :family_id, :provider_key ],
      name: "fk_source_policy_connection_origin"
    # Retained-link guards query the original UUID even when the conditional
    # live-link FK is NULL. The resource/revision indexes start with account_id.
    add_index :account_source_policies, :account_provider_id, name: "idx_source_policies_account_provider"

    execute <<~SQL
      CREATE FUNCTION guard_account_source_policy_retention() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        binding jsonb;
        identity_key text;
        uuid_pattern text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
        identity_row account_ingestion_identities%ROWTYPE;
        link_row account_providers%ROWTYPE;
        external_row record;
        legacy_descriptor record;
        legacy_parent uuid;
        legacy_family uuid;
        account_status text;
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF ROW(NEW.id, NEW.account_id, NEW.family_id, NEW.account_provider_id, NEW.resource,
              NEW.revision, NEW.created_at, NEW.source_binding) IS DISTINCT FROM
             ROW(OLD.id, OLD.account_id, OLD.family_id, OLD.account_provider_id, OLD.resource,
              OLD.revision, OLD.created_at, OLD.source_binding) THEN
            RAISE EXCEPTION 'Account source policy capture is immutable' USING ERRCODE = '23514';
          END IF;
          IF NOT OLD.active AND NEW.active THEN
            RAISE EXCEPTION 'Retained account source policy cannot be reactivated' USING ERRCODE = '23514';
          END IF;
          -- Existing unknown bindings stay unknown. Deactivation does not
          -- authorize replacing their live link or inventing original proof.
          RETURN NEW;
        END IF;

        -- Short publication locks only. NOWAIT avoids reversing a concurrent
        -- lifecycle's locks when SQL callers bypass the ordinary Account lock.
        SELECT status INTO account_status FROM accounts
          WHERE id = NEW.account_id AND family_id = NEW.family_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account source policy has no live financial owner' USING ERRCODE = '23503';
        END IF;
        IF account_status = 'pending_deletion' THEN
          RAISE EXCEPTION 'Account pending deletion cannot select a source' USING ERRCODE = '23514';
        END IF;
        SELECT * INTO identity_row FROM account_ingestion_identities
          WHERE id = NEW.account_id AND family_id = NEW.family_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account source policy has no retained account identity' USING ERRCODE = '23503';
        END IF;
        IF identity_row.retired_at IS NOT NULL OR identity_row.live_account_id IS DISTINCT FROM NEW.account_id THEN
          RAISE EXCEPTION 'Retired account cannot select a source' USING ERRCODE = '23514';
        END IF;
        SELECT * INTO link_row FROM account_providers WHERE id = NEW.account_provider_id
          AND account_id = NEW.account_id AND family_id = NEW.family_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Account source policy has no matching live link' USING ERRCODE = '23503';
        END IF;
        binding := NEW.source_binding;
        -- Compatibility SQL writers may leave an unknown capture. It stays
        -- immutable and keeps its live-link FK even after deactivation; normal
        -- Rails selections always capture a new complete binding.
        IF binding = '{}'::jsonb THEN RETURN NEW; END IF;
        IF jsonb_typeof(binding) IS DISTINCT FROM 'object' OR
           NOT (binding ?& ARRAY['format', 'capture_kind', 'account_id', 'family_id', 'account_provider_id', 'provider_key',
             'external_account_id', 'provider_connection_id', 'legacy_account_type', 'legacy_account_id', 'legacy_item_type', 'legacy_item_id']) OR
           (binding - ARRAY['format', 'capture_kind', 'account_id', 'family_id', 'account_provider_id', 'provider_key',
             'external_account_id', 'provider_connection_id', 'legacy_account_type', 'legacy_account_id', 'legacy_item_type', 'legacy_item_id']) <> '{}'::jsonb OR
           binding -> 'format' IS DISTINCT FROM '"account-source-policy/v1"'::jsonb OR
           binding -> 'capture_kind' IS DISTINCT FROM '"selection"'::jsonb OR
           binding -> 'account_id' IS DISTINCT FROM to_jsonb(NEW.account_id::text) OR
           binding -> 'family_id' IS DISTINCT FROM to_jsonb(NEW.family_id::text) OR
           binding -> 'account_provider_id' IS DISTINCT FROM to_jsonb(NEW.account_provider_id::text) OR
           jsonb_typeof(binding -> 'provider_key') IS DISTINCT FROM 'string' OR
           length(btrim(binding ->> 'provider_key')) = 0 THEN
          RAISE EXCEPTION 'Account source policy binding is invalid' USING ERRCODE = '23514';
        END IF;
        FOREACH identity_key IN ARRAY ARRAY['account_id', 'family_id', 'account_provider_id'] LOOP
          IF jsonb_typeof(binding -> identity_key) IS DISTINCT FROM 'string' OR
             NOT COALESCE((binding ->> identity_key) ~ uuid_pattern, false) THEN
            RAISE EXCEPTION 'Account source policy identity is invalid' USING ERRCODE = '23514';
          END IF;
        END LOOP;
        IF (binding -> 'external_account_id' = 'null'::jsonb) IS DISTINCT FROM
           (binding -> 'provider_connection_id' = 'null'::jsonb) THEN
          RAISE EXCEPTION 'Account source policy shared origin is incomplete' USING ERRCODE = '23514';
        END IF;
        FOREACH identity_key IN ARRAY ARRAY['external_account_id', 'provider_connection_id', 'legacy_account_id', 'legacy_item_id'] LOOP
          IF binding -> identity_key <> 'null'::jsonb AND
             (jsonb_typeof(binding -> identity_key) IS DISTINCT FROM 'string' OR
              NOT COALESCE((binding ->> identity_key) ~ uuid_pattern, false)) THEN
            RAISE EXCEPTION 'Account source policy origin identity is invalid' USING ERRCODE = '23514';
          END IF;
        END LOOP;
        IF binding -> 'legacy_account_id' = 'null'::jsonb THEN
          IF binding -> 'legacy_account_type' <> 'null'::jsonb OR binding -> 'legacy_item_type' <> 'null'::jsonb OR
             binding -> 'legacy_item_id' <> 'null'::jsonb THEN
            RAISE EXCEPTION 'Account source policy legacy origin is incomplete' USING ERRCODE = '23514';
          END IF;
        ELSE
          IF binding -> 'legacy_item_id' = 'null'::jsonb OR
             jsonb_typeof(binding -> 'legacy_account_type') IS DISTINCT FROM 'string' OR
             length(btrim(binding ->> 'legacy_account_type')) = 0 OR
             jsonb_typeof(binding -> 'legacy_item_type') IS DISTINCT FROM 'string' OR
             length(btrim(binding ->> 'legacy_item_type')) = 0 THEN
            RAISE EXCEPTION 'Account source policy legacy origin is incomplete' USING ERRCODE = '23514';
          END IF;
        END IF;
        IF binding -> 'external_account_id' = 'null'::jsonb AND binding -> 'legacy_account_id' = 'null'::jsonb THEN
          RAISE EXCEPTION 'Account source policy requires an original source' USING ERRCODE = '23514';
        END IF;

        IF binding -> 'legacy_account_id' IS DISTINCT FROM COALESCE(to_jsonb(link_row.provider_id::text), 'null'::jsonb) OR
           binding -> 'legacy_account_type' IS DISTINCT FROM COALESCE(to_jsonb(link_row.provider_type), 'null'::jsonb) OR
           binding -> 'external_account_id' IS DISTINCT FROM COALESCE(to_jsonb(link_row.external_account_id::text), 'null'::jsonb) OR
           (link_row.provider_key IS NOT NULL AND binding ->> 'provider_key' IS DISTINCT FROM link_row.provider_key) THEN
          RAISE EXCEPTION 'Account source policy binding differs from its live link' USING ERRCODE = '23514';
        END IF;
        IF link_row.provider_id IS NOT NULL THEN
          -- Frozen at this migration's version. Neither application autoloading
          -- nor caller-supplied class/table names participate in SQL admission.
          SELECT * INTO legacy_descriptor FROM (VALUES
            ('AkahuAccount', 'akahu_accounts', 'akahu_item_id', 'AkahuItem', 'akahu_items', 'akahu'),
            ('BinanceAccount', 'binance_accounts', 'binance_item_id', 'BinanceItem', 'binance_items', 'binance'),
            ('BrexAccount', 'brex_accounts', 'brex_item_id', 'BrexItem', 'brex_items', 'brex'),
            ('CoinbaseAccount', 'coinbase_accounts', 'coinbase_item_id', 'CoinbaseItem', 'coinbase_items', 'coinbase'),
            ('CoinstatsAccount', 'coinstats_accounts', 'coinstats_item_id', 'CoinstatsItem', 'coinstats_items', 'coinstats'),
            ('EnableBankingAccount', 'enable_banking_accounts', 'enable_banking_item_id', 'EnableBankingItem', 'enable_banking_items', 'enable_banking'),
            ('IbkrAccount', 'ibkr_accounts', 'ibkr_item_id', 'IbkrItem', 'ibkr_items', 'ibkr'),
            ('IndexaCapitalAccount', 'indexa_capital_accounts', 'indexa_capital_item_id', 'IndexaCapitalItem', 'indexa_capital_items', 'indexa_capital'),
            ('KrakenAccount', 'kraken_accounts', 'kraken_item_id', 'KrakenItem', 'kraken_items', 'kraken'),
            ('LunchflowAccount', 'lunchflow_accounts', 'lunchflow_item_id', 'LunchflowItem', 'lunchflow_items', 'lunchflow'),
            ('MercuryAccount', 'mercury_accounts', 'mercury_item_id', 'MercuryItem', 'mercury_items', 'mercury'),
            ('MonobankAccount', 'monobank_accounts', 'monobank_item_id', 'MonobankItem', 'monobank_items', 'monobank'),
            ('OnchainWalletAccount', 'onchain_wallet_accounts', 'onchain_wallet_item_id', 'OnchainWalletItem', 'onchain_wallet_items', 'onchain_wallet'),
            ('PlaidAccount', 'plaid_accounts', 'plaid_item_id', 'PlaidItem', 'plaid_items', 'plaid'),
            ('QuestradeAccount', 'questrade_accounts', 'questrade_item_id', 'QuestradeItem', 'questrade_items', 'questrade'),
            ('RedbarkAccount', 'redbark_accounts', 'redbark_item_id', 'RedbarkItem', 'redbark_items', 'redbark'),
            ('SimplefinAccount', 'simplefin_accounts', 'simplefin_item_id', 'SimplefinItem', 'simplefin_items', 'simplefin'),
            ('SnaptradeAccount', 'snaptrade_accounts', 'snaptrade_item_id', 'SnaptradeItem', 'snaptrade_items', 'snaptrade'),
            ('SophtronAccount', 'sophtron_accounts', 'sophtron_item_id', 'SophtronItem', 'sophtron_items', 'sophtron'),
            ('TradeRepublicAccount', 'trade_republic_accounts', 'trade_republic_item_id', 'TradeRepublicItem', 'trade_republic_items', 'trade_republic'),
            ('Trading212Account', 'trading212_accounts', 'trading212_item_id', 'Trading212Item', 'trading212_items', 'trading212'),
            ('UpAccount', 'up_accounts', 'up_item_id', 'UpItem', 'up_items', 'up'),
            ('WiseAccount', 'wise_accounts', 'wise_item_id', 'WiseItem', 'wise_items', 'wise')
          ) AS reviewed(account_type, account_table, item_column, item_type, item_table, provider_key)
          WHERE reviewed.account_type = link_row.provider_type;
          IF NOT FOUND OR binding ->> 'legacy_item_type' IS DISTINCT FROM legacy_descriptor.item_type OR
             binding ->> 'provider_key' IS DISTINCT FROM legacy_descriptor.provider_key THEN
            RAISE EXCEPTION 'Account source policy has an unregistered legacy origin' USING ERRCODE = '23514';
          END IF;
          EXECUTE format('SELECT %I FROM %I WHERE id = $1 FOR SHARE NOWAIT',
            legacy_descriptor.item_column, legacy_descriptor.account_table) INTO legacy_parent USING link_row.provider_id;
          IF legacy_parent IS NULL THEN
            RAISE EXCEPTION 'Account source policy has no live legacy account' USING ERRCODE = '23503';
          END IF;
          IF binding ->> 'legacy_item_id' IS DISTINCT FROM legacy_parent::text THEN
            RAISE EXCEPTION 'Account source policy legacy parent differs from its source' USING ERRCODE = '23514';
          END IF;
          EXECUTE format('SELECT family_id FROM %I WHERE id = $1 FOR SHARE NOWAIT',
            legacy_descriptor.item_table) INTO legacy_family USING legacy_parent;
          IF legacy_family IS DISTINCT FROM NEW.family_id THEN
            RAISE EXCEPTION 'Account source policy legacy item has no matching family' USING ERRCODE = '23503';
          END IF;
        END IF;
        IF link_row.external_account_id IS NOT NULL THEN
          SELECT id, provider_connection_id INTO external_row FROM external_accounts WHERE id = link_row.external_account_id
            AND family_id = NEW.family_id AND provider_key = binding ->> 'provider_key' FOR SHARE NOWAIT;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Account source policy has no matching shared source' USING ERRCODE = '23503';
          END IF;
          IF binding ->> 'provider_connection_id' IS DISTINCT FROM external_row.provider_connection_id::text THEN
            RAISE EXCEPTION 'Account source policy connection differs from its source' USING ERRCODE = '23514';
          END IF;
          IF link_row.provider_id IS NOT NULL THEN
            PERFORM mapping.id FROM provider_migration_mappings mapping
              JOIN provider_migration_controls control ON control.id = mapping.provider_migration_control_id
              WHERE mapping.role = 'external_account' AND mapping.legacy_type = link_row.provider_type
                AND mapping.legacy_id = link_row.provider_id AND mapping.external_account_id = external_row.id
                AND mapping.family_id = NEW.family_id AND control.family_id = NEW.family_id
                AND control.provider_key = binding ->> 'provider_key'
                AND control.provider_connection_id = external_row.provider_connection_id
                AND control.legacy_type = legacy_descriptor.item_type AND control.legacy_id = legacy_parent
              FOR SHARE OF mapping, control NOWAIT;
            IF NOT FOUND THEN
              RAISE EXCEPTION 'Account source policy dual origin has no exact migration proof' USING ERRCODE = '23514';
            END IF;
          END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER account_source_policy_retention_guard BEFORE INSERT OR UPDATE ON account_source_policies
        FOR EACH ROW EXECUTE FUNCTION guard_account_source_policy_retention();

      CREATE FUNCTION guard_account_provider_retained_identity() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'INSERT' OR NEW.id IS DISTINCT FROM OLD.id THEN
          IF EXISTS (SELECT 1 FROM account_source_policies WHERE account_provider_id = NEW.id) THEN
            RAISE EXCEPTION 'Account provider UUID has retained source policies' USING ERRCODE = '23514';
          END IF;
        END IF;
        IF TG_OP = 'INSERT' THEN RETURN NEW; END IF;
        IF NOT EXISTS (SELECT 1 FROM account_source_policies WHERE account_provider_id = OLD.id) THEN RETURN NEW; END IF;
        IF ROW(NEW.id, NEW.account_id, NEW.family_id, NEW.provider_type, NEW.provider_id) IS DISTINCT FROM
           ROW(OLD.id, OLD.account_id, OLD.family_id, OLD.provider_type, OLD.provider_id) OR
           (OLD.external_account_id IS NOT NULL AND NEW.external_account_id IS DISTINCT FROM OLD.external_account_id) OR
           (OLD.provider_key IS NOT NULL AND NEW.provider_key IS DISTINCT FROM OLD.provider_key) THEN
          RAISE EXCEPTION 'Retained account provider source identity is immutable' USING ERRCODE = '23514';
        END IF;
        IF NEW.external_account_id IS DISTINCT FROM OLD.external_account_id OR NEW.provider_key IS DISTINCT FROM OLD.provider_key THEN
          IF OLD.external_account_id IS NOT NULL OR NEW.external_account_id IS NULL OR NEW.provider_key IS NULL OR
             OLD.provider_id IS NULL OR OLD.provider_type IS NULL OR EXISTS (
               SELECT 1 FROM account_source_policies policy WHERE policy.account_provider_id = OLD.id AND
                 (policy.source_binding = '{}'::jsonb OR
                  policy.source_binding ->> 'legacy_account_id' IS DISTINCT FROM OLD.provider_id::text OR
                  policy.source_binding ->> 'legacy_account_type' IS DISTINCT FROM OLD.provider_type OR
                  policy.source_binding ->> 'provider_key' IS DISTINCT FROM NEW.provider_key)
             ) THEN
            RAISE EXCEPTION 'Account provider enrichment requires retained legacy source proof' USING ERRCODE = '23514';
          END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER account_provider_retained_identity_guard BEFORE INSERT OR UPDATE ON account_providers
        FOR EACH ROW EXECUTE FUNCTION guard_account_provider_retained_identity();

      CREATE FUNCTION verify_account_provider_source_enrichment() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        link_row account_providers%ROWTYPE;
        external_row record;
        mapping_row record;
        control_row record;
        policy_row record;
      BEGIN
        IF OLD.external_account_id IS NOT NULL OR NEW.external_account_id IS NULL THEN RETURN NULL; END IF;
        IF NOT EXISTS (SELECT 1 FROM account_source_policies WHERE account_provider_id = NEW.id) THEN RETURN NULL; END IF;
        SELECT * INTO link_row FROM account_providers WHERE id = NEW.id FOR SHARE NOWAIT;
        IF NOT FOUND OR ROW(link_row.account_id, link_row.family_id, link_row.provider_type, link_row.provider_id,
            link_row.external_account_id, link_row.provider_key) IS DISTINCT FROM
           ROW(NEW.account_id, NEW.family_id, NEW.provider_type, NEW.provider_id, NEW.external_account_id, NEW.provider_key) THEN
          RAISE EXCEPTION 'Retained account provider enrichment changed before commit' USING ERRCODE = '23514';
        END IF;
        SELECT id, provider_connection_id INTO external_row FROM external_accounts WHERE id = link_row.external_account_id
          AND family_id = link_row.family_id AND provider_key = link_row.provider_key FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Retained account provider enrichment has no exact external account' USING ERRCODE = '23503';
        END IF;
        SELECT provider_migration_control_id INTO mapping_row FROM provider_migration_mappings WHERE role = 'external_account'
          AND legacy_type = link_row.provider_type AND legacy_id = link_row.provider_id
          AND external_account_id = external_row.id AND family_id = link_row.family_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Retained account provider enrichment has no exact migration mapping' USING ERRCODE = '23514';
        END IF;
        SELECT legacy_id, legacy_type INTO control_row FROM provider_migration_controls WHERE id = mapping_row.provider_migration_control_id
          AND family_id = link_row.family_id AND provider_key = link_row.provider_key
          AND provider_connection_id = external_row.provider_connection_id FOR SHARE NOWAIT;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Retained account provider enrichment has no exact migration owner' USING ERRCODE = '23514';
        END IF;
        FOR policy_row IN SELECT source_binding FROM account_source_policies WHERE account_provider_id = link_row.id LOOP
          IF policy_row.source_binding = '{}'::jsonb OR
             policy_row.source_binding ->> 'legacy_account_id' IS DISTINCT FROM link_row.provider_id::text OR
             policy_row.source_binding ->> 'legacy_account_type' IS DISTINCT FROM link_row.provider_type OR
             policy_row.source_binding ->> 'provider_key' IS DISTINCT FROM link_row.provider_key OR
             policy_row.source_binding ->> 'legacy_item_id' IS DISTINCT FROM control_row.legacy_id::text OR
             policy_row.source_binding ->> 'legacy_item_type' IS DISTINCT FROM control_row.legacy_type THEN
            RAISE EXCEPTION 'Retained account provider enrichment differs from captured legacy ownership' USING ERRCODE = '23514';
          END IF;
        END LOOP;
        -- Copier attaches the link before saving its mapping in this same
        -- transaction. Only the final exact mapping proves that enrichment;
        -- migration state alone is never a grant to change source identity.
        RETURN NULL;
      END $$;
      CREATE CONSTRAINT TRIGGER account_provider_retained_source_enrichment
        AFTER UPDATE ON account_providers DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION verify_account_provider_source_enrichment();
    SQL
  end

  def down
    execute "LOCK TABLE account_source_policies, account_providers, account_ingestion_identities IN ACCESS EXCLUSIVE MODE"
    if select_value(<<~SQL.squish)
      SELECT 1 FROM account_source_policies policies LEFT JOIN account_providers links
        ON links.id = policies.account_provider_id AND links.account_id = policies.account_id AND links.family_id = policies.family_id
      WHERE links.id IS NULL LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration, "Retained source policies require their original live links before rollback"
    end
    if select_value("SELECT 1 FROM account_ingestion_identities WHERE retired_at IS NOT NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Retired financial accounts require an explicit source-policy retention disposition"
    end
    execute "DROP TRIGGER account_provider_retained_source_enrichment ON account_providers"
    execute "DROP TRIGGER account_provider_retained_identity_guard ON account_providers"
    execute "DROP TRIGGER account_source_policy_retention_guard ON account_source_policies"
    execute "DROP FUNCTION verify_account_provider_source_enrichment()"
    execute "DROP FUNCTION guard_account_provider_retained_identity()"
    execute "DROP FUNCTION guard_account_source_policy_retention()"
    remove_foreign_key :account_source_policies, name: "fk_source_policy_connection_origin"
    remove_foreign_key :account_source_policies, name: "fk_source_policy_external_origin"
    remove_foreign_key :account_source_policies, name: "fk_source_policy_required_link"
    remove_foreign_key :account_source_policies, name: "fk_source_policy_account_identity"
    add_foreign_key :account_source_policies, :account_providers,
      column: [ :account_provider_id, :account_id, :family_id ], primary_key: [ :id, :account_id, :family_id ]
    remove_index :account_source_policies, name: "idx_source_policies_account_provider"
    remove_column :account_source_policies, :source_provider_key
    remove_column :account_source_policies, :source_provider_connection_id
    remove_column :account_source_policies, :source_external_account_id
    remove_column :account_source_policies, :required_account_provider_id
    remove_check_constraint :account_source_policies, name: "chk_source_policy_binding_object_size"
    remove_column :account_source_policies, :source_binding
  end
end
