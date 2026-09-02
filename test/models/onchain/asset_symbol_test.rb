# frozen_string_literal: true

require "test_helper"

class Onchain::AssetSymbolTest < ActiveSupport::TestCase
  test "strips bridge suffixes" do
    assert_equal "USDC", Onchain::AssetSymbol.canonical("USDC.e")
    assert_equal "BTC", Onchain::AssetSymbol.canonical("BTC.b")
    assert_equal "DAI", Onchain::AssetSymbol.canonical("dai.e")
  end

  test "maps bridged and wrapped aliases to their canonical asset" do
    assert_equal "USDT", Onchain::AssetSymbol.canonical("USDT0")
    assert_equal "USDC", Onchain::AssetSymbol.canonical("USDbC")
    assert_equal "ETH", Onchain::AssetSymbol.canonical("weth")
    assert_equal "POL", Onchain::AssetSymbol.canonical("WMATIC")
  end

  test "leaves an unknown symbol alone apart from case and whitespace" do
    assert_equal "PEPE", Onchain::AssetSymbol.canonical(" pepe ")
    assert_equal "", Onchain::AssetSymbol.canonical(nil)
  end
end
