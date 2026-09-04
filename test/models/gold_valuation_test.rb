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
    Provider::Registry.expects(:get_provider).with(:twelve_data).never
    Provider::Registry.expects(:get_provider).with(:gold_api).never

    GoldValuation.new(account: @account).refresh!

    assert_in_delta 12_500, @account.reload.balance, 0.01
  end

  test "prefers the Twelve Data Gold Spot quote when configured" do
    twelve_data = mock
    Provider::Registry.expects(:get_provider).with(:twelve_data).returns(twelve_data)
    Provider::Registry.expects(:get_provider).with(:gold_api).never
    twelve_data.expects(:fetch_gold_price).with(date: Date.current).returns(
      Provider::Response.new(
        success?: true,
        data: Provider::TwelveData::GoldPrice.new(date: Date.current, currency: "USD", price_per_troy_ounce: 3_110.34768),
        error: nil
      )
    )

    GoldValuation.new(account: @account).refresh!

    assert_in_delta 10_000, @account.reload.balance, 0.01
  end

  test "converts the Twelve Data USD Gold Spot quote to the account currency" do
    @account.update!(currency: "INR")
    ExchangeRate.create!(from_currency: "USD", to_currency: "INR", date: Date.current, rate: 80)
    twelve_data = mock
    Provider::Registry.expects(:get_provider).with(:twelve_data).returns(twelve_data)
    Provider::Registry.expects(:get_provider).with(:gold_api).never
    twelve_data.expects(:fetch_gold_price).with(date: Date.current).returns(
      Provider::Response.new(
        success?: true,
        data: Provider::TwelveData::GoldPrice.new(date: Date.current, currency: "USD", price_per_troy_ounce: 3_110.34768),
        error: nil
      )
    )

    GoldValuation.new(account: @account).refresh!

    assert_in_delta 800_000, @account.reload.balance, 0.01
    assert_in_delta 248_827.8144, ExchangeRate.find_by!(from_currency: "XAU", to_currency: "INR", date: Date.current).rate, 0.0001
  end

  test "falls back to GoldAPI when Twelve Data cannot provide Gold Spot" do
    twelve_data = mock
    gold_api = mock
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(twelve_data)
    Provider::Registry.stubs(:get_provider).with(:gold_api).returns(gold_api)
    twelve_data.expects(:fetch_gold_price).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::TwelveData::Error.new("Commodity access requires a higher plan"))
    )
    gold_api.expects(:fetch_gold_price).with(currency: "USD").returns(
      Provider::Response.new(
        success?: true,
        data: Provider::GoldApi::Price.new(date: Date.current, currency: "USD", price_per_troy_ounce: 3_110.34768),
        error: nil
      )
    )

    assert_difference -> { DebugLogEntry.with_provider_key("twelve_data").count }, 1 do
      GoldValuation.new(account: @account).refresh!
    end

    assert_in_delta 10_000, @account.reload.balance, 0.01
    diagnostic = DebugLogEntry.with_provider_key("twelve_data").recent.first
    assert_equal "gold_valuation", diagnostic.category
    assert_equal @account, diagnostic.account
    assert_equal "Commodity access requires a higher plan", diagnostic.metadata["error"]
  end

  test "records the Twelve Data failure when GoldAPI fallback also fails" do
    twelve_data = mock
    gold_api = mock
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(twelve_data)
    Provider::Registry.stubs(:get_provider).with(:gold_api).returns(gold_api)
    twelve_data.expects(:fetch_gold_price).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::TwelveData::Error.new("Commodity access requires a higher plan"))
    )
    gold_api.expects(:fetch_gold_price).with(currency: "USD").returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::GoldApi::Error.new("GoldAPI unavailable"))
    )

    assert_difference -> { DebugLogEntry.with_provider_key("twelve_data").count }, 1 do
      assert_raises(GoldValuation::Error) { GoldValuation.new(account: @account).refresh! }
    end

    assert_equal "Commodity access requires a higher plan", DebugLogEntry.with_provider_key("twelve_data").recent.first.metadata["error"]
  end

  test "reuses a newly cached XAU rate when another refresh stores it first" do
    provider = mock
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(nil)
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

  test "uses the persisted daily rate when another refresh wins the cache race" do
    provider = mock
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:gold_api).returns(provider)
    provider.expects(:fetch_gold_price).returns(
      Provider::Response.new(
        success?: true,
        data: Provider::GoldApi::Price.new(date: Date.current, currency: "USD", price_per_troy_ounce: 1_555.17384),
        error: nil
      )
    )
    winning_rate = Struct.new(:date, :rate).new(Date.current, 3_110.34768)
    ExchangeRate.expects(:create_or_find_by!).returns(winning_rate)

    value = GoldValuation.new(account: @account).refresh!

    assert_in_delta 10_000, value, 0.01
    assert_in_delta 10_000, @account.reload.balance, 0.01
  end
end
