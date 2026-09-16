class AddProviderCredentialClaimDisposition < ActiveRecord::Migration[8.1]
  def up
    add_column :provider_credential_claims, :cancelled_at, :datetime
    # Historical actor identity survives user removal; it is deliberately not a FK.
    add_column :provider_credential_claims, :cancelled_by_id, :uuid
    add_column :provider_credential_claims, :cancelled_from_state, :string
    add_column :provider_credential_claims, :cancellation_reason, :string

    remove_check_constraint :provider_credential_claims, name: "chk_pcc_state"
    add_check_constraint :provider_credential_claims,
      "state IN ('prepared', 'claiming', 'claimed', 'installed', 'uncertain', 'cancelled') AND lock_version >= 0",
      name: "chk_pcc_state"
    remove_check_constraint :provider_credential_claims, name: "chk_pcc_result"
    add_check_constraint :provider_credential_claims, <<~SQL.squish, name: "chk_pcc_result"
      ((state IN ('claimed', 'installed') AND response IS NOT NULL) OR
       (state IN ('prepared', 'claiming', 'uncertain') AND response IS NULL) OR
       (state = 'cancelled' AND
         ((cancelled_from_state = 'claimed' AND response IS NOT NULL) OR
          (cancelled_from_state IN ('prepared', 'claiming', 'uncertain') AND response IS NULL)))) AND
      ((state = 'installed' AND installed_revision IS NOT NULL AND installed_revision >= 0) OR
       (state <> 'installed' AND installed_revision IS NULL AND sync_id IS NULL))
    SQL
    add_check_constraint :provider_credential_claims, <<~SQL.squish, name: "chk_pcc_cancellation"
      (state = 'cancelled' AND cancelled_at IS NOT NULL AND isfinite(cancelled_at) AND
       cancelled_by_id IS NOT NULL AND cancelled_from_state IS NOT NULL AND
       cancelled_from_state IN ('prepared', 'claiming', 'claimed', 'uncertain') AND
       cancellation_reason IS NOT NULL AND cancellation_reason = 'user_cancelled') OR
      (state <> 'cancelled' AND cancelled_at IS NULL AND cancelled_by_id IS NULL AND
       cancelled_from_state IS NULL AND cancellation_reason IS NULL)
    SQL
    install_guard(cancellation: true)
  end

  def down
    # Do not race a new cancellation while deciding whether its audit can be removed.
    execute "LOCK TABLE provider_credential_claims IN ACCESS EXCLUSIVE MODE"
    if select_value("SELECT 1 FROM provider_credential_claims WHERE state = 'cancelled' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Retained credential cancellations prevent rollback"
    end

    install_guard(cancellation: false)
    remove_check_constraint :provider_credential_claims, name: "chk_pcc_cancellation"
    remove_check_constraint :provider_credential_claims, name: "chk_pcc_state"
    add_check_constraint :provider_credential_claims,
      "state IN ('prepared', 'claiming', 'claimed', 'installed', 'uncertain') AND lock_version >= 0", name: "chk_pcc_state"
    remove_check_constraint :provider_credential_claims, name: "chk_pcc_result"
    add_check_constraint :provider_credential_claims, <<~SQL.squish, name: "chk_pcc_result"
      ((state IN ('claimed', 'installed') AND response IS NOT NULL) OR
       (state NOT IN ('claimed', 'installed') AND response IS NULL)) AND
      ((state = 'installed' AND installed_revision IS NOT NULL AND installed_revision >= 0) OR
       (state <> 'installed' AND installed_revision IS NULL AND sync_id IS NULL))
    SQL
    remove_column :provider_credential_claims, :cancellation_reason
    remove_column :provider_credential_claims, :cancelled_from_state
    remove_column :provider_credential_claims, :cancelled_by_id
    remove_column :provider_credential_claims, :cancelled_at
  end

  private
    def install_guard(cancellation:)
      cancellation_transition = if cancellation
        "OR (OLD.state IN ('prepared', 'claiming', 'claimed', 'uncertain') AND NEW.state = 'cancelled')"
      end
      cancellation_guard = if cancellation
        <<~SQL
          IF NEW.state = 'cancelled' AND OLD.state <> 'cancelled' AND
             NEW.cancelled_from_state IS DISTINCT FROM OLD.state THEN
            RAISE EXCEPTION 'Credential cancellation must retain its previous state' USING ERRCODE = '23514';
          END IF;
          IF ROW(NEW.cancelled_at, NEW.cancelled_by_id, NEW.cancelled_from_state, NEW.cancellation_reason) IS DISTINCT FROM
             ROW(OLD.cancelled_at, OLD.cancelled_by_id, OLD.cancelled_from_state, OLD.cancellation_reason) AND NOT
             (OLD.state IN ('prepared', 'claiming', 'claimed', 'uncertain') AND NEW.state = 'cancelled') THEN
            RAISE EXCEPTION 'Credential cancellation audit is immutable' USING ERRCODE = '23514';
          END IF;
        SQL
      end
      execute <<~SQL
        CREATE OR REPLACE FUNCTION guard_provider_credential_claim() RETURNS trigger LANGUAGE plpgsql AS $$
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
            #{cancellation_transition}
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
          #{cancellation_guard}
          RETURN NEW;
        END $$;
      SQL
    end
end
