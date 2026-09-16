class CreateProviderIngestionFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_connections, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :provider_key, null: false
      t.string :name, null: false
      t.string :external_id
      t.string :region
      t.string :environment
      t.string :status, null: false, default: "good"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.boolean :pending_account_setup, null: false, default: false
      t.date :sync_start_date
      t.text :credentials
      t.text :credential_state
      t.bigint :credential_revision, null: false, default: 0
      t.jsonb :settings, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.bigint :writer_epoch, null: false, default: 0
      t.string :lease_owner
      t.datetime :lease_expires_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :provider_connections, [ :id, :family_id ], unique: true, name: "idx_pc_tenant"
    add_index :provider_connections, [ :id, :family_id, :provider_key ], unique: true, name: "idx_pc_provider_tenant"
    add_index :provider_connections, [ :family_id, :provider_key ], name: "idx_pc_family_provider"
    add_check_constraint :provider_connections, "provider_key ~ '^[a-z][a-z0-9_]*$'", name: "chk_pc_provider_key"
    add_check_constraint :provider_connections, "status IN ('good', 'requires_update', 'disabled')", name: "chk_pc_status"
    add_check_constraint :provider_connections, "writer_epoch >= 0", name: "chk_pc_epoch"
    add_check_constraint :provider_connections, "credential_revision >= 0", name: "chk_pc_credential_revision"
    add_check_constraint :provider_connections, "(lease_owner IS NULL) = (lease_expires_at IS NULL)", name: "chk_pc_lease"
    json_object_checks(:provider_connections, :settings, :metadata)

    create_table :provider_authorizations, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :provider_connection, type: :uuid, null: false, foreign_key: true
      t.string :external_id
      t.string :status, null: false, default: "active"
      t.text :credentials
      t.jsonb :institution_metadata, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :expires_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :provider_authorizations, [ :id, :provider_connection_id, :family_id ], unique: true, name: "idx_pa_owner"
    add_index :provider_authorizations, [ :provider_connection_id, :external_id ], unique: true,
      where: "external_id IS NOT NULL", name: "idx_pa_external_identity"
    connection_tenant_fk(:provider_authorizations)
    add_check_constraint :provider_authorizations, "status IN ('active', 'requires_update', 'revoked')", name: "chk_pa_status"
    json_object_checks(:provider_authorizations, :institution_metadata, :metadata)

    create_table :external_accounts, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :provider_connection, type: :uuid, null: false, foreign_key: true
      t.string :provider_key, null: false
      t.string :identity_namespace, null: false, default: "connection"
      t.string :external_id
      t.string :name, null: false
      t.string :currency
      t.string :account_type
      t.string :account_subtype
      t.string :status, null: false, default: "active"
      t.decimal :current_balance, precision: 38, scale: 18
      t.decimal :available_balance, precision: 38, scale: 18
      t.decimal :cash_balance, precision: 38, scale: 18
      t.decimal :reserved_balance, precision: 38, scale: 18
      t.date :balance_date
      t.check_constraint "currency IS NOT NULL OR num_nonnulls(current_balance, available_balance, cash_balance, reserved_balance) = 0",
        name: "external_accounts_balance_currency"
      t.date :sync_start_date
      t.jsonb :metadata, null: false, default: {}
      t.text :sensitive_details
      t.timestamps
    end
    add_index :external_accounts, [ :id, :family_id, :provider_key ], unique: true, name: "idx_ea_provider_tenant"
    add_index :external_accounts, [ :id, :provider_connection_id, :family_id ], unique: true, name: "idx_ea_owner"
    add_index :external_accounts, [ :provider_connection_id, :identity_namespace, :external_id ], unique: true,
      where: "external_id IS NOT NULL", name: "idx_ea_external_identity"
    add_foreign_key :external_accounts, :provider_connections,
      column: [ :provider_connection_id, :family_id, :provider_key ], primary_key: [ :id, :family_id, :provider_key ], name: "fk_ea_provider_tenant"
    add_check_constraint :external_accounts, "status IN ('active', 'ignored', 'closed', 'identity_unresolved')", name: "chk_ea_status"
    add_check_constraint :external_accounts, "(external_id IS NOT NULL AND length(external_id) > 0) OR status = 'identity_unresolved'", name: "chk_ea_identity"
    add_check_constraint :external_accounts, "length(identity_namespace) > 0", name: "chk_ea_namespace"
    json_object_checks(:external_accounts, :metadata)

    create_table :provider_authorization_accounts, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :provider_connection, type: :uuid, null: false, foreign_key: true
      t.references :provider_authorization, type: :uuid, null: false, foreign_key: true
      t.references :external_account, type: :uuid, null: false, foreign_key: true
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :provider_authorization_accounts, [ :provider_authorization_id, :external_account_id ], unique: true, name: "idx_paa_membership"
    scoped_account_fk(:provider_authorization_accounts)
    scoped_authorization_fk(:provider_authorization_accounts)
    add_check_constraint :provider_authorization_accounts, "status IN ('active', 'revoked')", name: "chk_paa_status"

    create_table :ingestion_batches, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :origin_kind, null: false
      t.references :provider_connection, type: :uuid, foreign_key: true
      t.references :provider_authorization, type: :uuid, foreign_key: true
      t.references :external_account, type: :uuid, foreign_key: true
      t.references :sync, type: :uuid, foreign_key: true
      t.string :provider_sync_type, null: false, default: "ProviderConnection"
      t.references :import, type: :uuid, foreign_key: true
      t.references :account_statement, type: :uuid, foreign_key: true
      t.string :stream, null: false
      t.string :scope_key, null: false, default: "connection"
      t.integer :sequence, null: false, default: 0
      t.string :idempotency_key, null: false
      t.integer :schema_version, null: false, default: 1
      t.string :mode, null: false, default: "unknown"
      t.boolean :complete, null: false, default: false
      t.jsonb :coverage, null: false, default: {}
      t.text :payload
      t.text :ruleset_snapshot
      t.string :source_policy_version
      t.bigint :writer_epoch
      t.string :status, null: false, default: "captured"
      t.datetime :applied_at
      t.string :error_code
      t.timestamps
    end
    add_index :ingestion_batches, [ :family_id, :idempotency_key ], unique: true, name: "idx_ib_idempotency"
    add_index :ingestion_batches, [ :id, :family_id ], unique: true, name: "idx_ib_tenant"
    add_index :ingestion_batches, [ :id, :provider_connection_id, :family_id ], unique: true, name: "idx_ib_owner"
    add_index :ingestion_batches, [ :provider_connection_id, :stream, :scope_key, :created_at ], name: "idx_ib_stream"
    connection_tenant_fk(:ingestion_batches)
    scoped_account_fk(:ingestion_batches)
    scoped_authorization_fk(:ingestion_batches)
    add_foreign_key :ingestion_batches, :syncs,
      column: [ :sync_id, :provider_connection_id, :provider_sync_type ], primary_key: [ :id, :syncable_id, :syncable_type ], name: "fk_ib_sync_owner"
    add_foreign_key :ingestion_batches, :imports,
      column: [ :import_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_ib_import_tenant"
    add_foreign_key :ingestion_batches, :account_statements,
      column: [ :account_statement_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_ib_statement_tenant"
    add_check_constraint :ingestion_batches, <<~SQL.squish, name: "chk_ib_origin"
      (origin_kind = 'provider' AND provider_connection_id IS NOT NULL AND sync_id IS NOT NULL AND import_id IS NULL AND account_statement_id IS NULL AND writer_epoch IS NOT NULL)
      OR (origin_kind = 'migration' AND provider_connection_id IS NOT NULL AND sync_id IS NULL AND import_id IS NULL AND account_statement_id IS NULL)
      OR (origin_kind = 'file' AND import_id IS NOT NULL AND provider_connection_id IS NULL AND sync_id IS NULL AND provider_authorization_id IS NULL AND external_account_id IS NULL)
    SQL
    add_check_constraint :ingestion_batches, "provider_sync_type = 'ProviderConnection'", name: "chk_ib_sync_type"
    add_check_constraint :ingestion_batches, "status IN ('captured', 'applying', 'applied', 'failed', 'review_required', 'approved')", name: "chk_ib_status"
    add_check_constraint :ingestion_batches, "mode IN ('delta', 'snapshot', 'unknown') AND (NOT complete OR mode <> 'unknown')", name: "chk_ib_mode"
    add_check_constraint :ingestion_batches, "sequence >= 0 AND schema_version > 0 AND (writer_epoch IS NULL OR writer_epoch >= 0)", name: "chk_ib_versions"
    add_check_constraint :ingestion_batches, "length(stream) > 0 AND length(scope_key) > 0 AND length(idempotency_key) > 0", name: "chk_ib_keys"
    json_object_checks(:ingestion_batches, :coverage)

    create_table :provider_sync_checkpoints, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :provider_connection, type: :uuid, null: false, foreign_key: true
      t.references :provider_authorization, type: :uuid, foreign_key: true
      t.references :external_account, type: :uuid, foreign_key: true
      t.references :ingestion_batch, type: :uuid, foreign_key: true
      t.string :stream, null: false
      t.string :scope_key, null: false, default: "connection"
      t.text :cursor
      t.text :state
      t.datetime :covered_through
      t.integer :schema_version, null: false, default: 1
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :provider_sync_checkpoints, [ :provider_connection_id, :stream, :scope_key ], unique: true, name: "idx_psc_identity"
    connection_tenant_fk(:provider_sync_checkpoints)
    scoped_account_fk(:provider_sync_checkpoints)
    scoped_authorization_fk(:provider_sync_checkpoints)
    add_foreign_key :provider_sync_checkpoints, :ingestion_batches,
      column: [ :ingestion_batch_id, :provider_connection_id, :family_id ], primary_key: [ :id, :provider_connection_id, :family_id ], name: "fk_psc_batch_owner"
    add_check_constraint :provider_sync_checkpoints, "length(stream) > 0 AND length(scope_key) > 0 AND schema_version > 0", name: "chk_psc_keys"

    create_table :provider_migration_controls, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :provider_key, null: false
      t.string :legacy_type, null: false
      t.uuid :legacy_id, null: false
      t.references :provider_connection, type: :uuid, foreign_key: true
      t.string :state, null: false, default: "legacy"
      t.bigint :writer_epoch, null: false, default: 0
      t.string :lease_owner
      t.datetime :lease_expires_at
      t.integer :copy_version, null: false, default: 1
      t.text :high_water_mark
      t.jsonb :audit_results, null: false, default: {}
      t.string :error_code
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :provider_migration_controls, [ :legacy_type, :legacy_id ], unique: true, name: "idx_pmc_legacy"
    add_index :provider_migration_controls, :provider_connection_id, unique: true,
      where: "provider_connection_id IS NOT NULL", name: "idx_pmc_connection"
    add_index :provider_migration_controls, [ :id, :family_id ], unique: true, name: "idx_pmc_tenant"
    add_foreign_key :provider_migration_controls, :provider_connections,
      column: [ :provider_connection_id, :family_id, :provider_key ], primary_key: [ :id, :family_id, :provider_key ], name: "fk_pmc_provider_tenant"
    add_check_constraint :provider_migration_controls, "state IN ('legacy', 'copying', 'shadow', 'quiescing', 'active', 'rollback_pending', 'retired', 'failed')", name: "chk_pmc_state"
    add_check_constraint :provider_migration_controls, "writer_epoch >= 0 AND copy_version > 0", name: "chk_pmc_versions"
    add_check_constraint :provider_migration_controls, "(lease_owner IS NULL) = (lease_expires_at IS NULL)", name: "chk_pmc_lease"
    json_object_checks(:provider_migration_controls, :audit_results)

    create_table :provider_migration_mappings, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :provider_migration_control, type: :uuid, null: false, foreign_key: true
      t.string :legacy_type, null: false
      t.uuid :legacy_id, null: false
      t.string :role, null: false
      t.references :provider_connection, type: :uuid, foreign_key: true
      t.references :provider_authorization, type: :uuid, foreign_key: true
      t.references :external_account, type: :uuid, foreign_key: true
      t.string :source_version
      t.string :source_checksum
      t.datetime :copied_at
      t.datetime :verified_at
      t.timestamps
    end
    add_index :provider_migration_mappings, [ :legacy_type, :legacy_id, :role ], unique: true, name: "idx_pmm_legacy_role"
    %i[provider_connection_id provider_authorization_id external_account_id].each do |column|
      add_index :provider_migration_mappings, column, unique: true,
        where: "#{column} IS NOT NULL", name: "idx_pmm_target_#{column}"
    end
    add_foreign_key :provider_migration_mappings, :provider_migration_controls,
      column: [ :provider_migration_control_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_pmm_control_tenant"
    connection_tenant_fk(:provider_migration_mappings)
    # These mapping targets intentionally use only family ownership: the connection
    # FK is an exclusive target here, not the ownership column used on other rows.
    add_index :provider_authorizations, [ :id, :family_id ], unique: true, name: "idx_pa_tenant"
    add_index :external_accounts, [ :id, :family_id ], unique: true, name: "idx_ea_tenant"
    add_foreign_key :provider_migration_mappings, :provider_authorizations,
      column: [ :provider_authorization_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_pmm_authorization_tenant"
    add_foreign_key :provider_migration_mappings, :external_accounts,
      column: [ :external_account_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_pmm_account_tenant"
    add_check_constraint :provider_migration_mappings, <<~SQL.squish, name: "chk_pmm_target"
      (role = 'connection' AND provider_connection_id IS NOT NULL AND provider_authorization_id IS NULL AND external_account_id IS NULL)
      OR (role = 'authorization' AND provider_authorization_id IS NOT NULL AND provider_connection_id IS NULL AND external_account_id IS NULL)
      OR (role = 'external_account' AND external_account_id IS NOT NULL AND provider_connection_id IS NULL AND provider_authorization_id IS NULL)
    SQL
  end

  private
    def connection_tenant_fk(table)
      add_foreign_key table, :provider_connections,
        column: [ :provider_connection_id, :family_id ], primary_key: [ :id, :family_id ], name: "fk_#{table}_connection_tenant"
    end

    def scoped_account_fk(table)
      add_foreign_key table, :external_accounts,
        column: [ :external_account_id, :provider_connection_id, :family_id ],
        primary_key: [ :id, :provider_connection_id, :family_id ], name: "fk_#{table}_account_owner"
    end

    def scoped_authorization_fk(table)
      add_foreign_key table, :provider_authorizations,
        column: [ :provider_authorization_id, :provider_connection_id, :family_id ],
        primary_key: [ :id, :provider_connection_id, :family_id ], name: "fk_#{table}_authorization_owner"
    end

    def json_object_checks(table, *columns)
      columns.each do |column|
        add_check_constraint table, "jsonb_typeof(#{column}) = 'object'", name: "chk_#{table}_#{column}_object"
      end
    end
end
