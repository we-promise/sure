require "test_helper"

class ExchangeRate::CachedOnlyTest < ActiveSupport::TestCase
  test "native materialization uses dated cache and never falls back to a provider" do
    ExchangeRate.where(from_currency: "EUR", to_currency: "CHF").delete_all
    rate = ExchangeRate.create!(from_currency: "EUR", to_currency: "CHF", date: Date.new(2026, 5, 8), rate: "0.92")
    ExchangeRate.expects(:provider).never
    ExchangeRate.with_cached_rates_only do
      assert_equal rate, ExchangeRate.find_or_fetch_rate(from: "EUR", to: "CHF", date: Date.new(2026, 5, 9))
      assert_raises(ExchangeRate::Provided::MissingCachedRate) do
        ExchangeRate.find_or_fetch_rate(from: "EUR", to: "CHF", date: Date.new(2026, 5, 14))
      end
    end
  end

  test "cached-only scope restores legacy lookup behavior after exceptions and nested scopes" do
    ExchangeRate.where(from_currency: "EUR", to_currency: "CHF").delete_all
    ExchangeRate.stubs(:provider).returns(nil)
    assert_raises(ExchangeRate::Provided::MissingCachedRate) do
      ExchangeRate.with_cached_rates_only do
        ExchangeRate.with_cached_rates_only { assert true }
        ExchangeRate.find_or_fetch_rate(from: "EUR", to: "CHF", date: Date.new(2026, 5, 9))
      end
    end
    assert_nil ExchangeRate.find_or_fetch_rate(from: "EUR", to: "CHF", date: Date.new(2026, 5, 9))
  end

  test "invalid persisted rates abort native calculations instead of reaching legacy conversion fallbacks" do
    ExchangeRate.where(from_currency: "EUR", to_currency: "CHF").delete_all
    ExchangeRate.create!(from_currency: "EUR", to_currency: "CHF", date: Date.new(2026, 5, 8), rate: "0")
    ExchangeRate.with_cached_rates_only do
      assert_raises(ExchangeRate::Provided::MissingCachedRate) do
        Money.new(10, "EUR").exchange_to("CHF", date: Date.new(2026, 5, 8))
      end
    end
  end
end
