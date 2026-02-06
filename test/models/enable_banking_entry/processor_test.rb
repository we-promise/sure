require "test_helper"

class EnableBankingEntry::ProcessorTest < ActiveSupport::TestCase
  def build_name(data)
    processor = EnableBankingEntry::Processor.new(data, enable_banking_account: Object.new)
    processor.send(:name)
  end

  test "uses remittance merchant when description is generic card payment" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      description: "PAIEMENT CB  0202 59100 ROUBAIX",
      remittance_information: [
        "PAIEMENT CB  0202 59100 ROUBAIX",
        "LA REDOUTE       CARTE 8496"
      ]
    )

    assert_equal "LA REDOUTE", name
  end

  test "keeps explicit counterparty name" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      creditor_name: "EDF",
      remittance_information: [ "FACTURE JANVIER" ]
    )

    assert_equal "EDF", name
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
end
