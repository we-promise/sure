# frozen_string_literal: true

require "test_helper"

class Onchain::PricingTest < ActiveSupport::TestCase
  test "a USD family needs only the crypto provider" do
    with_crypto_provider(enabled: true) do
      assert Onchain::Pricing.ready_for?("USD")
      assert_empty Onchain::Pricing.missing_for("USD")
    end
  end

  test "a non-USD family also needs an exchange rate provider" do
    with_crypto_provider(enabled: true) do
      ExchangeRate.stubs(:provider).returns(nil)

      assert_not Onchain::Pricing.ready_for?("EUR")
      assert_equal [ :exchange_rate ], Onchain::Pricing.missing_for("EUR")
      # USD needs no conversion, so the same install is fine for a USD family.
      assert_empty Onchain::Pricing.missing_for("USD")
    end
  end

  test "both gaps are reported together" do
    with_crypto_provider(enabled: false) do
      ExchangeRate.stubs(:provider).returns(nil)

      assert_equal [ :crypto_provider, :exchange_rate ], Onchain::Pricing.missing_for("EUR")
    end
  end

  test "a configured exchange rate provider closes the second gap" do
    with_crypto_provider(enabled: true) do
      ExchangeRate.stubs(:provider).returns(Provider::Frankfurter.new)

      assert Onchain::Pricing.ready_for?("EUR")
    end
  end

  test "an unusable exchange rate setting reads as not configured rather than raising" do
    with_crypto_provider(enabled: true) do
      ExchangeRate.stubs(:provider).raises(Provider::Registry::Error, "nope")

      assert_not Onchain::Pricing.fx_configured?
      assert_equal [ :exchange_rate ], Onchain::Pricing.missing_for("EUR")
    end
  end

  private
    def with_crypto_provider(enabled:)
      providers = enabled ? [ Onchain::SecurityResolver::PRICE_PROVIDER ] : [ "twelve_data" ]
      Setting.stubs(:enabled_securities_providers).returns(providers)
      yield
    end
end
