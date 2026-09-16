require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::MercuryHistoryWindowsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
    Account.any_instance.stubs(:sync_later)
  end

  teardown do
    travel_back
  end

  test "initial hints survive discovery and select independent account windows" do
    with_history_sources([ "2020-01-01", "2023-04-05" ]) do |connection, externals, _accounts, _client, requests|
      sync = connection.syncs.create!

      run_sync(connection, sync)

      assert_nil sync.reload.window_start_date
      assert_windows(requests, sync, externals.zip([ Time.utc(2020, 1, 1), Time.utc(2023, 4, 5) ]).to_h)
      assert_equal [ "2020-01-01", "2023-04-05" ], externals.map { |external| external.reload.metadata.fetch("mercury_initial_history_start") }
      externals.each do |external|
        checkpoint = transaction_checkpoint(connection, external)
        assert checkpoint.ingestion_batch.applied?
        assert_equal sync.created_at, checkpoint.covered_through
      end
    end
  end

  test "explicit account and connection starts take precedence over copied first-read hints" do
    with_history_sources([ "2020-01-01", "2021-01-01" ]) do |connection, externals, _accounts, _client, requests|
      connection.update!(sync_start_date: Date.new(2026, 7, 1))
      externals.first.update!(sync_start_date: Date.new(2026, 9, 1))
      sync = connection.syncs.create!

      run_sync(connection, sync)

      assert_windows(requests, sync, { externals.first => Time.utc(2026, 9, 1), externals.last => Time.utc(2026, 7, 1) })
      assert_nil sync.reload.window_start_date
      assert_equal Date.new(2026, 9, 1), externals.first.reload.sync_start_date
      assert_equal Date.new(2026, 7, 1), connection.reload.sync_start_date
    end
  end

  test "an absent hint retains the default from the original Sync clock" do
    with_history_sources([ :absent ]) do |connection, externals, _accounts, _client, requests|
      sync = connection.syncs.create!
      travel 2.days

      run_sync(connection, sync)

      assert_windows(requests, sync, { externals.first => sync.created_at - 90.days })
      refute externals.first.reload.metadata.key?("mercury_initial_history_start")
    end
  end

  test "a completed native checkpoint takes precedence over the original first-read hint" do
    with_history_sources([ "2020-01-01" ]) do |connection, externals, _accounts, _client, requests|
      external = externals.first
      covered = Time.utc(2026, 9, 10, 9)
      connection.provider_sync_checkpoints.create!(external_account: external, stream: "transactions",
        scope_key: "account:#{external.id}", covered_through: covered)
      sync = connection.syncs.create!

      run_sync(connection, sync)

      assert_windows(requests, sync, { external => covered - 7.days })
      assert_equal sync.created_at, transaction_checkpoint(connection, external).covered_through
      assert_equal "2020-01-01", external.reload.metadata.fetch("mercury_initial_history_start")
    end
  end

  test "present malformed hints fail before a transaction request without claiming coverage" do
    [ nil, "", "2026-02-30", "2026-9-01", "2026-09-01T00:00:00Z", " 2026-09-01", 123, {} ].each do |hint|
      with_history_sources([ hint ]) do |connection, externals, accounts, _client, requests|
        error = assert_raises(Provider::AccountData::InvalidResponse, hint.inspect) do
          Provider::AccountData::Mercury.new(client: nil, timezone: "UTC").initial_history_start(
            account: { metadata: externals.first.metadata }, observed_at: Time.current)
        end
        assert_equal "Invalid Mercury initial history date", error.message
        # Syncer records a resource failure and reports its aggregate error after
        # retaining any independently completed balance stream.
        assert_raises(Provider::AccountData::Error, hint.inspect) do
          run_sync(connection, connection.syncs.create!)
        end

        assert_empty requests
        assert_nil transaction_checkpoint(connection, externals.first)
        assert_empty connection.ingestion_batches.where(stream: "transactions")
        assert_empty accounts.first.entries
      end
    end
  end

  test "a hint changed during HTTP leaves captured response evidence and refuses financial publication" do
    with_history_sources([ "2020-01-01" ]) do |connection, externals, accounts, client, requests|
      external = externals.first
      client.transaction_response = lambda do |request|
        ExternalAccount.find(external.id).update!(metadata: external.reload.metadata.merge("mercury_initial_history_start" => "2021-01-01"))
        [ { id: "after-hint-change", accountId: request.fetch(:account_id), bankDescription: "Should remain captured",
          amount: "-10.00", status: "sent", createdAt: "2026-09-14T12:00:00Z", postedAt: "2026-09-15T12:00:00Z" } ]
      end

      error = assert_raises(Provider::AccountData::StaleWriter) do
        run_sync(connection, connection.syncs.create!)
      end

      assert_includes error.message, "Request window configuration or checkpoint changed"
      assert_equal 1, requests.size
      assert_equal Time.utc(2020, 1, 1), Time.iso8601(requests.sole.fetch(:start))
      batch = connection.ingestion_batches.where(stream: "transactions").sole
      assert batch.captured?
      page = Ingestion::Codec.load(batch.payload)
      assert page.evidence.key?(Provider::AccountData::RequestInputs::EVIDENCE_KEY)
      assert_equal [ "mercury_after-hint-change" ], page.records.map { |record| record[:external_id] }
      assert_nil transaction_checkpoint(connection, external)
      assert_empty accounts.first.entries
      assert_empty SourceRecord.where(ingestion_batch: batch)
    end
  end

  private
    class HistoryClient
      attr_accessor :transaction_response

      def initialize(ids, requests)
        @ids, @requests = ids, requests
        @transaction_response = ->(_request) { [] }
      end

      def get_accounts_page(cursor:)
        { items: @ids.map { |id| { id: id, name: "Mercury history account", currentBalance: "0.00" } }, next_cursor: nil }
      end

      def get_account_transactions_page(account_id, cursor:, start_date:, end_date:)
        request = { account_id: account_id, cursor: cursor, start: start_date, end: end_date }
        @requests << request
        { items: transaction_response.call(request), next_cursor: nil }
      end
    end

    def with_history_sources(hints)
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "mercury", credentials: { "token" => "private-mercury-token" })
        accounts = []
        externals = hints.each_with_index.map do |hint, index|
          metadata = hint == :absent ? {} : { "mercury_initial_history_start" => hint }
          external = create_external_account(connection, external_id: "mercury-history-#{index}", metadata: metadata)
          account = connection.family.accounts.create!(name: "Mercury history #{index}", currency: "USD", balance: 0, accountable: Depository.new)
          accounts << account
          link = AccountProvider.create!(account: account, external_account: external)
          Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: %w[transactions balances])
          external
        end
        requests = []
        client = HistoryClient.new(externals.map(&:external_id), requests)
        Provider::Mercury.stubs(:new).returns(client)
        yield connection, externals, accounts, client, requests
      end
    end

    def run_sync(connection, sync)
      Provider::AccountData::Syncer.new(connection).perform_sync(sync)
    end

    def transaction_checkpoint(connection, external)
      connection.provider_sync_checkpoints.find_by(stream: "transactions", scope_key: "account:#{external.id}")
    end

    def assert_windows(requests, sync, starts)
      assert_equal starts.size, requests.size
      by_id = requests.index_by { |request| request.fetch(:account_id) }
      starts.each do |external, start|
        request = by_id.fetch(external.external_id)
        assert_equal start, Time.iso8601(request.fetch(:start))
        assert_equal sync.created_at, Time.iso8601(request.fetch(:end))
        assert_nil request.fetch(:cursor)
      end
    end
end
