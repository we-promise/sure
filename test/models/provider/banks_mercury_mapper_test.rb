require "test_helper"

class ProviderBanksMercuryMapperTest < ActiveSupport::TestCase
  test "normalizes mercury account payload" do
    mapper = Provider::Banks::Mercury::Mapper.new
    payload = {
      id: "acc0",
      name: "Operating",
      currency: "USD",
      balances: { current: 120.5, available: 100.25 }
    }

    acc = mapper.normalize_account(payload)
    assert_equal "acc0", acc[:provider_account_id]
    assert_equal "Operating", acc[:name]
    assert_equal "USD", acc[:currency]
    assert_equal BigDecimal("120.5"), acc[:current_balance]
    assert_equal BigDecimal("100.25"), acc[:available_balance]
  end

  test "normalizes mercury transaction payload with direction" do
    mapper = Provider::Banks::Mercury::Mapper.new
    debit_payload = { id: "t1", amount: 10.0, date: "2025-01-02", description: "ACH", direction: "debit" }
    credit_payload = { id: "t2", amount: 7.5, date: "2025-01-03", description: "Refund", direction: "credit" }

    t1 = mapper.normalize_transaction(debit_payload, currency: "USD")
    t2 = mapper.normalize_transaction(credit_payload, currency: "USD")

    assert_equal BigDecimal("10.0"), t1[:amount]
    assert_equal BigDecimal("-7.5"), t2[:amount]
    assert_equal Date.parse("2025-01-02"), t1[:posted_at]
    assert_equal Date.parse("2025-01-03"), t2[:posted_at]
  end
end

