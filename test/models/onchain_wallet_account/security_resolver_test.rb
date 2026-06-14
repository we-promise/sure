# frozen_string_literal: true

require "test_helper"

class OnchainWalletAccount::SecurityResolverTest < ActiveSupport::TestCase
  test "binds the CRYPTO ticker to Binance Public (USD) when enabled" do
    Setting.stubs(:enabled_securities_providers).returns([ "binance_public" ])

    resolved = OnchainWalletAccount::SecurityResolver.resolve("BTC", "Bitcoin")

    # Keeps the bare CRYPTO:<SYMBOL> ticker (priced as USD via parse_ticker)
    # rather than resolving to a foreign-currency pair.
    assert_equal "CRYPTO:BTC", resolved.ticker
    assert_equal Provider::BinancePublic::BINANCE_MIC, resolved.exchange_operating_mic
    assert_equal "binance_public", resolved.price_provider
    refute resolved.offline
  end

  test "creates an offline on-chain security when Binance Public is disabled" do
    Setting.stubs(:enabled_securities_providers).returns([])

    resolved = OnchainWalletAccount::SecurityResolver.resolve("BTC", "Bitcoin")

    assert_equal "CRYPTO:BTC", resolved.ticker
    assert resolved.offline
  end
end
