class PreserveHistoricalCommandBindings < ActiveRecord::Migration[8.1]
  def up
    # Source discovery follows captured account/policy identities even after a
    # live link disappears. Its OR branches deliberately have no family prefix,
    # so contradictory tenant references remain discoverable and can be refused.
    add_index :ingestion_batches, :source_policy_version,
      where: "source_policy_version IS NOT NULL", name: "idx_ib_source_policy"
    add_index :ingestion_batches, "(source_binding->>'account_id')",
      where: "source_binding->>'account_id' IS NOT NULL", name: "idx_ib_binding_account"
    add_index :ingestion_batches, "(source_binding->>'balance_policy_version')",
      where: "origin_kind = 'provider' AND stream IN ('historical_balances', 'opening_anchor_repairs') AND source_binding->>'balance_policy_version' IS NOT NULL",
      name: "idx_ib_binding_balance_policy"
    add_index :ingestion_batches, "(source_binding->>'anchor_policy_version')",
      where: "origin_kind = 'provider' AND stream IN ('historical_balances', 'opening_anchor_repairs') AND source_binding->>'anchor_policy_version' IS NOT NULL",
      name: "idx_ib_binding_anchor_policy"
    # Retained policy references are strings. Match the existing safe text join
    # instead of casting possibly malformed historical input to UUID.
    add_index :account_source_policies, "family_id, (id::text)", name: "idx_source_policies_family_text_id"

    execute <<~SQL
      CREATE FUNCTION guard_historical_command_capture() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        binding jsonb;
        identity_key text;
        uuid_pattern text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF (OLD.origin_kind = 'provider' AND OLD.stream IN ('historical_balances', 'opening_anchor_repairs')) OR
             (NEW.origin_kind = 'provider' AND NEW.stream IN ('historical_balances', 'opening_anchor_repairs')) THEN
            IF (to_jsonb(NEW) - ARRAY['status', 'applied_at', 'updated_at', 'error_code', 'source_binding']) IS DISTINCT FROM
               (to_jsonb(OLD) - ARRAY['status', 'applied_at', 'updated_at', 'error_code', 'source_binding']) THEN
              RAISE EXCEPTION 'Historical command capture is immutable' USING ERRCODE = '23514';
            END IF;
            IF OLD.source_binding <> '{}'::jsonb AND NEW.source_binding IS DISTINCT FROM OLD.source_binding THEN
              RAISE EXCEPTION 'Historical command binding is immutable' USING ERRCODE = '23514';
            END IF;
          ELSE
            RETURN NEW;
          END IF;
        ELSIF NOT (NEW.origin_kind = 'provider' AND NEW.stream IN ('historical_balances', 'opening_anchor_repairs')) THEN
          RETURN NEW;
        END IF;

        -- Unknown pre-index captures remain readable during rollout. The only
        -- permitted completion preserves every original header and cipher byte.
        binding := NEW.source_binding;
        IF binding = '{}'::jsonb THEN
          RETURN NEW;
        END IF;
        IF jsonb_typeof(binding) IS DISTINCT FROM 'object' OR
           NOT (binding ?& ARRAY['format', 'account_id', 'account_provider_id', 'external_account_id', 'resource',
             'source_policy_version', 'publication', 'balance_policy_version', 'anchor_policy_version', 'source_batch_id']) OR
           (binding - ARRAY['format', 'account_id', 'account_provider_id', 'external_account_id', 'resource',
             'source_policy_version', 'publication', 'balance_policy_version', 'anchor_policy_version', 'source_batch_id']) <> '{}'::jsonb OR
           binding -> 'format' IS DISTINCT FROM '"historical-command/v1"'::jsonb OR
           binding -> 'publication' IS DISTINCT FROM '"ledger"'::jsonb OR
           binding -> 'resource' IS DISTINCT FROM to_jsonb(NEW.stream) OR
           binding -> 'external_account_id' IS DISTINCT FROM to_jsonb(NEW.external_account_id::text) OR
           binding -> 'source_policy_version' IS DISTINCT FROM to_jsonb(NEW.source_policy_version) THEN
          RAISE EXCEPTION 'Historical command binding is invalid' USING ERRCODE = '23514';
        END IF;
        FOREACH identity_key IN ARRAY ARRAY['account_id', 'account_provider_id', 'external_account_id',
          'source_policy_version', 'source_batch_id'] LOOP
          IF jsonb_typeof(binding -> identity_key) IS DISTINCT FROM 'string' OR
             NOT COALESCE((binding ->> identity_key) ~ uuid_pattern, false) THEN
            RAISE EXCEPTION 'Historical command binding identity is invalid' USING ERRCODE = '23514';
          END IF;
        END LOOP;
        FOREACH identity_key IN ARRAY ARRAY['balance_policy_version', 'anchor_policy_version'] LOOP
          IF binding -> identity_key <> 'null'::jsonb AND
             (jsonb_typeof(binding -> identity_key) IS DISTINCT FROM 'string' OR
              NOT COALESCE((binding ->> identity_key) ~ uuid_pattern, false)) THEN
            RAISE EXCEPTION 'Historical command secondary policy is invalid' USING ERRCODE = '23514';
          END IF;
        END LOOP;
        IF binding -> 'anchor_policy_version' <> 'null'::jsonb AND
           (NEW.stream <> 'opening_anchor_repairs' OR
            binding -> 'anchor_policy_version' IS DISTINCT FROM binding -> 'balance_policy_version') THEN
          RAISE EXCEPTION 'Historical opening anchor policy is invalid' USING ERRCODE = '23514';
        END IF;
        -- SQL validates shape and immutability, not the encrypted original.
        -- SourceBinding.verify! must establish the exact command projection.
        RETURN NEW;
      END $$;
      CREATE TRIGGER ingestion_historical_command_guard BEFORE INSERT OR UPDATE ON ingestion_batches
        FOR EACH ROW EXECUTE FUNCTION guard_historical_command_capture();
    SQL
  end

  def down
    execute "LOCK TABLE ingestion_batches IN ACCESS EXCLUSIVE MODE"
    if select_value(<<~SQL.squish)
      SELECT 1 FROM ingestion_batches WHERE origin_kind = 'provider'
        AND stream IN ('historical_balances', 'opening_anchor_repairs') AND source_binding <> '{}'::jsonb LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration, "Retained historical bindings need an explicit disposition before rollback"
    end
    remove_index :account_source_policies, name: "idx_source_policies_family_text_id"
    remove_index :ingestion_batches, name: "idx_ib_binding_anchor_policy"
    remove_index :ingestion_batches, name: "idx_ib_binding_balance_policy"
    remove_index :ingestion_batches, name: "idx_ib_binding_account"
    remove_index :ingestion_batches, name: "idx_ib_source_policy"
    execute "DROP TRIGGER ingestion_historical_command_guard ON ingestion_batches"
    execute "DROP FUNCTION guard_historical_command_capture()"
  end
end
