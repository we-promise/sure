class CreateProviderCredentialClaims < ActiveRecord::Migration[8.1]
  def up
    create_table :provider_credential_claims, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider_key, null: false
      t.string :operation, null: false
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.string :request_fingerprint, null: false
      t.string :state, null: false, default: "prepared"
      t.text :request, null: false
      t.text :expected, null: false
      # The serialized empty Hash is SQL NULL until a result is confirmed.
      t.text :response
      t.bigint :installed_revision
      # Historical enqueue identity survives cleanup of the original Sync.
      t.uuid :sync_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :provider_credential_claims, [ :provider_key, :request_fingerprint ], unique: true, name: "idx_pcc_request"
    add_index :provider_credential_claims, [ :target_type, :target_id ], name: "idx_pcc_target"
    add_check_constraint :provider_credential_claims,
      "provider_key = 'simplefin' AND target_type = 'SimplefinItem' AND operation IN ('connect', 'reconnect')",
      name: "chk_pcc_supported_target"
    add_check_constraint :provider_credential_claims, "request_fingerprint ~ '^[0-9a-f]{64}$'", name: "chk_pcc_fingerprint"
    add_check_constraint :provider_credential_claims,
      "state IN ('prepared', 'claiming', 'claimed', 'installed', 'uncertain') AND lock_version >= 0", name: "chk_pcc_state"
    add_check_constraint :provider_credential_claims, <<~SQL.squish, name: "chk_pcc_result"
      ((state IN ('claimed', 'installed') AND response IS NOT NULL) OR
       (state NOT IN ('claimed', 'installed') AND response IS NULL)) AND
      ((state = 'installed' AND installed_revision IS NOT NULL AND installed_revision >= 0) OR
       (state <> 'installed' AND installed_revision IS NULL AND sync_id IS NULL))
    SQL
    add_check_constraint :provider_credential_claims,
      "octet_length(request) <= 65536 AND octet_length(expected) <= 65536 AND (response IS NULL OR octet_length(response) <= 65536)",
      name: "chk_pcc_storage_bound"
    execute <<~SQL
      CREATE FUNCTION guard_provider_credential_claim() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          IF NEW.state <> 'prepared' THEN
            RAISE EXCEPTION 'Credential claims must begin prepared' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END IF;
        IF ROW(NEW.id, NEW.family_id, NEW.provider_key, NEW.operation, NEW.target_type, NEW.target_id,
               NEW.request_fingerprint, NEW.request, NEW.expected, NEW.created_at) IS DISTINCT FROM
           ROW(OLD.id, OLD.family_id, OLD.provider_key, OLD.operation, OLD.target_type, OLD.target_id,
               OLD.request_fingerprint, OLD.request, OLD.expected, OLD.created_at) THEN
          RAISE EXCEPTION 'Credential claim preparation is immutable' USING ERRCODE = '23514';
        END IF;
        IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
          (OLD.state = 'prepared' AND NEW.state = 'claiming') OR
          (OLD.state = 'claiming' AND NEW.state IN ('claimed', 'uncertain')) OR
          (OLD.state = 'claimed' AND NEW.state = 'installed')
        ) THEN
          RAISE EXCEPTION 'Credential claim cannot replay its exchange' USING ERRCODE = '23514';
        END IF;
        IF NEW.response IS DISTINCT FROM OLD.response AND NOT (OLD.state = 'claiming' AND NEW.state = 'claimed') THEN
          RAISE EXCEPTION 'Confirmed credential result is immutable' USING ERRCODE = '23514';
        END IF;
        IF NEW.installed_revision IS DISTINCT FROM OLD.installed_revision AND NOT (OLD.state = 'claimed' AND NEW.state = 'installed') THEN
          RAISE EXCEPTION 'Credential installation revision is immutable' USING ERRCODE = '23514';
        END IF;
        IF NEW.sync_id IS DISTINCT FROM OLD.sync_id AND NOT
           (OLD.sync_id IS NULL AND OLD.state IN ('claimed', 'installed') AND NEW.state = 'installed') THEN
          RAISE EXCEPTION 'Credential installation Sync is immutable' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER provider_credential_claim_transition BEFORE INSERT OR UPDATE ON provider_credential_claims
        FOR EACH ROW EXECUTE FUNCTION guard_provider_credential_claim();
    SQL
  end

  def down
    if select_value("SELECT 1 FROM provider_credential_claims LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Credential claim dispositions must be resolved before rollback"
    end
    drop_table :provider_credential_claims
    execute "DROP FUNCTION guard_provider_credential_claim()"
  end
end
