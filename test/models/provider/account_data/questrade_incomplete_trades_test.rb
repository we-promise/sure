require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::QuestradeIncompleteTradesTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    Provider::AccountData::Questrade.stubs(:native_ready?).returns(true)
  end

  teardown do
    travel_back
  end

  test "independent activities commit while an unpriced trade and fee retain their original retry window" do
    with_source do |connection, external, account, client|
      sync = connection.syncs.create!(window_start_date: Date.new(2026, 8, 1))
      DebugLogEntry.expects(:capture).with do |values|
        values[:provider_key] == "questrade" && values[:family] == connection.family &&
          values[:account_provider] == external.account_provider &&
          values[:metadata][:error_class] == "Provider::AccountData::IncompletePage"
      end.at_least_once

      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, sync, client) }

      assert_equal 2, client.requests.size
      assert_equal [ "Later deposit" ], account.entries.pluck(:name)
      cash_id = account.entries.sole.id
      batches = connection.ingestion_batches.where(sync: sync, stream: "activities").order(:sequence).to_a
      assert_equal 2, batches.size
      assert batches.all?(&:applied?)
      assert batches.none?(&:complete?)
      payloads = batches.map(&:payload)
      first = Ingestion::Codec.load(batches.first.payload)
      assert_empty first.records
      assert_nil first.evidence.fetch("response").with_indifferent_access.fetch(:activities).sole[:price]
      assert_includes first.warnings, { "code" => "missing_trade_price", "count" => 1 }
      assert_equal 1, SourceRecord.where(external_account: external, kind: "activity").count
      assert_empty account.entries.where(entryable_type: "Trade")

      checkpoint = activity_checkpoint(connection, external)
      assert_nil checkpoint.covered_through
      assert_nil checkpoint.ingestion_batch_id
      assert_nil checkpoint.cursor
      assert checkpoint.state.dig("progress", "cursor").present?
      original_requests = client.requests.deep_dup

      # The same execution replays the retained incomplete input, without
      # repeating HTTP or converting a partial history into successful coverage.
      assert_no_difference [ "Entry.count", "SourceRecord.count", "IngestionBatch.count" ] do
        assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, sync, client) }
      end
      assert_equal original_requests, client.requests
      assert_equal cash_id, account.entries.sole.id

      # A later execution can obtain the missing price. Its retry starts at the
      # original boundary, even after that boundary falls outside default history.
      travel 4.years
      client.price = "10.25"
      run_sync(connection, connection.syncs.create!, client)

      assert_equal original_requests, client.requests.last(2)
      assert_equal 3, account.entries.count
      assert_equal cash_id, account.entries.find_by!(name: "Later deposit").id
      trade = account.entries.where(entryable_type: "Trade").sole
      assert_equal BigDecimal("20.50"), trade.amount
      assert_equal BigDecimal("10.25"), trade.trade.price
      assert_equal BigDecimal("0.50"), account.entries.find_by!(name: "Commission for AAPL").amount
      assert_equal 3, SourceRecord.where(external_account: external, kind: "activity").count
      assert_equal Time.iso8601(first.coverage.fetch("end")), checkpoint.reload.covered_through
      assert_nil checkpoint.state["progress"]
      assert checkpoint.ingestion_batch.applied?
      assert checkpoint.ingestion_batch.complete?
      assert_equal payloads, batches.map { |batch| batch.reload.payload }
    end
  end

  test "an incomplete later scan preserves its previously completed checkpoint" do
    with_source do |connection, external, account, client|
      client.price = "10.25"
      run_sync(connection, connection.syncs.create!(window_start_date: Date.new(2026, 8, 1)), client)
      checkpoint = activity_checkpoint(connection, external)
      completed = checkpoint.attributes.slice("covered_through", "cursor", "ingestion_batch_id")
      identities = account.entries.order(:id).pluck(:id, :external_id, :amount)

      client.price = nil
      travel 1.day
      assert_raises(Provider::AccountData::IncompletePage) do
        run_sync(connection, connection.syncs.create!(window_start_date: Date.new(2026, 8, 1)), client)
      end

      assert_equal completed, checkpoint.reload.attributes.slice("covered_through", "cursor", "ingestion_batch_id")
      assert checkpoint.state.dig("progress", "cursor").present?
      assert_equal identities, account.entries.order(:id).pluck(:id, :external_id, :amount)
    end
  end

  private
    class ActivityClient
      attr_accessor :price
      attr_reader :requests

      def initialize
        @requests = []
      end

      def get_ingestion_accounts
        { accounts: [ { number: "123", type: "TFSA", status: "Active" } ] }
      end

      def get_ingestion_balances(account_id:)
        { perCurrencyBalances: [], combinedBalances: [] }
      end

      def get_ingestion_holdings(account_id:)
        { positions: [] }
      end

      def get_ingestion_activities(account_id:, start_time:, end_time:)
        requests << { account_id: account_id, start_time: start_time, end_time: end_time }
        row = if Date.iso8601(start_time) == Date.new(2026, 8, 1)
          { type: "Trades", action: "Buy", symbol: "AAPL", symbolId: 456,
            quantity: "2", price: price, netAmount: "-21", commission: "-0.50", description: "Apple purchase",
            transactionDate: "2026-08-10T12:00:00-04:00", currency: "CAD" }
        else
          { type: "Deposits", symbol: "", quantity: "0", netAmount: "50", description: "Later deposit",
            transactionDate: "2026-09-05T12:00:00-04:00", currency: "CAD" }
        end
        { activities: [ row ] }
      end
    end

    def with_source
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "questrade", credentials: { "refresh_token" => "private-token" })
        external = create_external_account(connection, external_id: "123", currency: "CAD")
        account = connection.family.accounts.create!(name: "Questrade investment", currency: "CAD", balance: 0, accountable: Investment.new)
        link = AccountProvider.create!(account: account, external_account: external)
        Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: %w[activities balances holdings])
        yield connection, external, account, ActivityClient.new
      end
    end

    def run_sync(connection, sync, client)
      adapter = Provider::AccountData::Questrade.new(client: client, timezone: "America/Toronto", observed_at: sync.created_at)
      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
    end

    def activity_checkpoint(connection, external)
      connection.provider_sync_checkpoints.find_by!(stream: "activities", scope_key: "account:#{external.id}")
    end
end
