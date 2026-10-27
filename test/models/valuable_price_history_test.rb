require "test_helper"

class ValuablePriceHistoryTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    @account.valuable.lots.create!(description: "Bar", acquired_on: Date.new(2026, 9, 1), weight: 100, weight_unit: "gram", karat: 24, cost_amount: 10_000)
    @end_date = Date.new(2026, 9, 4)
    @provider = mock
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(@provider)
  end

  test "stores futures closes as provisional rates from the first purchase" do
    expect_closes(Date.new(2026, 9, 1), Date.new(2026, 9, 1) => 3_000, Date.new(2026, 9, 2) => 3_010)

    assert_equal 2, import

    rate = ExchangeRate.find_by!(from_currency: "XAU", to_currency: "USD", date: Date.new(2026, 9, 2))
    assert_equal 3_010, rate.rate
    assert_equal "yahoo_futures", rate.source
    assert rate.provisional?
  end

  test "keeps a spot quote stored for the same day" do
    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: Date.new(2026, 9, 1), rate: 3_005, source: "gold_api_com", provisional: true)
    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: Date.new(2026, 9, 2), rate: 3_015, source: "gold_api_com", provisional: true)
    expect_closes(Date.new(2026, 9, 3), Date.new(2026, 9, 3) => 3_020)

    assert_equal 1, import
    assert_equal 3_005, ExchangeRate.find_by!(from_currency: "XAU", date: Date.new(2026, 9, 1)).rate
  end

  test "backfills from the purchase when only recent quotes are stored" do
    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: @end_date, rate: 3_030, source: "gold_api_com", provisional: true)
    @account.valuable.lots.first.update!(acquired_on: Date.new(2026, 8, 1))
    expect_closes(Date.new(2026, 8, 1), Date.new(2026, 8, 3) => 2_900, @end_date => 3_000)

    assert_equal 1, import
    assert_equal 3_030, ExchangeRate.find_by!(from_currency: "XAU", date: @end_date).rate
  end

  test "converts closes into the account currency" do
    @account.update_columns(currency: "EUR")
    @account.valuable.lots.update_all(currency: "EUR")
    ExchangeRate.expects(:import_provider_rates).returns(0)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.new(2026, 8, 29), rate: 0.9)
    expect_closes(Date.new(2026, 9, 1), Date.new(2026, 9, 1) => 3_000)

    import

    assert_equal 2_700, ExchangeRate.find_by!(from_currency: "XAU", to_currency: "EUR", date: Date.new(2026, 9, 1)).rate
  end

  test "records a provider failure" do
    @provider.expects(:fetch_security_prices).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("rate limited")))

    assert_difference -> { DebugLogEntry.with_provider_key("yahoo_finance").count }, 1 do
      assert_equal 0, import
    end
  end

  test "ignores manually valued items" do
    @account.valuable.lots.first.update!(manual_value: 100)
    @provider.expects(:fetch_security_prices).never

    assert_equal 0, import
  end

  private
    def import = ValuablePriceHistory.new(account: @account, end_date: @end_date).import

    def expect_closes(start_date, closes)
      data = closes.map { |date, price| OpenStruct.new(date: date, price: price, currency: "USD") }
      @provider.expects(:fetch_security_prices).with(symbol: "GC=F", start_date: start_date, end_date: @end_date)
        .returns(Provider::Response.new(success?: true, data: data, error: nil))
    end
end
