require "test_helper"

class BankExternalAccountProcessorDedupeTest < ActiveSupport::TestCase
  class StubMapper < Provider::Banks::Mapper
    def normalize_transaction(payload, currency:)
      data = payload.symbolize_keys
      { external_id: "dup_#{data[:id]}", posted_at: Date.parse("2025-01-01"), amount: BigDecimal("1.0"), description: "Test" }
    end
  end

  setup do
    @family = families(:dylan_family)
    @conn = @family.bank_connections.create!(name: "Test", provider: :test, credentials: { x: 1 }.to_json)
    @ext = @conn.bank_external_accounts.create!(provider_account_id: "p1", name: "Ext", currency: "USD", current_balance: 0)

    # Create internal account and link
    @account = Account.create!(
      family: @family,
      name: "Checking",
      balance: 0,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: { subtype: "checking" },
      bank_external_account: @ext
    )
  end

  test "processor is idempotent by external_id" do
    @ext.update!(raw_transactions_payload: [ { id: "1" }, { id: "1" } ])
    processor = BankExternalAccount::Processor.new(@ext, mapper: StubMapper.new)

    assert_difference -> { Entry.count }, +1 do
      processor.process
    end

    # Running again should not create duplicates
    assert_no_difference -> { Entry.count } do
      processor.process
    end
  end
end
