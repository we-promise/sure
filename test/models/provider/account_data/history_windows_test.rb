require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::HistoryWindowsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  # An explicit race seam after the real pure policy selects its date, before
  # RequestInputs admits the request. All factory/grant/publication paths run.
  class ConcurrentHistoryWise < Provider::AccountData::Wise
    def initial_history_start(account:, observed_at:)
      super.tap { client.history_selected! }
    end
  end

  setup do
    travel_to Time.utc(2026, 9, 15, 12)
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
  end

  teardown do
    travel_back
  end

  test "Akahu initial sync requests accessible history without a start date" do
    with_history_source("akahu") do |connection, external, client|
      sync = connection.syncs.create!
      expect_akahu_transactions(client, start: nil, finish: sync.created_at)

      run_sync(connection, sync)

      checkpoint = transaction_checkpoint(connection, external)
      assert_nil checkpoint.state.dig("coverage", "start")
      assert_equal sync.created_at, checkpoint.covered_through
      assert_equal 2, transaction_batches(connection).where(status: "applied").count
    end
  end

  test "explicit dates bind Akahu unbounded history and earlier sync dates widen configured history" do
    [
      { connection_start: Date.new(2026, 7, 1), expected: Date.new(2026, 7, 1) },
      { connection_start: Date.new(2026, 7, 1), account_start: Date.new(2026, 8, 1), expected: Date.new(2026, 8, 1) },
      { connection_start: Date.new(2026, 7, 1), account_start: Date.new(2026, 8, 1), sync_start: Date.new(2026, 6, 1), expected: Date.new(2026, 6, 1) },
      { sync_start: Date.new(2026, 8, 1), expected: Date.new(2026, 8, 1) },
      { connection_start: Date.new(2026, 7, 1), sync_start: Date.new(2026, 8, 1), expected: Date.new(2026, 7, 1) }
    ].each do |dates|
      with_history_source("akahu") do |connection, external, client|
        connection.update!(sync_start_date: dates[:connection_start])
        external.update!(sync_start_date: dates[:account_start])
        sync = connection.syncs.create!(window_start_date: dates[:sync_start])
        expect_akahu_transactions(client, start: dates.fetch(:expected), finish: sync.created_at)

        run_sync(connection, sync)

        assert_coverage(connection, start: dates.fetch(:expected), finish: sync.created_at)
      end
    end
  end

  test "Akahu completed history resumes with seven days of overlap" do
    with_history_source("akahu") do |connection, external, client|
      covered = Time.utc(2026, 9, 10, 10)
      seed_checkpoint(connection, external, covered)
      sync = connection.syncs.create!
      expect_akahu_transactions(client, start: covered - 7.days, finish: sync.created_at)

      run_sync(connection, sync)

      assert_coverage(connection, start: covered - 7.days, finish: sync.created_at)
      assert_equal sync.created_at, transaction_checkpoint(connection, external).covered_through
    end
  end

  test "explicit historical ends are honored and future ends stop at the captured sync clock" do
    [ Date.new(2026, 9, 1), Date.new(2026, 10, 1) ].each do |ending|
      with_history_source("akahu") do |connection, external, client|
        sync = connection.syncs.create!(window_start_date: Date.new(2026, 8, 1), window_end_date: ending)
        finish = ending < sync.created_at.to_date ? ending.to_time(:utc).end_of_day.change(usec: 0) : sync.created_at
        expect_akahu_transactions(client, start: Date.new(2026, 8, 1), finish: finish)

        run_sync(connection, sync)

        assert_coverage(connection, start: Date.new(2026, 8, 1), finish: finish)
      end
    end
  end

  test "Wise default history uses the captured sync clock for all thirty day statement pages" do
    with_history_source("wise") do |connection, external, client|
      sync = connection.syncs.create!
      start = sync.created_at - 365.days
      expect_wise_transactions(client, start: start, finish: sync.created_at)
      travel 2.days

      run_sync(connection, sync)

      assert_coverage(connection, start: start, finish: sync.created_at)
      assert_equal 14, transaction_batches(connection).where(status: "applied").count
      assert_equal sync.created_at, transaction_checkpoint(connection, external).covered_through
    end
  end

  test "Wise all history begins at the reported creation instant" do
    created = Time.utc(2026, 7, 10, 6)
    with_history_source("wise", import_all_history: true, creation_time: created.iso8601) do |connection, external, client|
      sync = connection.syncs.create!
      expect_wise_transactions(client, start: created, finish: sync.created_at)

      run_sync(connection, sync)

      assert_coverage(connection, start: created, finish: sync.created_at)
      assert_equal 4, transaction_batches(connection).where(status: "applied").count
    end
  end

  test "Wise all history without a creation date retains the year 2000 fallback for jars" do
    with_history_source("wise", import_all_history: true, creation_time: nil, savings: true) do |connection, external, client|
      sync = connection.syncs.create!
      client.expects(:get_balance_statement_page).never
      client.expects(:get_activities_page).with("profile_1", cursor: nil).returns(empty_page)

      run_sync(connection, sync)

      assert_coverage(connection, start: Time.utc(2000, 1, 1), finish: sync.created_at)
      assert_equal 1, transaction_batches(connection).where(status: "applied").count
    end
  end

  test "Wise explicit account date overrides provider history and earlier sync date widens it" do
    [ nil, Date.new(2026, 7, 1), Date.new(2026, 9, 1) ].each do |sync_start|
      with_history_source("wise", import_all_history: true, creation_time: "2026-01-01T00:00:00Z") do |connection, external, client|
        connection.update!(sync_start_date: Date.new(2026, 7, 15))
        external.update!(sync_start_date: Date.new(2026, 8, 1))
        sync = connection.syncs.create!(window_start_date: sync_start)
        start = sync_start == Date.new(2026, 7, 1) ? sync_start : Date.new(2026, 8, 1)
        expect_wise_transactions(client, start: start, finish: sync.created_at)

        run_sync(connection, sync)

        assert_coverage(connection, start: start, finish: sync.created_at)
      end
    end
  end

  test "Wise checkpoint overlap takes precedence over its all history default" do
    with_history_source("wise", import_all_history: true) do |connection, external, client|
      covered = Time.utc(2026, 9, 10, 8)
      seed_checkpoint(connection, external, covered)
      sync = connection.syncs.create!
      expect_wise_transactions(client, start: covered - 7.days, finish: sync.created_at)

      run_sync(connection, sync)

      assert_coverage(connection, start: covered - 7.days, finish: sync.created_at)
    end
  end

  test "Wise changed creation date between window selection and admission rejects before HTTP" do
    with_history_source("wise", import_all_history: true) do |connection, external, client|
      Provider::AccountData::Registry.stubs(:fetch).with("wise").returns(ConcurrentHistoryWise)
      client.define_singleton_method(:history_selected!) do
        fresh = ExternalAccount.find(external.id)
        fresh.update!(metadata: fresh.metadata.merge("creation_time" => "2025-01-01T00:00:00Z"))
      end
      client.expects(:get_balance_statement_page).never
      client.expects(:get_activities_page).never

      assert_raises(Provider::AccountData::StaleWriter) { run_sync(connection, connection.syncs.create!) }

      assert_empty transaction_batches(connection)
      assert_nil transaction_checkpoint(connection, external)
    end
  end

  test "Wise history preference changed during HTTP retains evidence without publishing a checkpoint" do
    with_history_source("wise") do |connection, external, client|
      client.define_singleton_method(:get_balance_statement_page) do |*args, **kwargs|
        fresh = ProviderConnection.find(connection.id)
        fresh.update!(settings: fresh.settings.merge("import_all_history" => true))
        { items: [], next_cursor: nil }
      end
      client.expects(:get_activities_page).never

      assert_raises(Provider::AccountData::StaleWriter) { run_sync(connection, connection.syncs.create!) }

      assert_equal 1, transaction_batches(connection).where(status: "captured").count
      assert_nil transaction_checkpoint(connection, external)
    end
  end

  private
    def with_history_source(key, import_all_history: false, creation_time: "2026-07-01T00:00:00Z", savings: false)
      with_provider_encryption do
        credentials = key == "akahu" ? { app_token: "test-app", user_token: "test-user" } : { token: "test-token" }
        settings = key == "wise" ? { profile_id: "profile_1", import_all_history: import_all_history } : {}
        connection = create_provider_connection(provider_key: key, credentials: credentials, settings: settings)
        external = create_external_account(connection, external_id: "account_1")
        account = Account.create!(family: connection.family, name: "History test", currency: "USD", balance: 0, accountable: Depository.new)
        link = AccountProvider.create!(account: account, external_account: external)
        %w[balances transactions].each do |resource|
          Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource)
        end
        client = Object.new
        if key == "akahu"
          Provider::AccountData::Registry.stubs(:fetch).with(key).returns(Provider::AccountData::Akahu)
          Provider::Akahu.expects(:new).with(app_token: "test-app", user_token: "test-user").returns(client)
          client.expects(:get_accounts_page).with(cursor: nil).returns(items: [ {
            _id: external.external_id, name: "Checking", type: "CHECKING", balance: { current: "0", currency: "USD" }
          } ], next_cursor: nil)
        else
          Provider::AccountData::Registry.stubs(:fetch).with(key).returns(Provider::AccountData::Wise)
          Provider::Wise.expects(:new).with("test-token", base_url: Provider::Wise::LIVE_BASE_URL, sca_private_key: nil).returns(client)
          raw = { id: external.external_id, type: savings ? "SAVINGS" : "STANDARD", name: "Wise USD",
            amount: { value: "0", currency: "USD" }, totalWorth: { value: "0" }, creationTime: creation_time }
          client.expects(:get_balances_page).with("profile_1", type: "STANDARD").returns(items: savings ? [] : [ raw ], next_cursor: nil)
          client.expects(:get_balances_page).with("profile_1", type: "SAVINGS").returns(items: savings ? [ raw ] : [], next_cursor: nil)
          client.expects(:get_borderless_accounts_page).with("profile_1").returns(empty_page)
        end
        yield connection, external, client
      end
    end

    def expect_akahu_transactions(client, start:, finish:)
      client.expects(:get_account_transactions_page).with(account_id: "account_1", start_date: start && utc(start).iso8601,
        end_date: utc(finish).iso8601, cursor: nil).returns(empty_page)
      client.expects(:get_pending_transactions_page).with(cursor: nil).returns(empty_page)
    end

    def expect_wise_transactions(client, start:, finish:)
      from = utc(start)
      loop do
        through = [ from + 30.days, finish ].min
        client.expects(:get_balance_statement_page).with("profile_1", "account_1", currency: "USD",
          interval_start: from, interval_end: through).returns(empty_page)
        break if through == finish
        from = through
      end
      client.expects(:get_activities_page).with("profile_1", cursor: nil).returns(empty_page)
    end

    def empty_page
      { items: [], next_cursor: nil }
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

    def assert_coverage(connection, start:, finish:)
      batches = transaction_batches(connection).order(:sequence).to_a
      assert batches.any?
      batches.each do |batch|
        assert batch.applied?
        assert_equal utc(start), Time.iso8601(batch.coverage.fetch("start"))
        assert_equal utc(finish), Time.iso8601(batch.coverage.fetch("end"))
      end
    end

    def utc(value)
      value.instance_of?(Date) ? value.to_time(:utc) : value.to_time.utc
    end
end
