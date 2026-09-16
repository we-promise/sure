# Retain only relational ownership projections here. The application additionally
# authenticates the original encrypted archives and its exclusive legacy permit.
class RetainProviderSourceOwners < ActiveRecord::Migration[8.1]
  def up
    execute "LOCK TABLE provider_migration_mappings, provider_migration_controls, account_source_policies IN SHARE ROW EXCLUSIVE MODE"
    add_column :provider_migration_mappings, :retained_owner, :jsonb
    add_check_constraint :provider_migration_mappings,
      "retained_owner IS NULL OR (jsonb_typeof(retained_owner) = 'object' AND octet_length(retained_owner::text) <= 16384)",
      name: "chk_pmm_retained_owner_object_size"
    execute mapping_guard
    execute source_policy_guard(retained: true)
  end

  def down
    execute "LOCK TABLE provider_migration_mappings, account_source_policies IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM provider_migration_mappings WHERE retained_owner IS NOT NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Retained provider owners require an explicit archive-retention disposition"
    end
    execute source_policy_guard(retained: false)
    execute "DROP TRIGGER provider_migration_retained_owner_guard ON provider_migration_mappings"
    execute "DROP FUNCTION guard_provider_migration_retained_owner()"
    remove_check_constraint :provider_migration_mappings, name: "chk_pmm_retained_owner_object_size"
    remove_column :provider_migration_mappings, :retained_owner
  end

  private

    # Frozen migration descriptors. Never resolve caller-supplied Ruby classes or
    # table names while admitting a retained SQL origin.
    def legacy_sources
      <<~SQL
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
      SQL
    end

    def native_cutover_predicate(control, connection)
      <<~SQL.squish
        #{control}.state IN ('active', 'retired')
        AND #{control}.copy_version = 1
        AND #{control}.audit_results -> 'snapshot_checksums_verified' = 'true'::jsonb
        AND #{control}.audit_results -> 'copy_mode' = '"quiesced"'::jsonb
        AND #{control}.audit_results -> 'declared_writer_fence_held' = 'true'::jsonb
        AND #{control}.writer_epoch = 1 AND #{connection}.writer_epoch >= 1
        AND jsonb_typeof(#{control}.audit_results -> 'copy_run_id') = 'string'
        AND (#{control}.audit_results ->> 'copy_run_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND #{control}.audit_results -> 'native_cutover' -> 'format' = '"provider-native-cutover/v1"'::jsonb
        AND #{control}.audit_results -> 'native_cutover' -> 'connection_id' = to_jsonb(#{connection}.id::text)
        AND #{control}.audit_results -> 'native_cutover' -> 'writer_epoch' = '1'::jsonb
        AND #{control}.audit_results -> 'native_cutover' -> 'copy_run_id' = #{control}.audit_results -> 'copy_run_id'
        AND jsonb_typeof(#{control}.audit_results -> 'native_cutover' -> 'preparation_run_id') = 'string'
        AND (#{control}.audit_results -> 'native_cutover' ->> 'preparation_run_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      SQL
    end

    def owner_projection(mapping, control)
      <<~SQL.squish
        jsonb_build_object(
          'format', 'retained-provider-owner/v1', 'family_id', #{mapping}.family_id::text,
          'control_id', #{control}.id::text, 'provider_connection_id', #{control}.provider_connection_id::text,
          'mapping_id', #{mapping}.id::text, 'role', #{mapping}.role,
          'legacy_type', #{mapping}.legacy_type, 'legacy_id', #{mapping}.legacy_id::text,
          'legacy_item_type', #{control}.legacy_type, 'legacy_item_id', #{control}.legacy_id::text,
          'source_checksum', #{mapping}.source_checksum, 'copy_run_id', #{control}.audit_results ->> 'copy_run_id',
          'copy_version', #{control}.copy_version)
      SQL
    end

    def mapping_guard
      <<~SQL
        CREATE FUNCTION guard_provider_migration_retained_owner() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE
          control_row record;
          connection_row record;
          descriptor record;
          legacy_parent uuid;
          legacy_family uuid;
        BEGIN
          IF TG_OP = 'UPDATE' AND OLD.retained_owner IS NOT NULL THEN
            IF NEW.retained_owner IS DISTINCT FROM OLD.retained_owner OR
               ROW(NEW.id, NEW.family_id, NEW.provider_migration_control_id, NEW.legacy_type, NEW.legacy_id,
                 NEW.role, NEW.provider_connection_id, NEW.provider_authorization_id, NEW.external_account_id,
                 NEW.source_version, NEW.source_checksum, NEW.copied_at, NEW.verified_at, NEW.created_at) IS DISTINCT FROM
               ROW(OLD.id, OLD.family_id, OLD.provider_migration_control_id, OLD.legacy_type, OLD.legacy_id,
                 OLD.role, OLD.provider_connection_id, OLD.provider_authorization_id, OLD.external_account_id,
                 OLD.source_version, OLD.source_checksum, OLD.copied_at, OLD.verified_at, OLD.created_at) THEN
              RAISE EXCEPTION 'Retained provider owner and copy provenance are immutable' USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
          END IF;
          IF NEW.retained_owner IS NULL THEN RETURN NEW; END IF;
          IF jsonb_typeof(NEW.retained_owner) IS DISTINCT FROM 'object' OR
             octet_length(NEW.retained_owner::text) > 16384 OR
             NEW.role NOT IN ('connection', 'external_account') OR
             NEW.copied_at IS NULL OR NEW.verified_at IS NULL OR
             NOT COALESCE(NEW.source_checksum ~ '^v1-[0-9a-f]{64}$', false) THEN
            RAISE EXCEPTION 'Retained provider owner requires a verified bounded copy' USING ERRCODE = '23514';
          END IF;
          SELECT id, family_id, provider_key, provider_connection_id, legacy_type, legacy_id,
            state, writer_epoch, copy_version, audit_results INTO control_row FROM provider_migration_controls
            WHERE id = NEW.provider_migration_control_id AND family_id = NEW.family_id FOR SHARE NOWAIT;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Retained provider owner has no matching control' USING ERRCODE = '23503';
          END IF;
          SELECT id, family_id, provider_key, writer_epoch INTO connection_row FROM provider_connections
            WHERE id = control_row.provider_connection_id AND family_id = NEW.family_id
              AND provider_key = control_row.provider_key FOR SHARE NOWAIT;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Retained provider owner has no matching connection' USING ERRCODE = '23503';
          END IF;
          IF NOT COALESCE((#{native_cutover_predicate("control_row", "connection_row")}), false) OR
             NEW.retained_owner IS DISTINCT FROM #{owner_projection("NEW", "control_row")} THEN
            RAISE EXCEPTION 'Retained provider owner differs from its original native copy' USING ERRCODE = '23514';
          END IF;

          SELECT * INTO descriptor FROM (VALUES
            #{legacy_sources}
          ) AS reviewed(account_type, account_table, item_column, item_type, item_table, provider_key)
            WHERE reviewed.item_type = control_row.legacy_type AND reviewed.provider_key = control_row.provider_key;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Retained provider owner has an unregistered origin' USING ERRCODE = '23514';
          END IF;
          IF NEW.role = 'connection' THEN
            IF NEW.legacy_type IS DISTINCT FROM descriptor.item_type OR
               NEW.legacy_id IS DISTINCT FROM control_row.legacy_id OR
               NEW.provider_connection_id IS DISTINCT FROM connection_row.id OR
               NEW.provider_authorization_id IS NOT NULL OR NEW.external_account_id IS NOT NULL THEN
              RAISE EXCEPTION 'Retained provider connection mapping is inconsistent' USING ERRCODE = '23514';
            END IF;
          ELSE
            IF NEW.legacy_type IS DISTINCT FROM descriptor.account_type OR
               NEW.provider_connection_id IS NOT NULL OR NEW.provider_authorization_id IS NOT NULL THEN
              RAISE EXCEPTION 'Retained provider account mapping is inconsistent' USING ERRCODE = '23514';
            END IF;
            PERFORM id FROM external_accounts WHERE id = NEW.external_account_id
              AND provider_connection_id = connection_row.id AND family_id = NEW.family_id
              AND provider_key = control_row.provider_key FOR SHARE NOWAIT;
            IF NOT FOUND THEN
              RAISE EXCEPTION 'Retained provider account has no matching shared target' USING ERRCODE = '23503';
            END IF;
            EXECUTE format('SELECT %I FROM %I WHERE id = $1 FOR SHARE NOWAIT',
              descriptor.item_column, descriptor.account_table) INTO legacy_parent USING NEW.legacy_id;
            IF legacy_parent IS DISTINCT FROM control_row.legacy_id THEN
              RAISE EXCEPTION 'Retained provider account requires its original live parent' USING ERRCODE = '23514';
            END IF;
          END IF;
          EXECUTE format('SELECT family_id FROM %I WHERE id = $1 FOR SHARE NOWAIT',
            descriptor.item_table) INTO legacy_family USING control_row.legacy_id;
          IF legacy_family IS DISTINCT FROM NEW.family_id THEN
            RAISE EXCEPTION 'Retained provider owner requires its original live family' USING ERRCODE = '23503';
          END IF;
          RETURN NEW;
        END $$;
        CREATE TRIGGER provider_migration_retained_owner_guard BEFORE INSERT OR UPDATE ON provider_migration_mappings
          FOR EACH ROW EXECUTE FUNCTION guard_provider_migration_retained_owner();
      SQL
    end

    def live_legacy_check
      <<~SQL
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
      SQL
    end

    def retained_legacy_check
      <<~SQL
        EXECUTE format('SELECT %I FROM %I WHERE id = $1 FOR SHARE NOWAIT',
          legacy_descriptor.item_column, legacy_descriptor.account_table) INTO legacy_parent USING link_row.provider_id;
        GET DIAGNOSTICS legacy_row_count = ROW_COUNT;
        IF legacy_row_count = 0 THEN
          legacy_missing := true;
          legacy_parent := (binding ->> 'legacy_item_id')::uuid;
        ELSIF binding ->> 'legacy_item_id' IS DISTINCT FROM legacy_parent::text THEN
          RAISE EXCEPTION 'Account source policy legacy parent differs from its source' USING ERRCODE = '23514';
        END IF;
        EXECUTE format('SELECT family_id FROM %I WHERE id = $1 FOR SHARE NOWAIT',
          legacy_descriptor.item_table) INTO legacy_family USING legacy_parent;
        GET DIAGNOSTICS legacy_row_count = ROW_COUNT;
        IF legacy_row_count = 0 THEN
          legacy_missing := true;
        ELSIF legacy_family IS DISTINCT FROM NEW.family_id THEN
          RAISE EXCEPTION 'Account source policy legacy item has no matching family' USING ERRCODE = '23503';
        END IF;
      SQL
    end

    def retained_policy_check
      <<~SQL
        IF legacy_missing THEN
          IF link_row.external_account_id IS NULL THEN
            RAISE EXCEPTION 'Missing legacy policy origin requires its shared counterpart' USING ERRCODE = '23503';
          END IF;
          PERFORM account_mapping.id FROM provider_migration_mappings account_mapping
            JOIN provider_migration_controls control ON control.id = account_mapping.provider_migration_control_id
            JOIN provider_connections connection ON connection.id = control.provider_connection_id
            JOIN provider_migration_mappings item_mapping ON item_mapping.provider_migration_control_id = control.id
              AND item_mapping.role = 'connection' AND item_mapping.provider_connection_id = connection.id
            WHERE account_mapping.role = 'external_account'
              AND account_mapping.legacy_type = link_row.provider_type AND account_mapping.legacy_id = link_row.provider_id
              AND account_mapping.external_account_id = external_row.id AND account_mapping.family_id = NEW.family_id
              AND control.family_id = NEW.family_id AND control.provider_key = binding ->> 'provider_key'
              AND control.provider_connection_id = external_row.provider_connection_id
              AND control.legacy_type = legacy_descriptor.item_type AND control.legacy_id = legacy_parent
              AND connection.family_id = NEW.family_id AND connection.provider_key = control.provider_key
              AND control.state = 'retired' AND #{native_cutover_predicate("control", "connection")}
              AND item_mapping.family_id = NEW.family_id AND item_mapping.legacy_type = control.legacy_type
              AND item_mapping.legacy_id = control.legacy_id
              AND account_mapping.copied_at IS NOT NULL AND account_mapping.verified_at IS NOT NULL
              AND item_mapping.copied_at IS NOT NULL AND item_mapping.verified_at IS NOT NULL
              AND account_mapping.retained_owner = #{owner_projection("account_mapping", "control")}
              AND item_mapping.retained_owner = #{owner_projection("item_mapping", "control")}
            FOR SHARE OF account_mapping, control, connection, item_mapping NOWAIT;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Missing legacy policy origin has no exact retired copy proof' USING ERRCODE = '23514';
          END IF;
        END IF;
      SQL
    end

    # Keep the preexisting UPDATE, live identity/link, shape, native and dual
    # checks intact. Only absent legacy rows gain an additional retained route.
    def source_policy_guard(retained:)
      <<~SQL
        CREATE OR REPLACE FUNCTION guard_account_source_policy_retention() RETURNS trigger LANGUAGE plpgsql AS $$
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
          #{"legacy_missing boolean := false; legacy_row_count bigint;" if retained}
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
            #{retained ? retained_legacy_check : live_legacy_check}
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
          #{retained_policy_check if retained}
          RETURN NEW;
        END $$;
      SQL
    end
end
