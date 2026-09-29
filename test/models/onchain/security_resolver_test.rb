# frozen_string_literal: true

require "test_helper"

class Onchain::SecurityResolverTest < ActiveSupport::TestCase
  test "binds a new security to the crypto price provider" do
    security = Onchain::SecurityResolver.resolve(symbol: "sol", name: "Solana")

    assert_equal "CRYPTO:SOL", security.ticker
    assert_equal Onchain::SecurityResolver::PRICE_PROVIDER, security.price_provider
    assert_equal Onchain::SecurityResolver::EXCHANGE_MIC, security.exchange_operating_mic
    assert_equal "Solana", security.name
  end

  test "bridged and wrapped variants resolve to the canonical security" do
    usdc = Onchain::SecurityResolver.resolve(symbol: "USDC")

    [ "USDC.e", "USDbC", "axlUSDC" ].each do |variant|
      assert_equal usdc, Onchain::SecurityResolver.resolve(symbol: variant), "#{variant} should resolve to USDC"
    end

    assert_equal "CRYPTO:USDT", Onchain::SecurityResolver.resolve(symbol: "USDT0").ticker
    assert_equal "CRYPTO:ETH", Onchain::SecurityResolver.resolve(symbol: "WETH").ticker
  end

  test "reuses an existing security for the ticker whatever its MIC" do
    existing = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", exchange_operating_mic: "XKRA")

    assert_no_difference "Security.count" do
      assert_equal existing, Onchain::SecurityResolver.resolve(symbol: "BTC")
    end
  end

  test "an unresolvable symbol returns nil without raising" do
    [ nil, "", "   ", "Visit site to claim rewards", "🚀🚀", "https://spam.example", "A" * 30 ].each do |symbol|
      assert_nil Onchain::SecurityResolver.resolve(symbol: symbol), "#{symbol.inspect} should not resolve"
      assert_not Onchain::SecurityResolver.priceable?(symbol)
    end
  end

  test "priceable? recognises a plausible ticker without creating a security" do
    assert_no_difference "Security.count" do
      assert Onchain::SecurityResolver.priceable?("wbtc")
    end
  end

  test "a reused security with no price provider is bound to the crypto one" do
    existing = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: nil)

    resolved = Onchain::SecurityResolver.resolve(symbol: "BTC")

    assert_equal existing, resolved
    # A blank provider falls back to whichever is enabled first, and only the
    # crypto one quotes a bare coin symbol, so the holding would value at zero.
    assert_equal Onchain::SecurityResolver::PRICE_PROVIDER, resolved.reload.price_provider
  end

  test "a price provider another integration chose is left alone" do
    existing = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: "yahoo_finance")

    resolved = Onchain::SecurityResolver.resolve(symbol: "BTC")

    assert_equal existing, resolved
    # The CRYPTO: prefix is shared with the exchange integrations; stomping their
    # choice would break their pricing to fix ours.
    assert_equal "yahoo_finance", resolved.reload.price_provider
  end
end
