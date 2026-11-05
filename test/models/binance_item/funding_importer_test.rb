# frozen_string_literal: true

require "test_helper"

class BinanceItem::FundingImporterTest < ActiveSupport::TestCase
  test "includes free locked frozen and withdrawing units without zero assets" do
    provider = mock
    provider.expects(:get_funding_account).returns([
      { "asset" => "USDT", "free" => "1", "locked" => "2", "freeze" => "3", "withdrawing" => "4" },
      { "asset" => "BTC", "free" => "0" }
    ])

    result = BinanceItem::FundingImporter.new(nil, provider: provider).import

    assert_equal "funding", result[:source]
    assert_equal [ { symbol: "USDT", free: "1.0", locked: "9.0", total: "10.0" } ], result[:assets]
    assert_nil result[:error]
  end

  test "distinguishes a failed request from an empty funding wallet" do
    provider = mock
    provider.expects(:get_funding_account).raises(Provider::Binance::ApiError, "Unavailable")

    result = BinanceItem::FundingImporter.new(nil, provider: provider).import

    assert_equal "Unavailable", result[:error]
    assert_empty result[:assets]
  end
end
