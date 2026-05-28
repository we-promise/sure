# frozen_string_literal: true

require "test_helper"

class OnchainWalletAccount::SecurityResolverTest < ActiveSupport::TestCase
  test "resolves crypto through Binance Public when enabled" do
    binance_match = Security.new(
      ticker: "BTCUSD",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
      country_code: nil,
      price_provider: "binance_public"
    )

    Setting.stubs(:enabled_securities_providers).returns([ "binance_public" ])
    Security.expects(:search_provider)
      .with(
        "CRYPTO:BTC",
        exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC
      )
      .returns([ binance_match ])

    resolved = OnchainWalletAccount::SecurityResolver.resolve("BTC", "Bitcoin")

    assert_equal "BTCUSD", resolved.ticker
    assert_equal Provider::BinancePublic::BINANCE_MIC, resolved.exchange_operating_mic
    assert_equal "binance_public", resolved.price_provider
    refute resolved.offline
  end

  test "falls back to offline on-chain security when Binance Public is disabled" do
    Setting.stubs(:enabled_securities_providers).returns([])
    Security.expects(:search_provider).returns([])

    resolved = OnchainWalletAccount::SecurityResolver.resolve("BTC", "Bitcoin")

    assert_equal "CRYPTO:BTC", resolved.ticker
    assert_nil resolved.exchange_operating_mic
    assert resolved.offline
  end
end
