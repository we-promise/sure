require "test_helper"

class BinanceAccount::SecurityResolverTest < ActiveSupport::TestCase
  test "reuses the canonical asset when a foreign quoted pair exists" do
    pair = Security.create!(ticker: "BNBBRL", name: "BNB / BRL")
    asset = Security.create!(ticker: "CRYPTO:BNB", name: "BNB", price_provider: "binance_public")
    Security::Resolver.expects(:new).never

    resolved = BinanceAccount::SecurityResolver.resolve("CRYPTO:BNB", "BNB")

    assert_equal asset, resolved
    assert_not_equal pair, resolved
    assert_equal "binance_public", resolved.price_provider
  end

  test "creates a priceable asset without searching trading pairs" do
    Security::Resolver.expects(:new).never

    resolved = BinanceAccount::SecurityResolver.resolve("CRYPTO:ADA", "ADA")

    assert_equal "CRYPTO:ADA", resolved.ticker
    assert_equal "binance_public", resolved.price_provider
    assert_not resolved.offline?
  end
end
