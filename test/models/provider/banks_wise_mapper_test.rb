require "test_helper"

class ProviderBanksWiseMapperTest < ActiveSupport::TestCase
  test "normalizes wise account payload" do
    mapper = Provider::Banks::Wise::Mapper.new
    payload = {
      id: 123,
      name: nil,
      amount: { value: 150.25, currency: "USD" }
    }

    acc = mapper.normalize_account(payload)
    assert_equal "123", acc[:provider_account_id]
    assert_equal "Wise USD Account", acc[:name]
    assert_equal "USD", acc[:currency]
    assert_equal BigDecimal("150.25"), acc[:current_balance]
    assert_equal BigDecimal("150.25"), acc[:available_balance]
  end

  test "normalizes wise transaction payload and flips sign" do
    mapper = Provider::Banks::Wise::Mapper.new
    payload = {
      id: "tx_1",
      amount: { value: 10.5, currency: "USD" },
      date: "2024-01-05T00:00:00Z",
      details: { description: "Coffee Shop" }
    }

    tx = mapper.normalize_transaction(payload, currency: "USD")
    assert_equal "wise_tx_1", tx[:external_id]
    assert_equal Date.parse("2024-01-05"), tx[:posted_at]
    assert_equal BigDecimal("-10.5"), -tx[:amount] # ensure sign flipped
    assert_equal "Coffee Shop", tx[:description]
  end
end

