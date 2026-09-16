require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::SimplefinHistoryWindowsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    travel_to Time.utc(2026, 9, 15, 12)
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
  end

  teardown do
    travel_back
  end

  test "initial history fetches all six sixty day pages even after two empty pages" do
    with_history_source do |connection, external, account, client, requests|
      sync = connection.syncs.create!
      historical_date = (sync.created_at - 330.days).to_date
      client.response_transactions = lambda do |start, finish|
        next [] unless start && historical_date.between?(start.to_date, finish.to_date)
        [ { id: "old-dividend", amount: "12.34", posted: historical_date.to_s,
          description: "Historical dividend", pending: false } ]
      end

      run_sync(connection, sync)

      assert_windows(requests, start: sync.created_at - 360.days, finish: sync.created_at, count: 6)
      imported = account.entries.find_by!(source: "simplefin", external_id: "simplefin_old-dividend")
      assert_equal historical_date, imported.date
      assert_equal BigDecimal("-12.34"), imported.amount
      checkpoint = transaction_checkpoint(connection, external)
      assert_equal sync.created_at, checkpoint.covered_through
      assert_equal (sync.created_at - 360.days).iso8601, checkpoint.state.dig("coverage", "start")
      assert_equal 6, transaction_batches(connection).where(status: "applied").count
    end
  end

  test "a completed checkpoint uses thirty days of overlap and the captured sync clock" do
    with_history_source do |connection, external, account, client, requests|
      covered = Time.utc(2026, 9, 10, 10)
      seed_checkpoint(connection, external, covered)
      sync = connection.syncs.create!
      travel 2.days

      run_sync(connection, sync)

      assert_windows(requests, start: covered - 30.days, finish: sync.created_at, count: 1)
      assert_equal sync.created_at, transaction_checkpoint(connection, external).covered_through
    end
  end

  test "configured dates and an earlier per sync date retain their precedence" do
    [
      { connection: Date.new(2026, 6, 1), expected: Date.new(2026, 6, 1) },
      { connection: Date.new(2026, 6, 1), account: Date.new(2026, 8, 1), expected: Date.new(2026, 8, 1) },
      { connection: Date.new(2026, 6, 1), account: Date.new(2026, 8, 1), sync: Date.new(2026, 5, 1), expected: Date.new(2026, 5, 1) },
      { account: Date.new(2026, 8, 1), sync: Date.new(2026, 9, 1), expected: Date.new(2026, 8, 1) }
    ].each do |dates|
      with_history_source do |connection, external, account, client, requests|
        connection.update!(sync_start_date: dates[:connection])
        external.update!(sync_start_date: dates[:account])
        sync = connection.syncs.create!(window_start_date: dates[:sync])

        run_sync(connection, sync)

        assert_windows(requests, start: dates.fetch(:expected).to_time(:utc), finish: sync.created_at)
      end
    end
  end

  test "an initial explicit backfill is capped at one calendar year including its final short page" do
    with_history_source do |connection, external, account, client, requests|
      external.update!(sync_start_date: Date.new(2024, 1, 1))
      sync = connection.syncs.create!(window_start_date: Date.new(2023, 1, 1))
      floor = Time.utc(2025, 9, 15)

      run_sync(connection, sync)

      assert_windows(requests, start: floor, finish: sync.created_at, count: 7)
      assert_equal floor.iso8601, transaction_checkpoint(connection, external).state.dig("coverage", "start")
      assert_equal 7, transaction_batches(connection).where(status: "applied").count
    end
  end

  test "the initial calendar year cap accounts for leap years" do
    travel_to Time.utc(2024, 2, 29, 12)
    with_history_source do |connection, external, account, client, requests|
      connection.update!(sync_start_date: Date.new(2022, 1, 1))
      sync = connection.syncs.create!

      run_sync(connection, sync)

      assert_windows(requests, start: Time.utc(2023, 2, 28), finish: sync.created_at, count: 7)
    end
  end

  test "the calendar year floor uses UTC independently of the worker time zone" do
    Time.use_zone("America/Los_Angeles") do
      with_history_source do |connection, external, account, client, requests|
        connection.update!(sync_start_date: Date.new(2024, 1, 1))
        sync = connection.syncs.create!

        run_sync(connection, sync)

        assert_windows(requests, start: Time.utc(2025, 9, 15), finish: sync.created_at, count: 7)
      end
    end
  end

  test "a historical end stays fixed and an empty capped range cannot advance history" do
    with_history_source do |connection, external, account, client, requests|
      sync = connection.syncs.create!(window_start_date: Date.new(2026, 6, 1), window_end_date: Date.new(2026, 8, 1))

      run_sync(connection, sync)

      assert_windows(requests, start: Time.utc(2026, 6, 1), finish: Time.utc(2026, 8, 1, 23, 59, 59), count: 2)
    end
    with_history_source do |connection, external, account, client, requests|
      sync = connection.syncs.create!(window_start_date: Date.new(2023, 1, 1), window_end_date: Date.new(2024, 1, 1))

      assert_raises(Provider::AccountData::Error) { run_sync(connection, sync) }

      assert_empty requests.select { |request| request[:start] }
      assert_nil transaction_checkpoint(connection, external)
      assert_empty transaction_batches(connection)
    end
  end

  test "repeat history may explicitly widen beyond the initial history cap" do
    with_history_source do |connection, external, account, client, requests|
      seed_checkpoint(connection, external, Time.utc(2026, 9, 10))
      sync = connection.syncs.create!(window_start_date: Date.new(2025, 9, 1))

      run_sync(connection, sync)

      assert_windows(requests, start: Time.utc(2025, 9, 1), finish: sync.created_at, count: 7)
    end
  end

  test "an overdue completed checkpoint retains its older incremental gap" do
    with_history_source do |connection, external, account, client, requests|
      covered = Time.utc(2025, 9, 1)
      seed_checkpoint(connection, external, covered)
      sync = connection.syncs.create!

      run_sync(connection, sync)

      assert_windows(requests, start: covered - 30.days, finish: sync.created_at, count: 7)
      assert_equal sync.created_at, transaction_checkpoint(connection, external).covered_through
    end
  end

  test "interrupted history retries exact captured pages without advancing its checkpoint early" do
    with_history_source do |connection, external, account, client, requests|
      sync = connection.syncs.create!
      client.response_transactions = lambda do |start, finish|
        if start && finish == sync.created_at - 60.days
          raise Provider::AccountData::IncompletePage, "Interrupted historical page"
        end
        []
      end
      assert_raises(Provider::AccountData::IncompletePage) { run_sync(connection, sync) }
      assert_nil transaction_checkpoint(connection, external)
      assert_equal 1, transaction_batches(connection).where(status: "applied").count
      client.response_transactions = ->(start, finish) { [] }
      requests.clear

      run_sync(connection, sync)

      assert_windows(requests, start: sync.created_at - 360.days, finish: sync.created_at - 60.days, count: 5)
      assert_equal sync.created_at, transaction_checkpoint(connection, external).covered_through
      assert_equal 6, transaction_batches(connection).where(status: "applied").count
    end
  end

  test "date configuration changed during a page retains evidence without publishing history" do
    with_history_source do |connection, external, account, client, requests|
      client.response_transactions = lambda do |start, finish|
        ExternalAccount.find(external.id).update!(sync_start_date: Date.new(2026, 8, 1)) if start
        []
      end

      assert_raises(Provider::AccountData::StaleWriter) { run_sync(connection, connection.syncs.create!) }

      assert_equal 1, requests.count { |request| request[:start] }
      assert_equal 1, transaction_batches(connection).where(status: "captured").count
      assert_nil transaction_checkpoint(connection, external)
    end
  end

  private
    class SnapshotClient
      attr_accessor :response_transactions

      def initialize(requests, observed_at)
        @requests, @observed_at = requests, observed_at
        @response_transactions = ->(start, finish) { [] }
      end

      def get_accounts_snapshot(access_url, start_date:, end_date:, pending:)
        @requests << { start: start_date, end: end_date, pending: pending }
        { accounts: [ { id: "sf-history", name: "Checking", type: "checking", currency: "USD", balance: "1000",
          "available-balance": "1000", "balance-date": @observed_at.to_i,
          org: { name: "Example Bank", domain: "example.bank" }, holdings: [],
          transactions: response_transactions.call(start_date, end_date) } ] }
      end
    end

    def with_history_source
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "simplefin", credentials: { "access_url" => "https://user:secret@bridge.example/access" })
        external = create_external_account(connection, external_id: "sf-history")
        account = Account.create!(family: connection.family, name: "History test", currency: "USD", balance: 0, accountable: Depository.new)
        link = AccountProvider.create!(account: account, external_account: external)
        %w[balances transactions holdings].each do |resource|
          Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource)
        end
        requests = []
        client = SnapshotClient.new(requests, Time.current)
        Provider::AccountData::Registry.stubs(:fetch).with("simplefin").returns(Provider::AccountData::Simplefin)
        Provider::Simplefin.stubs(:new).returns(client)
        yield connection, external, account, client, requests
      end
    end

    def run_sync(connection, sync)
      Provider::AccountData::Syncer.new(connection).perform_sync(sync)
    end

    def seed_checkpoint(connection, external, covered)
      connection.provider_sync_checkpoints.create!(stream: "transactions", scope_key: "account:#{external.id}",
        external_account: external, covered_through: covered)
    end

    def transaction_checkpoint(connection, external)
      connection.provider_sync_checkpoints.find_by(stream: "transactions", scope_key: "account:#{external.id}")
    end

    def transaction_batches(connection)
      connection.ingestion_batches.where(stream: "transactions")
    end

    def assert_windows(requests, start:, finish:, count: nil)
      windows = requests.select { |request| request[:start] }
      assert windows.any?
      assert_equal count, windows.size if count
      assert_equal finish, windows.first.fetch(:end)
      assert_equal start, windows.last.fetch(:start)
      windows.each do |window|
        assert_operator window.fetch(:start), :<, window.fetch(:end)
        assert_operator window.fetch(:end) - window.fetch(:start), :<=, 60.days
      end
      windows.each_cons(2) { |newer, older| assert_equal newer.fetch(:start), older.fetch(:end) }
    end
end
