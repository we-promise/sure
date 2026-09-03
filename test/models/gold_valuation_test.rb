require "test_helper"

class GoldValuationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @account.holdings.destroy_all
    @account.accountable.update!(subtype: "gold", gold_form: "physical")
    @account.physical_gold_lots.create!(description: "Bar", acquired_on: Date.current, weight: 100, weight_unit: "gram", karat: 24, cost_amount: 10_000)
  end

  test "uses the cached daily XAU rate and records the calculated account value" do
    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: Date.current, rate: 3_110.34768)

    value = GoldValuation.new(account: @account).refresh!

    assert_in_delta 10_000, value, 0.01
    assert_in_delta 10_000, @account.reload.balance, 0.01
  end

  test "sums separately valued lots with different karats" do
    @account.physical_gold_lots.destroy_all
    @account.physical_gold_lots.create!(description: "Bar", acquired_on: Date.current, weight: 100, weight_unit: "gram", karat: 24, cost_amount: 10_000)
    @account.physical_gold_lots.create!(description: "Jewelry", acquired_on: Date.current, weight: 100, weight_unit: "gram", karat: 18, cost_amount: 7_500)
    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: Date.current, rate: 3_110.34768)

    value = GoldValuation.new(account: @account).refresh!

    assert_in_delta 17_500, value, 0.01
    assert_in_delta 17_500, @account.reload.balance, 0.01
  end

  test "requires complete physical gold details" do
    @account.physical_gold_lots.destroy_all

    assert_raises(GoldValuation::Error) { GoldValuation.new(account: @account).refresh! }
  end

  test "uses an individual manual value without requesting a spot price" do
    @account.physical_gold_lots.first.update!(manual_value: 12_500)
    Provider::Registry.expects(:get_provider).with(:gold_api).never

    GoldValuation.new(account: @account).refresh!

    assert_in_delta 12_500, @account.reload.balance, 0.01
  end

  test "reuses a newly cached XAU rate when another refresh stores it first" do
    provider = mock
    Provider::Registry.stubs(:get_provider).with(:gold_api).returns(provider)
    provider.expects(:fetch_gold_price).returns(
      Provider::Response.new(
        success?: true,
        data: Provider::GoldApi::Price.new(date: Date.current - 1.day, currency: "USD", price_per_troy_ounce: 3_110.34768),
        error: nil
      )
    )

    GoldValuation.new(account: @account).refresh!
    GoldValuation.new(account: @account).refresh!

    assert_equal 1, ExchangeRate.where(from_currency: "XAU", to_currency: "USD", date: Date.current).count
  end
end
