class IndexProviderGenerationAccounts < ActiveRecord::Migration[8.1]
  def up
    # Historical identities deliberately have no live financial-account FK.
    add_column :provider_sync_generations, :account_ids, :uuid, array: true
    add_index :provider_sync_generations, :account_ids, using: :gin, name: "idx_psg_account_ids"
    add_index :provider_sync_generations, [ :family_id, :id ], where: "account_ids IS NULL", name: "idx_psg_unindexed_accounts"

    execute <<~SQL
      CREATE FUNCTION guard_provider_generation_capture() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        canonical_ids uuid[];
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF ROW(NEW.id, NEW.family_id, NEW.provider_connection_id, NEW.sync_id, NEW.provider_sync_type,
                 NEW.stream, NEW.scope_key, NEW.start_cursor, NEW.context_snapshot, NEW.writer_epoch, NEW.created_at)
             IS DISTINCT FROM
             ROW(OLD.id, OLD.family_id, OLD.provider_connection_id, OLD.sync_id, OLD.provider_sync_type,
                 OLD.stream, OLD.scope_key, OLD.start_cursor, OLD.context_snapshot, OLD.writer_epoch, OLD.created_at) THEN
            RAISE EXCEPTION 'Provider generation capture is immutable' USING ERRCODE = '23514';
          END IF;
          IF OLD.account_ids IS NOT NULL AND NEW.account_ids IS DISTINCT FROM OLD.account_ids THEN
            RAISE EXCEPTION 'Provider generation account projection is immutable' USING ERRCODE = '23514';
          END IF;
        END IF;
        IF NEW.account_ids IS NOT NULL THEN
          IF cardinality(NEW.account_ids) > 10000 OR COALESCE(array_ndims(NEW.account_ids), 0) > 1 OR
             (cardinality(NEW.account_ids) > 0 AND array_lower(NEW.account_ids, 1) <> 1) THEN
            RAISE EXCEPTION 'Provider generation account projection is invalid' USING ERRCODE = '23514';
          END IF;
          SELECT COALESCE(array_agg(value ORDER BY value), '{}'::uuid[]) INTO canonical_ids
            FROM (SELECT DISTINCT value FROM unnest(NEW.account_ids) AS value WHERE value IS NOT NULL) ids;
          IF NEW.account_ids IS DISTINCT FROM canonical_ids THEN
            RAISE EXCEPTION 'Provider generation account projection must be sorted and distinct' USING ERRCODE = '23514';
          END IF;
        END IF;
        -- SQL cannot decrypt the capture. The bounded application verifier must
        -- prove INSERT and NULL-to-indexed projections against the original map.
        RETURN NEW;
      END $$;
      CREATE TRIGGER provider_generation_capture_guard BEFORE INSERT OR UPDATE ON provider_sync_generations
        FOR EACH ROW EXECUTE FUNCTION guard_provider_generation_capture();
    SQL
  end

  def down
    execute "LOCK TABLE provider_sync_generations IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM provider_sync_generations WHERE account_ids IS NOT NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Indexed generation ownership needs an explicit disposition before rollback"
    end
    execute "DROP TRIGGER provider_generation_capture_guard ON provider_sync_generations; DROP FUNCTION guard_provider_generation_capture();"
    remove_index :provider_sync_generations, name: "idx_psg_unindexed_accounts"
    remove_index :provider_sync_generations, name: "idx_psg_account_ids"
    remove_column :provider_sync_generations, :account_ids
  end
end
