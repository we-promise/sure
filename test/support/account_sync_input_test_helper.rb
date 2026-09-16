require_relative "provider_ingestion_test_helper"

module AccountSyncInputTestHelper
  include ProviderIngestionTestHelper

  def with_account_input
    with_provider_encryption do
      travel_to Time.utc(2026, 5, 9, 12) do
        DebugLogEntry.stubs(:capture)
        family = families(:empty).reload
        family_timestamps = family.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        @connection = create_provider_connection(provider_key: "ibkr", writer_epoch: 1, family: family)
        @provider_sync = @connection.syncs.create!
        scope = Provider::AccountData::Ibkr::Archive.build(connection: @connection, sync: @provider_sync, observed_at: @provider_sync.created_at).fetch(:scope)
        reader = Provider::AccountData::Ibkr.new(client: nil, timezone: scope.fetch("timezone"), observed_at: @provider_sync.created_at,
          export_scope: scope, staged_xml: file_fixture("ibkr/flex_statement.xml").read)
        @inventory = create_provider_batch(@connection, sync: @provider_sync, payload: Ingestion::Codec.dump(reader.list_accounts))
        @account = @connection.family.accounts.create!(name: "Sealed IBKR calculation", currency: "CHF", balance: "3351", cash_balance: "1000.5", accountable: Investment.new)
        @external = create_external_account(@connection, external_id: "U1234567", currency: "CHF")
        @link = AccountProvider.create!(account: @account, external_account: @external)
        @history_policy = Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "historical_balances")
        Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "balances")
        @handoff = capture_account_handoff
        yield
      ensure
        begin
          Account::SyncSource.where(account: @account).delete_all if @account
          @account&.syncs&.destroy_all
          @connection&.ingestion_batches&.destroy_all
          Account::SourcePolicy.where(account_id: @account.id).delete_all if @account
          @account&.account_providers&.destroy_all
          @connection&.syncs&.destroy_all
          @connection&.destroy!
          @account&.destroy!
        ensure
          # These suites commit so they can exercise real session locks. Sync
          # callbacks touch the fixture family even after its test rows go away.
          Family.where(id: family.id).update_all(family_timestamps) if family && family_timestamps
        end
      end
    end
  end

  def capture_account_handoff
    Provider::AccountData::Ibkr::EquityCapture.new(connection: @connection, sync: @provider_sync, external_account: @external,
      source_batch_id: @inventory.id, writer_epoch: @connection.writer_epoch, fence: ->(&block) { @connection.with_lock(&block) }).capture!
  end

  def enqueue_account_handoff
    Account::SyncQueue.new(@account).enqueue(parent_sync: @provider_sync, handoff: @handoff)
  end

  def seed_account_history
    @opening = @account.entries.create!(name: "Opening anchor", date: Date.new(2026, 5, 1), amount: "3351", currency: "CHF",
      entryable: Valuation.new(kind: "opening_anchor"))
    @account.entries.create!(name: "Current anchor", date: Date.new(2026, 5, 8), amount: "3351", currency: "CHF",
      entryable: Valuation.new(kind: "current_anchor"))
    @account.entries.create!(name: "Deposit", date: Date.new(2026, 5, 3), amount: "-500", currency: "CHF",
      entryable: Transaction.new)
  end
end
