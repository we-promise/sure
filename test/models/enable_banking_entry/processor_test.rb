require "test_helper"

class EnableBankingEntry::ProcessorTest < ActiveSupport::TestCase
  def build_name(data)
    processor = EnableBankingEntry::Processor.new(data, enable_banking_account: Object.new)
    processor.send(:name)
  end

  test "skips technical card counterparty and falls back to bank tx description" do
    name = build_name(
      credit_debit_indicator: "CRDT",
      debtor_name: "CARD-1234",
      remittance_information: [ "ACME SHOP" ],
      bank_transaction_code: { description: "Card Purchase" }
    )

    assert_equal "Card Purchase", name
  end

  test "uses counterparty when it is human readable" do
    name = build_name(
      credit_debit_indicator: "CRDT",
      debtor_name: "ACME SHOP",
      remittance_information: [ "Receipt #42" ],
      bank_transaction_code: { description: "Transfer" }
    )

    assert_equal "ACME SHOP", name
  end
end
