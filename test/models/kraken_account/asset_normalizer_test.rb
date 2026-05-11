# frozen_string_literal: true

require "test_helper"

class KrakenAccount::AssetNormalizerTest < ActiveSupport::TestCase
  test "normalizes kraken symbols through metadata and fallbacks" do
    normalizer = KrakenAccount::AssetNormalizer.new(
      "XXBT" => { "altname" => "XBT" },
      "XETH" => { "altname" => "ETH" },
      "ZUSD" => { "altname" => "USD" }
    )

    assert_equal "BTC", normalizer.normalize("XXBT")[:symbol]
    assert_equal "ETH", normalizer.normalize("XETH")[:symbol]
    assert_equal "USD", normalizer.normalize("ZUSD")[:symbol]
  end

  test "preserves kraken suffix variants while pricing base asset" do
    normalizer = KrakenAccount::AssetNormalizer.new("XETH" => { "altname" => "ETH" })

    parsed = normalizer.normalize("XETH.F")

    assert_equal "ETH.F", parsed[:symbol]
    assert_equal "ETH", parsed[:price_symbol]
    assert_equal ".F", parsed[:suffix]
    assert_equal "XETH", parsed[:raw_base]
  end
end
