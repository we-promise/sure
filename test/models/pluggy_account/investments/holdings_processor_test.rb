require "test_helper"

# Pluggy's investments payload never sends a `price` field. The per-unit
# price is `value` (verified: quantity * value == amount for both stocks and
# fixed-income). Fixed-income holdings (CDB/LCI/LCA) carry no `code` or `isin`
# either -- only a unique holding `id` and a shared `name`/`issuer`. See
# app/models/pluggy_account/investments/holdings_processor.rb.
class PluggyAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  test "imports a tickered holding using value as the unit price and the payload amount" do
    recorded = []
    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:import_holding) { |**opts| recorded << opts; true }
    fake_account = OpenStruct.new(currency: "BRL", holdings: [])

    acct = pluggy_accounts(:one)
    acct.stubs(:current_account).returns(fake_account)
    acct.stubs(:account_provider).returns(OpenStruct.new(id: 42))
    acct.stubs(:raw_holdings_payload).returns([
      { "id" => "k1", "code" => "KNCR11", "isin" => "BRKNCRCTF000",
        "quantity" => 10, "value" => 107.6, "amount" => 1076, "currencyCode" => "BRL" }
    ])
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:import_adapter).returns(fake_adapter)
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:resolve_security).returns(securities(:aapl))

    PluggyAccount::Investments::HoldingsProcessor.new(acct).process

    assert_equal 1, recorded.size, "tickered holding (value, no price) should be imported"
    assert_equal 10, recorded.first[:quantity]
    assert_in_delta 107.6, recorded.first[:price], 0.0001, "price should come from value, not the absent price field"
    assert_in_delta 1076, recorded.first[:amount], 0.01, "amount should come from the payload"
    assert_equal "pluggy", recorded.first[:source]
    assert_equal 42, recorded.first[:account_provider_id]
  end

  test "imports a ticker-less fixed-income CDB using its holding id as the security ticker" do
    recorded = []
    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:import_holding) { |**opts| recorded << opts; true }
    fake_account = OpenStruct.new(currency: "BRL", holdings: [])

    acct = pluggy_accounts(:one)
    acct.stubs(:current_account).returns(fake_account)
    acct.stubs(:account_provider).returns(OpenStruct.new(id: 42))
    # code AND isin are both nil -- only the per-holding `id` identifies it.
    # If gate 1 still required a code/isin, recorded.size would stay 0.
    acct.stubs(:raw_holdings_payload).returns([
      { "id" => "cdb-a38a", "code" => nil, "isin" => nil,
        "name" => "CDB BANCO", "subtype" => "CDB", "type" => "FIXED_INCOME",
        "quantity" => 100, "value" => 10, "amount" => 1005, "currencyCode" => "BRL",
        "status" => "ACTIVE" }
    ])
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:import_adapter).returns(fake_adapter)
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:resolve_security).returns(securities(:aapl))

    PluggyAccount::Investments::HoldingsProcessor.new(acct).process

    assert_equal 1, recorded.size, "ticker-less CDB with a holding id should be imported"
    assert_equal 100, recorded.first[:quantity]
    assert_in_delta 10, recorded.first[:price], 0.0000001
    assert_in_delta 1005, recorded.first[:amount], 0.001, "amount should come from the payload, not qty*value"
    assert_equal "pluggy", recorded.first[:source]
  end

  test "skips a holding with no code, isin, or holding id" do
    fake_adapter = OpenStruct.new(import_holding: ->(**) { raise "should not call" })
    acct = pluggy_accounts(:one)
    acct.stubs(:current_account).returns(OpenStruct.new(currency: "BRL", holdings: []))
    acct.stubs(:raw_holdings_payload).returns([ { "quantity" => 100, "value" => 10 } ])
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:import_adapter).returns(fake_adapter)
    assert_nothing_raised { PluggyAccount::Investments::HoldingsProcessor.new(acct).process }
  end

  test "skips a holding with no unit price (no value and no price)" do
    fake_adapter = OpenStruct.new(import_holding: ->(**) { raise "should not call" })
    acct = pluggy_accounts(:one)
    acct.stubs(:current_account).returns(OpenStruct.new(currency: "BRL", holdings: []))
    acct.stubs(:raw_holdings_payload).returns([
      { "id" => "noprice", "code" => "ZZZZ", "quantity" => 5, "currencyCode" => "BRL" }
    ])
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:import_adapter).returns(fake_adapter)
    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:resolve_security).returns(securities(:aapl))
    assert_nothing_raised { PluggyAccount::Investments::HoldingsProcessor.new(acct).process }
  end
end
