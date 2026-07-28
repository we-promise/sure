require "test_helper"

class PluggyAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  test "process imports a holding using code as ticker" do
    recorded = []
    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:import_holding) { |**opts| recorded << opts; true }
    fake_account = OpenStruct.new(currency: "BRL", holdings: [])

    acct = pluggy_accounts(:one)
    acct.stubs(:current_account).returns(fake_account)
    acct.stubs(:account_provider).returns(OpenStruct.new(id: 42))
    acct.stubs(:raw_holdings_payload).returns([
      { "id" => "inv1", "code" => "PETR4", "quantity" => 100, "price" => 30.5, "currencyCode" => "BRL" }
    ])
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:import_adapter).returns(fake_adapter)
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:resolve_security).returns(securities(:aapl))

    PluggyAccount::Investments::HoldingsProcessor.new(acct).process

    assert_equal 1, recorded.size
    assert_equal securities(:aapl), recorded.first[:security]
    assert_equal 100, recorded.first[:quantity]
    assert_equal 30.5, recorded.first[:price]
    assert_equal "pluggy", recorded.first[:source]
    assert_equal 42, recorded.first[:account_provider_id]
  end

  test "process skips holding without code or isin" do
    fake_adapter = OpenStruct.new(import_holding: ->(**) { raise "should not call" })
    acct = pluggy_accounts(:one)
    acct.stubs(:current_account).returns(OpenStruct.new(currency: "BRL", holdings: []))
    acct.stubs(:raw_holdings_payload).returns([ { "quantity" => 100, "price" => 10 } ])
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:import_adapter).returns(fake_adapter)
    assert_nothing_raised { PluggyAccount::Investments::HoldingsProcessor.new(acct).process }
  end
end
