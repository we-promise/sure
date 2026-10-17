require "test_helper"

class BalanceSheet::NetWorthSeriesBuilderFxCacheTest < ActiveSupport::TestCase
  test "net worth series cache key changes when an exchange rate is created" do
    family = families(:dylan_family)
    period = Period.last_30_days
    builder = BalanceSheet::NetWorthSeriesBuilder.new(family)

    before = builder.send(:cache_key, period)

    ExchangeRate.create!(
      from_currency: "CAD",
      to_currency: family.currency,
      date: Date.current,
      rate: 0.75
    )

    after = builder.send(:cache_key, period)

    assert_not_equal before, after
  end
end
