require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Account::SyncRetentionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper

  Context = Data.define(:family, :account, :connection, :provider_sync, :sync, :input, :source, :preparation)

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "raw Account Sync insertion captures its family and rejects wrong or unavailable owners" do
    family = Family.create!(name: "Raw execution ownership")
    account = family.accounts.create!(name: "Raw execution owner", balance: 0, currency: "USD", accountable: Depository.new)
    attributes = { id: SecureRandom.uuid, syncable_type: "Account", syncable_id: account.id,
      created_at: Time.current, updated_at: Time.current }

    Sync.insert_all!([ attributes ])

    captured = Sync.find(attributes.fetch(:id))
    assert_equal family.id, captured.account_family_id
    assert_nil captured.account_inputs_sealed_at
    refute Account::IngestionIdentity.exists?(account.id)
    assert_database_failure do
      Sync.insert_all!([ attributes.merge(id: SecureRandom.uuid, account_family_id: families(:dylan_family).id) ])
    end
    [ nil, "unknown", "pending_deletion" ].each do |status|
      Account.where(id: account.id).update_all(status: status)
      assert_equal status, Account.where(id: account.id).pick(:status)
      assert_database_failure { Sync.insert_all!([ attributes.merge(id: SecureRandom.uuid) ]) }
      assert_equal [ captured.id ], Sync.where(syncable_type: "Account", syncable_id: account.id).pluck(:id)
    end
    assert_equal family.id, captured.reload.account_family_id
  end

  test "raw updates cannot rebind unsealed Account Sync ownership or adopt a non-Account execution" do
    family = Family.create!(name: "Immutable execution ownership")
    account = family.accounts.create!(name: "Original owner", balance: 0, currency: "USD", accountable: Depository.new)
    other_account = family.accounts.create!(name: "Other owner", balance: 0, currency: "USD", accountable: Depository.new)
    sync = account.syncs.create!
    before = sync.attributes
    assert_nil sync.account_inputs_sealed_at

    [ { account_family_id: families(:dylan_family).id }, { account_family_id: nil },
      { syncable_id: other_account.id },
      { syncable_type: "Family", syncable_id: family.id, account_family_id: nil } ].each do |changes|
      assert_database_failure { Sync.where(id: sync.id).update_all(changes) }
      assert_equal before, sync.reload.attributes
    end

    family_sync = family.syncs.create!
    original = family_sync.attributes
    assert_database_failure do
      Sync.where(id: family_sync.id).update_all(syncable_type: "Account", syncable_id: account.id, account_family_id: family.id)
    end
    assert_equal original, family_sync.reload.attributes
  end

  test "retirement retains exact encrypted input preparation selection and original execution headers" do
    with_calculation do |context|
      before = retained_rows(context)
      original_input = context.input.payload
      original_preparation = context.preparation.payload
      retire_fixture(context)

      assert_equal before, retained_rows(context)
      assert_nil context.input.reload.account
      assert context.input.account_identity.retired?
      assert context.input.valid?, context.input.errors.full_messages.to_sentence
      assert context.preparation.reload.valid?, context.preparation.errors.full_messages.to_sentence
      assert context.source.reload.valid?, context.source.errors.full_messages.to_sentence
      assert_nil context.source.account
      assert_equal original_input, context.input.handoff.payload
      assert_equal original_preparation, context.preparation.trade_flows.payload
      assert_equal context.family.id, context.sync.reload.account_family_id
      assert_equal [ context.input.id ], context.sync.verify_account_inputs!.map(&:id)
      assert_provider_column_encrypted(context.input, :payload, "statement_sha256")
      assert_provider_column_encrypted(context.preparation, :payload, "inputs_sha256")
    end
  end

  test "retired input resolution refuses the cached live receiver before resolving a handoff" do
    with_calculation do |context|
      assert_equal context.account.id, context.input.account.id
      retire_fixture(context)
      Provider::AccountData::Ibkr::EquityHandoff.any_instance.expects(:resolve).never

      assert_raises(Account::SyncAdmission::Unavailable) { context.input.resolve! }
    end
  end

  test "retired owning Sync and recursive ancestor deletion cannot discard any evidence" do
    with_calculation do |context|
      family_sync = context.family.syncs.create!
      context.provider_sync.update!(parent: family_sync)
      # A selected-input FK must not be the only protection for old executions.
      context.source.destroy!
      retire_fixture(context)
      before = retained_rows(context)
      ancestor_ids = [ family_sync.id, context.provider_sync.id, context.sync.id ]

      [ context.sync, context.provider_sync, family_sync ].each do |record|
        assert_database_failure { record.class.where(id: record.id).delete_all }
        assert_equal before, retained_rows(context)
        assert_equal ancestor_ids.sort, Sync.where(id: ancestor_ids).pluck(:id).sort
      end
      assert_database_failure { family_sync.destroy! }
      assert_equal before, retained_rows(context)
      assert_equal ancestor_ids.sort, Sync.where(id: ancestor_ids).pluck(:id).sort
    end
  end

  test "retired selected input cannot be replaced or deleted" do
    with_calculation do |context|
      next_sync = context.account.sync_later(window_start_date: Date.new(2026, 5, 2))
      next_input = next_sync.account_sync_inputs.sole
      retire_fixture(context)
      before = retained_rows(context)

      assert_raises(ActiveRecord::RecordInvalid) { context.source.update!(account_sync_input: next_input) }
      context.source.reload
      assert_raises(ActiveRecord::ReadOnlyRecord) { context.source.destroy! }
      assert_database_failure { Account::SyncSource.where(id: context.source.id).update_all(account_sync_input_id: next_input.id) }
      assert_database_failure { Account::SyncSource.where(id: context.source.id).delete_all }
      assert_equal before, retained_rows(context)
    end
  end

  test "retired accounts cannot receive a new selected pointer even for an existing captured input" do
    with_calculation do |context|
      attributes = context.source.attributes.except("id")
      context.source.destroy!
      retire_fixture(context)

      refute Account::SyncSource.new(attributes).valid?
      assert_database_failure { Account::SyncSource.insert_all!([ attributes.merge("id" => SecureRandom.uuid) ]) }
      assert_empty Account::SyncSource.where(account_id: context.account.id)
    end
  end

  test "old unsealed and sealed executions cannot accept new inputs or preparation after retirement" do
    with_calculation do |context|
      unsealed = context.account.syncs.create!
      sealed = context.account.syncs.create!
      sealed.update!(account_inputs_sealed_at: Time.current, account_inputs_digest: Account::SyncInput.digest([]))
      sealed.start!
      input_attributes = context.input.attributes.except("id").merge("sync_id" => unsealed.id)
      preparation_attributes = context.preparation.attributes.except("id").merge("sync_id" => sealed.id,
        "input_digest" => sealed.account_inputs_digest)
      retire_fixture(context)

      refute Account::SyncInput.new(input_attributes).valid?
      refute Account::SyncPreparation.new(preparation_attributes).valid?
      assert_database_failure { Account::SyncInput.insert_all!([ input_attributes.merge("id" => SecureRandom.uuid) ]) }
      assert_database_failure { Account::SyncPreparation.insert_all!([ preparation_attributes.merge("id" => SecureRandom.uuid) ]) }
      assert_empty unsealed.account_sync_inputs
      assert_nil sealed.reload.account_sync_preparation
    end
  end

  test "pending deletion rejects new evidence on a previously admitted execution" do
    with_calculation do |context|
      unsealed = context.account.syncs.create!
      attributes = context.input.attributes.except("id").merge("sync_id" => unsealed.id)
      Account.where(id: context.account.id).update_all(status: "pending_deletion")

      refute Account::SyncInput.new(attributes).valid?
      assert_database_failure { Account::SyncInput.insert_all!([ attributes.merge("id" => SecureRandom.uuid) ]) }
      assert_empty unsealed.account_sync_inputs
    end
  end

  test "pending deletion rejects preparation and selected input creation through model and SQL paths" do
    with_calculation do |context|
      sealed = context.account.syncs.create!
      sealed.update!(account_inputs_sealed_at: Time.current, account_inputs_digest: Account::SyncInput.digest([]))
      sealed.start!
      preparation_attributes = context.preparation.attributes.except("id").merge("sync_id" => sealed.id,
        "input_digest" => sealed.account_inputs_digest)
      selection_attributes = context.source.attributes.except("id")
      context.source.destroy!
      Account.where(id: context.account.id).update_all(status: "pending_deletion")

      refute Account::SyncPreparation.new(preparation_attributes).valid?
      refute Account::SyncSource.new(selection_attributes).valid?
      assert_database_failure { Account::SyncPreparation.insert_all!([ preparation_attributes.merge("id" => SecureRandom.uuid) ]) }
      assert_database_failure { Account::SyncSource.insert_all!([ selection_attributes.merge("id" => SecureRandom.uuid) ]) }
      assert_nil sealed.reload.account_sync_preparation
      assert_empty Account::SyncSource.where(account_id: context.account.id)
    end
  end

  test "raw input cannot name another same-family provider execution for its original batch" do
    with_calculation do |context|
      unsealed = context.account.syncs.create!
      other_provider_sync = context.connection.syncs.create!
      payload = context.input.payload.merge("provider_sync_id" => other_provider_sync.id)
      attributes = context.input.attributes.except("id").merge("id" => SecureRandom.uuid, "sync_id" => unsealed.id,
        "provider_sync_id" => other_provider_sync.id, "payload" => payload,
        "payload_digest" => Ingestion::HistoricalBalances.fingerprint(payload))

      refute Account::SyncInput.new(attributes).valid?
      assert_database_failure { Account::SyncInput.insert_all!([ attributes ]) }
      assert_empty unsealed.account_sync_inputs
      assert_equal context.provider_sync.id, context.input.source_batch.sync_id
    end
  end

  test "first trade preparation captures its live identity while an empty seal alone does not" do
    with_provider_encryption do
      family = Family.create!(name: "First calculation preparation")
      account = family.accounts.create!(name: "No source policy", balance: 0, currency: "USD", accountable: Investment.new)
      sync = account.sync_later
      refute Account::IngestionIdentity.exists?(account.id)
      sync.start!
      snapshot = Ingestion::HistoricalBalances::TradeFlowSnapshot.capture(account: account)

      preparation = sync.create_account_sync_preparation!(input_digest: sync.account_inputs_digest, payload: snapshot.payload)

      identity = Account::IngestionIdentity.find(account.id)
      assert_equal account.id, identity.live_account_id
      assert_equal family.id, identity.family_id
      assert preparation.valid?, preparation.errors.full_messages.to_sentence
      assert_equal snapshot.payload, preparation.trade_flows.payload
      assert_empty sync.account_sync_inputs
    end
  end

  test "live execution cleanup still permits removal after its selected pointer is cleared" do
    with_calculation do |context|
      input_id, preparation_id = context.input.id, context.preparation.id
      context.source.destroy!
      context.sync.destroy!

      refute Account::SyncInput.exists?(input_id)
      refute Account::SyncPreparation.exists?(preparation_id)
      assert Account.exists?(context.account.id)
      assert Account::IngestionIdentity.exists?(context.account.id)
      assert Sync.exists?(context.provider_sync.id)
    end
  end

  test "empty ordinary sealed executions do not prevent ordinary account deletion" do
    family = Family.create!(name: "Ordinary account cleanup")
    account = family.accounts.create!(name: "No retained calculation", balance: 0, currency: "USD", accountable: Depository.new)
    sync = account.sync_later
    assert_empty sync.account_sync_inputs
    assert sync.account_inputs_sealed_at

    account.destroy!

    refute Account.exists?(account.id)
    refute Sync.exists?(sync.id)
  end

  test "ordinary Account destruction refuses calculation evidence before clearing the selected pointer" do
    with_calculation do |context|
      # Remove unrelated policy restrictions so this proves calculation retention.
      Account::SourcePolicy.where(account_id: context.account.id).delete_all
      before = retained_rows(context)

      assert_equal false, context.account.destroy
      assert context.account.errors.any?
      assert_equal before, retained_rows(context)
      assert Account.exists?(context.account.id)
    end
  end

  test "stored evidence validation rejects changed original account family and preparation identity" do
    with_calculation do |context|
      context.input.family_id = families(:dylan_family).id
      refute context.input.valid?
      context.input.reload
      malformed = context.preparation.trade_flows.data.merge("account_id" => SecureRandom.uuid)
      context.preparation.payload = Ingestion::HistoricalBalances::TradeFlowSnapshot.new(malformed).payload
      refute context.preparation.valid?
      assert_raises(Provider::AccountData::InvalidResponse) { context.preparation.trade_flows }
    end
  end

  test "retained calculation families require explicit erase disposition instead of cascading or resetting" do
    with_calculation do |context|
      retire_fixture(context)
      before = retained_rows(context)

      assert_equal false, context.family.destroy
      assert context.family.errors.any?
      assert_database_failure { Family.where(id: context.family.id).delete_all }
      assert_raises(Family::FinancialDataReset::RetainedHistoryError) do
        Family::FinancialDataReset.new(family: context.family, dry_run: false, confirmed: true).call
      end
      assert_equal before, retained_rows(context)
      assert Family.exists?(context.family.id)
    end
  end

  private
    def with_calculation
      with_provider_encryption do
        travel_to Time.utc(2026, 5, 9, 12) do
          family = Family.create!(name: "Retained account calculation")
          connection = create_provider_connection(provider_key: "ibkr", writer_epoch: 1, family: family)
          provider_sync = connection.syncs.create!
          scope = Provider::AccountData::Ibkr::Archive.build(connection: connection, sync: provider_sync,
            observed_at: provider_sync.created_at).fetch(:scope)
          reader = Provider::AccountData::Ibkr.new(client: nil, timezone: scope.fetch("timezone"),
            observed_at: provider_sync.created_at, export_scope: scope, staged_xml: file_fixture("ibkr/flex_statement.xml").read)
          inventory = create_provider_batch(connection, sync: provider_sync, payload: Ingestion::Codec.dump(reader.list_accounts))
          account = family.accounts.create!(name: "Retained investment", currency: "CHF", balance: "3351", cash_balance: "1000.5",
            accountable: Investment.new)
          external = create_external_account(connection, external_id: "U1234567", currency: "CHF")
          link = AccountProvider.create!(account: account, external_account: external)
          %w[historical_balances balances].each { |resource| Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource) }
          handoff = Provider::AccountData::Ibkr::EquityCapture.new(connection: connection, sync: provider_sync,
            external_account: external, source_batch_id: inventory.id, writer_epoch: connection.writer_epoch,
            fence: ->(&block) { connection.with_lock(&block) }).capture!
          sync = Account::SyncQueue.new(account).enqueue(parent_sync: provider_sync, handoff: handoff)
          sync.start!
          snapshot = Ingestion::HistoricalBalances::TradeFlowSnapshot.capture(account: account)
          preparation = sync.create_account_sync_preparation!(input_digest: sync.account_inputs_digest, payload: snapshot.payload)
          yield Context.new(family, account, connection, provider_sync, sync, sync.account_sync_inputs.sole,
            Account::SyncSource.find_by!(account: account), preparation)
        end
      end
    end

    def retire_fixture(context)
      # Test-only atomic retirement of this isolated ledger. Keep every captured
      # calculation, policy and provider batch; this is not a public erase command.
      Account::SourcePolicy.where(account_id: context.account.id).update_all(active: false)
      context.account.account_providers.destroy_all
      Account::IngestionIdentity.where(id: context.account.id).update_all(live_account_id: nil, retired_at: Time.current)
      Account.where(id: context.account.id).delete_all
      ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
      ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement DEFERRED")
    end

    def retained_rows(context)
      [ context.sync, context.input, context.source, context.preparation ].map do |record|
        # Scalar SQL retains the ciphertext bytes as well as all original IDs and
        # timestamps; inspecting history must not decrypt and rewrite captures.
        record.class.connection.select_one(record.class.where(id: record.id).to_sql)
      end
    end

    def assert_database_failure(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true, &block)
      end
    end
end
