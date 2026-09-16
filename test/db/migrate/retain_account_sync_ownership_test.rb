require "test_helper"
require Rails.root.join("db/migrate/20260915150000_create_account_sync_inputs")
require Rails.root.join("db/migrate/20260916000600_retain_ingestion_account_identities")
require Rails.root.join("db/migrate/20260916000800_retain_account_sync_ownership")

class RetainAccountSyncOwnershipTest < ActiveSupport::TestCase
  test "backfill retains original bytes and derives only independently proven account owners" do
    with_prior_schema do
      family_id = insert(:families)
      account_id = insert(:accounts, family_id: family_id, status: "active")
      parent_id = insert(:syncs, syncable_type: "Family", syncable_id: family_id)
      sync_id = insert(:syncs, syncable_type: "Account", syncable_id: account_id, parent_id: parent_id)
      provider_id = insert(:syncs, syncable_type: "ProviderConnection", syncable_id: SecureRandom.uuid)
      batch_id = insert(:ingestion_batches, family_id: family_id, sync_id: provider_id)
      input_id = insert(:account_sync_inputs, sync_id: sync_id, account_id: account_id, family_id: family_id,
        provider_sync_id: provider_id, source_batch_id: batch_id, resource: "historical_balances", kind: "ibkr_equity",
        payload: "opaque original encrypted input bytes", payload_digest: "original-input-digest")
      update(:syncs, sync_id, account_inputs_sealed_at: Time.utc(2026, 5, 1), account_inputs_digest: "original-input-digest", status: "syncing")
      preparation_id = insert(:account_sync_preparations, sync_id: sync_id,
        input_digest: "original-input-digest", payload: "opaque original encrypted preparation bytes")
      selection_id = insert(:account_sync_sources, account_id: account_id, family_id: family_id,
        account_sync_input_id: input_id, resource: "historical_balances")
      orphan_id = insert(:syncs, syncable_type: "Account", syncable_id: SecureRandom.uuid, parent_id: parent_id)
      retired_account_id = retired_owner(family_id)
      retired_sync_id = insert(:syncs, syncable_type: "Account", syncable_id: retired_account_id)
      before_sync = row(:syncs, sync_id)
      before_input = row(:account_sync_inputs, input_id)
      before_preparation = row(:account_sync_preparations, preparation_id)
      before_selection = row(:account_sync_sources, selection_id)

      migrate(:up)

      assert_equal before_sync, row(:syncs, sync_id).except("account_family_id")
      assert_equal family_id, row(:syncs, sync_id).fetch("account_family_id")
      assert_equal family_id, row(:syncs, retired_sync_id).fetch("account_family_id")
      assert_nil row(:syncs, orphan_id).fetch("account_family_id"), "a parent family does not prove the orphan's owner"
      assert_nil row(:syncs, parent_id).fetch("account_family_id")
      assert_equal before_input, row(:account_sync_inputs, input_id)
      assert_equal before_preparation, row(:account_sync_preparations, preparation_id)
      assert_equal before_selection, row(:account_sync_sources, selection_id)
      assert_equal account_id, row(:account_ingestion_identities, account_id).fetch("live_account_id")
      assert @database.foreign_key_exists?(:account_sync_inputs, :account_ingestion_identities, name: "fk_account_sync_input_identity")
    end
  end

  test "backfill captures existing preparation and materialization owners but not empty seals" do
    with_prior_schema do
      family_id = insert(:families)
      ids = %i[preparation materialized empty].index_with do |kind|
        account_id = insert(:accounts, family_id: family_id, status: "active")
        sync_id = insert(:syncs, syncable_type: "Account", syncable_id: account_id, status: "syncing",
          account_inputs_sealed_at: Time.utc(2026, 5, 1), account_inputs_digest: "empty-seal",
          account_materialized_at: (Time.utc(2026, 5, 2) if kind == :materialized))
        if kind == :preparation
          insert(:account_sync_preparations, sync_id: sync_id, input_digest: "empty-seal", payload: "original preparation bytes")
        end
        account_id
      end

      migrate(:up)

      assert row(:account_ingestion_identities, ids.fetch(:preparation))
      assert row(:account_ingestion_identities, ids.fetch(:materialized))
      assert_nil row(:account_ingestion_identities, ids.fetch(:empty))
    end
  end

  test "unknown preparation and materialization evidence survive parent and direct deletion without invented ownership" do
    %i[preparation materialized].each do |kind|
      with_prior_schema do
        family_id = insert(:families)
        parent_id = insert(:syncs, syncable_type: "Family", syncable_id: family_id)
        account_id = SecureRandom.uuid
        sync_id = insert(:syncs, syncable_type: "Account", syncable_id: account_id, parent_id: parent_id, status: "syncing",
          account_inputs_sealed_at: Time.utc(2026, 5, 1), account_inputs_digest: "unknown-original-seal",
          account_materialized_at: (Time.utc(2026, 5, 2) if kind == :materialized))
        if kind == :preparation
          preparation_id = insert(:account_sync_preparations, sync_id: sync_id, input_digest: "unknown-original-seal",
            payload: "unknown original encrypted preparation bytes")
          before_preparation = row(:account_sync_preparations, preparation_id)
        end
        telemetry_id = insert(:syncs, syncable_type: "Account", syncable_id: SecureRandom.uuid)
        before = row(:syncs, sync_id)

        migrate(:up)

        error = assert_raises(ActiveRecord::StatementInvalid) do
          @database.transaction(requires_new: true) { @database.execute("DELETE FROM syncs WHERE id = #{@database.quote(sync_id)}") }
        end
        assert_match(/Unknown account sync evidence requires an explicit disposition/, error.message)
        assert_raises(ActiveRecord::InvalidForeignKey) do
          @database.transaction(requires_new: true) { @database.execute("DELETE FROM syncs WHERE id = #{@database.quote(parent_id)}") }
        end
        assert_equal before, row(:syncs, sync_id).except("account_family_id")
        assert_nil row(:syncs, sync_id).fetch("account_family_id")
        assert_nil row(:account_ingestion_identities, account_id)
        assert_equal before_preparation, row(:account_sync_preparations, preparation_id) if kind == :preparation

        @database.execute("DELETE FROM syncs WHERE id = #{@database.quote(telemetry_id)}")
        assert_nil row(:syncs, telemetry_id), "unknown empty telemetry remains removable"
      end
    end
  end

  test "conflicting owner proofs abort the migration without adding a partial column or identity" do
    with_prior_schema do
      first_family = insert(:families)
      second_family = insert(:families)
      account_id = insert(:accounts, family_id: first_family, status: "active")
      insert(:account_ingestion_identities, id: account_id, family_id: first_family, live_account_id: account_id,
        created_at: Time.utc(2026, 5, 1), updated_at: Time.utc(2026, 5, 1))
      sync_id = insert(:syncs, syncable_type: "Account", syncable_id: account_id)
      # Build disagreeing headers during an unfinished deferred retirement.
      # All original guards remain installed; this temporary state cannot be
      # committed until the live Account is removed below.
      update(:account_ingestion_identities, account_id, live_account_id: nil, retired_at: Time.utc(2026, 5, 2))
      update(:accounts, account_id, family_id: second_family)
      before = row(:syncs, sync_id)

      assert_raises(ActiveRecord::MigrationError) { migrate(:up) }

      assert_not @database.column_exists?(:syncs, :account_family_id)
      assert_equal before, row(:syncs, sync_id)
      assert_equal first_family, row(:account_ingestion_identities, account_id).fetch("family_id")
      @database.execute("DELETE FROM accounts WHERE id = #{@database.quote(account_id)}")
      @database.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
    end
  end

  test "rollback restores live ownership constraints without changing retained bytes" do
    with_prior_schema do
      family_id = insert(:families)
      account_id = insert(:accounts, family_id: family_id, status: "active")
      sync_id = insert(:syncs, syncable_type: "Account", syncable_id: account_id)
      before = row(:syncs, sync_id)

      migrate(:up)
      migrate(:down)

      assert_not @database.column_exists?(:syncs, :account_family_id)
      assert_equal before, row(:syncs, sync_id)
      assert @database.foreign_key_exists?(:account_sync_inputs, :accounts, column: [ :account_id, :family_id ])
    end
  end

  test "rollback refuses unknown and retired ownership and leaves the guards installed" do
    %i[unknown retired].each do |kind|
      with_prior_schema do
        family_id = insert(:families)
        account_id = kind == :retired ? retired_owner(family_id) : SecureRandom.uuid
        sync_id = insert(:syncs, syncable_type: "Account", syncable_id: account_id)
        migrate(:up)
        before = row(:syncs, sync_id)

        assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }

        assert_equal before, row(:syncs, sync_id)
        assert @database.column_exists?(:syncs, :account_family_id)
        if kind == :retired
          assert_raises(ActiveRecord::StatementInvalid) do
            @database.transaction(requires_new: true) { @database.execute("DELETE FROM syncs WHERE id = #{@database.quote(sync_id)}") }
          end
        end
      end
    end
  end

  private
    def with_prior_schema
      @database = ApplicationRecord.connection
      original_path = @database.schema_search_path
      schema = "account_sync_migration_#{SecureRandom.hex(10)}"
      @database.transaction(requires_new: true) do
        @database.execute("CREATE SCHEMA #{@database.quote_table_name(schema)}")
        # Do not include public: CREATE OR REPLACE must never see a production
        # function. Every table and function in this fixture is isolated.
        @database.schema_search_path = schema
        create_base_tables
        [ CreateAccountSyncInputs, RetainIngestionAccountIdentities ].each do |migration|
          run_migration(migration, :up)
        end
        yield
        # Roll back the complete fixture, including deferred trigger events
        # and schema/function definitions, even when assertions raise.
        raise ActiveRecord::Rollback
      end
    ensure
      @database.schema_search_path = original_path if @database && original_path
    end

    def migrate(direction)
      run_migration(RetainAccountSyncOwnership, direction)
    end

    def run_migration(migration_class, direction)
      migration = migration_class.new
      migration.stubs(:connection).returns(@database)
      @database.transaction(requires_new: true) do
        ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
      end
    end

    def insert(table, **attributes)
      names = @database.columns(table).map(&:name)
      defaults = { id: SecureRandom.uuid }
      defaults[:created_at] = Time.utc(2026, 5, 1) if names.include?("created_at")
      defaults[:updated_at] = Time.utc(2026, 5, 1) if names.include?("updated_at")
      attributes = defaults.merge(attributes)
      columns = attributes.keys.map { |name| @database.quote_column_name(name) }.join(", ")
      values = attributes.values.map { |value| @database.quote(value) }.join(", ")
      @database.execute("INSERT INTO #{@database.quote_table_name(table)} (#{columns}) VALUES (#{values})")
      attributes.fetch(:id)
    end

    def update(table, id, **attributes)
      assignments = attributes.map { |name, value| "#{@database.quote_column_name(name)} = #{@database.quote(value)}" }.join(", ")
      @database.execute("UPDATE #{@database.quote_table_name(table)} SET #{assignments} WHERE id = #{@database.quote(id)}")
    end

    def row(table, id)
      @database.select_one("SELECT * FROM #{@database.quote_table_name(table)} WHERE id = #{@database.quote(id)}")
    end

    def retired_owner(family_id)
      account_id = insert(:accounts, family_id: family_id, status: "active")
      insert(:account_ingestion_identities, id: account_id, family_id: family_id, live_account_id: account_id,
        created_at: Time.utc(2026, 5, 1), updated_at: Time.utc(2026, 5, 1))
      update(:account_ingestion_identities, account_id, live_account_id: nil, retired_at: Time.utc(2026, 5, 2))
      @database.execute("DELETE FROM accounts WHERE id = #{@database.quote(account_id)}")
      @database.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
      account_id
    end

    # Only predecessor-schema tables required by the three actual migrations.
    # Their evidence/identity triggers are installed by the original migrations.
    def create_base_tables
      @database.execute <<~SQL
        CREATE TABLE families (id uuid PRIMARY KEY);
        CREATE TABLE accounts (id uuid PRIMARY KEY, family_id uuid NOT NULL REFERENCES families(id), status text,
          owner_id uuid, UNIQUE (id, family_id));
        CREATE TABLE syncs (id uuid PRIMARY KEY, syncable_id uuid NOT NULL, syncable_type text NOT NULL,
          status text NOT NULL DEFAULT 'pending', parent_id uuid REFERENCES syncs(id), predecessor_id uuid,
          window_start_date date, window_end_date date, created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE (id, syncable_id, syncable_type),
          CONSTRAINT chk_sync_predecessor_origin CHECK (predecessor_id IS NULL OR syncable_type = 'ProviderConnection'));
        CREATE TABLE ingestion_batches (id uuid PRIMARY KEY, family_id uuid NOT NULL REFERENCES families(id),
          sync_id uuid REFERENCES syncs(id), UNIQUE (id, family_id));
        CREATE TABLE source_records (id uuid PRIMARY KEY, account_id uuid, family_id uuid NOT NULL,
          FOREIGN KEY (account_id, family_id) REFERENCES accounts(id, family_id));
        CREATE TABLE entry_sources (id uuid PRIMARY KEY, source_record_id uuid, account_id uuid, family_id uuid,
          active boolean NOT NULL DEFAULT TRUE, entry_identity uuid, entry_id uuid);
        CREATE TABLE holding_sources (id uuid PRIMARY KEY, source_record_id uuid, account_id uuid, family_id uuid,
          active boolean NOT NULL DEFAULT TRUE, holding_identity uuid, holding_id uuid);
      SQL
    end
end
