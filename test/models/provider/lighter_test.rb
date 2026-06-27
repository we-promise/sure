require "test_helper"

class Provider::LighterTest < ActiveSupport::TestCase
  test "totals account values across every sub account for an l1 address" do
    provider = Provider::Lighter.new

    stub_request(:get, "https://mainnet.zklighter.elliot.ai/api/v1/accountsByL1Address")
      .with(query: { l1_address: "0xabc" })
      .to_return(status: 200, body: {
        sub_accounts: [
          { index: 12 },
          { index: 18 }
        ]
      }.to_json, headers: { "Content-Type" => "application/json" })

    stub_request(:get, "https://mainnet.zklighter.elliot.ai/api/v1/account")
      .with(query: hash_including("by" => "index", "value" => "12"))
      .to_return(status: 200, body: {
        accounts: [ {
          collateral: "500.00",
          total_asset_value: "515.50",
          positions: [ { unrealized_pnl: "15.50" } ]
        } ]
      }.to_json, headers: { "Content-Type" => "application/json" })

    stub_request(:get, "https://mainnet.zklighter.elliot.ai/api/v1/account")
      .with(query: hash_including("by" => "index", "value" => "18"))
      .to_return(status: 200, body: {
        accounts: [ {
          collateral: "300.00",
          total_asset_value: "290.25",
          positions: [ { unrealized_pnl: "-9.75" } ]
        } ]
      }.to_json, headers: { "Content-Type" => "application/json" })

    result = provider.total_account_value_for_l1_address("0xabc")

    assert_equal BigDecimal("805.75"), result[:total_account_value]
    assert_equal BigDecimal("800.00"), result[:total_collateral]
    assert_equal BigDecimal("5.75"), result[:total_unrealized_pnl]
    assert_equal 2, result[:accounts].size
  end
end
