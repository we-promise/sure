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
      "account syncs start with no CAD/USD rate, so balances convert at 1:1 until a later sync"
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

  test "deletes the family's cached balances and holdings" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")
    @account.holdings.create!(security: securities(:aapl), date: 1.day.ago.to_date, qty: 1, price: 200, amount: 200, currency: "CAD")

    DataCacheClearJob.perform_now(@family)

    assert_empty @account.balances.reload
    assert_empty @account.holdings.reload
  end
end
