require "test_helper"
require "ostruct"

class DataCacheClearJobTest < ActiveJob::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock("provider")
    Provider::Registry.any_instance.stubs(:get_provider).returns(@provider)

    @family = Family.create!(name: "Cache clear", currency: "USD")
    @account = @family.accounts.create!(
      name: "Foreign savings",
      currency: "CAD",
      balance: 1000,
      accountable: Depository.new
    )
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: Date.current, rate: 0.7)
  end

  test "reloads the exchange rates the family needs before its accounts sync" do
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([
      OpenStruct.new(from: "CAD", to: "USD", date: Date.current, rate: 0.73)
    ]))

    DataCacheClearJob.perform_now(@family)

    assert_enqueued_jobs 1, only: SyncJob
    assert_equal 0.73, ExchangeRate.find_by(from_currency: "CAD", to_currency: "USD", date: Date.current)&.rate&.to_f,
      "account syncs must start with the refreshed CAD/USD rate"
  end

  test "keeps the market data and cached balances of other families" do
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([]))
    other_rate = ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0.0067)
    other_price = Security::Price.create!(security: securities(:aapl), date: 3.days.ago.to_date, price: 200, currency: "USD")
    other_balance_ids = accounts(:depository).balances.pluck(:id)
    other_holding_ids = accounts(:investment).holdings.pluck(:id)
    assert other_balance_ids.any?
    assert other_holding_ids.any?

    DataCacheClearJob.perform_now(@family)

    assert ExchangeRate.exists?(other_rate.id)
    assert Security::Price.exists?(other_price.id)
    assert_equal other_balance_ids.sort, Balance.where(id: other_balance_ids).pluck(:id).sort
    assert_equal other_holding_ids.sort, Holding.where(id: other_holding_ids).pluck(:id).sort
  end

  test "refreshes the prices of held securities before it deletes the holdings" do
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([]))
    brokerage = @family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "CLRC", exchange_operating_mic: "XNAS")
    brokerage.holdings.create!(security: security, date: 1.day.ago.to_date, qty: 1, price: 200, amount: 200, currency: "USD")

    Security.any_instance.expects(:import_provider_prices).with(has_entry(clear_cache: true)).once
    Security.any_instance.stubs(:import_provider_details)

    DataCacheClearJob.perform_now(@family)

    assert_empty brokerage.holdings.reload
  end

  test "deletes the family's cached balances and holdings" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")
    @account.holdings.create!(security: securities(:aapl), date: 1.day.ago.to_date, qty: 1, price: 200, amount: 200, currency: "CAD")

    DataCacheClearJob.perform_now(@family)

    assert_empty @account.balances.reload
    assert_empty @account.holdings.reload
  end

  test "rolls the delete back when the sync cannot be scheduled" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")
    @family.stubs(:sync_later).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_raises(ActiveRecord::StatementInvalid) { DataCacheClearJob.perform_now(@family) }

    assert Balance.exists?(balance.id)
  end

  test "waits for a running sync instead of deleting the balances it writes" do
    Family::MarketDataRefresher.any_instance.expects(:refresh).never
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")
    @account.syncs.create!(status: "syncing")

    assert_enqueued_with(job: DataCacheClearJob, args: [ @family ]) do
      DataCacheClearJob.perform_now(@family)
    end

    assert Balance.exists?(balance.id)
    assert_no_enqueued_jobs only: SyncJob
  end

  test "waits when a sync starts while the market data is refreshed" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh).with { @family.syncs.create!(status: "pending") }
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")

    assert_enqueued_with(job: DataCacheClearJob, args: [ @family ]) do
      DataCacheClearJob.perform_now(@family)
    end

    assert Balance.exists?(balance.id)
  end

  test "locks the family's accounts before it checks for running syncs" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      DataCacheClearJob.perform_now(@family)
    end

    lock_index = queries.index { |sql| sql.match?(/FROM "accounts".*FOR UPDATE/m) }
    sync_check_index = queries.rindex { |sql| sql.match?(/FROM "syncs"/) && sql.include?("EXISTS") || sql.match?(/SELECT 1 AS one FROM "syncs"/) }
    assert lock_index, "accounts are not locked"
    assert lock_index < sync_check_index, "accounts are locked only after the running-sync check"
  end
end
