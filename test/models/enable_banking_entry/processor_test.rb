require "test_helper"
require "ostruct"

class EnableBankingEntry::ProcessorTest < ActiveSupport::TestCase
  def build_name(data)
    processor = EnableBankingEntry::Processor.new(data, enable_banking_account: OpenStruct.new)
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

  test "prefers remittance merchant when card reference counterparty is technical" do
    name = build_name(
      credit_debit_indicator: "CRDT",
      debtor_name: "CARD-1234",
      remittance_information: [ "ACME SHOP" ],
      bank_transaction_code: { description: "Card Purchase" }
    )

    assert_equal "ACME SHOP", name
  end

  test "uses descriptive remittance when description is a technical reference code" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      description: "C18W26037W001080",
      remittance_information: [
        "VIR SEPA TRAVAUX AGRIS 26-01-0024",
        "C18W26037W001080"
      ]
    )

    assert_equal "VIR SEPA TRAVAUX AGRIS 26-01-0024", name
  end

  test "uses merchant segment from remittance when description is card reference" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      description: "CARD-3419406613",
      remittance_information: [
        "Card transaction of EUR issued by Amzn Mktp Fr*Mkudamazonfr"
      ]
    )

    assert_equal "Amzn Mktp Fr*Mkudamazonfr", name
  end

  test "skips technical remittance line and keeps issued by merchant line" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      description: "CARD-3403900155",
      remittance_information: [
        "CARD-3403900155",
        "Card transaction of EUR issued by Boulangerie Bric CROIX"
      ]
    )

    assert_equal "Boulangerie Bric CROIX", name
  end

  test "extracts merchant when remittance uses paid to wording" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      description: "CARD-3403900155",
      remittance_information: [
        "Card transaction of EUR paid to Local Bakery"
      ]
    )

    assert_equal "Local Bakery", name
  end

  test "keeps specific description when remittance is less informative" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      description: "Monthly Membership",
      remittance_information: [ "PAYMENT" ]
    )

    assert_equal "Monthly Membership", name
  end

  test "keeps merchant description when remittance is a technical operation header" do
    name = build_name(
      credit_debit_indicator: "DBIT",
      description: "EMINZA",
      remittance_information: [ "CARD PAYMENT 02/01 59100 ROUBAIX" ]
    )

    assert_equal "EMINZA", name
  end
end
