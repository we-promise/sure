require "test_helper"

class Transaction::LabelNormalizerTest < ActiveSupport::TestCase
  ENTRY_DATE = Date.new(2026, 9, 5)

  def normalize(raw, on: ENTRY_DATE)
    Transaction::LabelNormalizer.normalize(raw, on: on)
  end

  test "strips a card prefix and the embedded operation date" do
    result = normalize("CB 02/09 CARREFOUR MARKET")

    assert_equal "CARREFOUR MARKET", result.name
    assert_equal "card", result.rail
    assert_equal Date.new(2026, 9, 2), result.operation_date
  end

  test "strips a SEPA direct debit prefix" do
    result = normalize("PRLV SEPA AMZ PRIME")

    assert_equal "AMZ PRIME", result.name
    assert_equal "direct_debit", result.rail
  end

  test "unwraps a payment aggregator to the real merchant" do
    result = normalize("CB PAYPAL *XYZ")

    assert_equal "XYZ", result.name
    assert_equal "card", result.rail
  end

  test "strips a SEPA transfer prefix in both phrasings" do
    assert_equal "XYZ", normalize("VIR SEPA XYZ").name
    assert_equal "XYZ", normalize("VIREMENT DE XYZ").name
    assert_equal "transfer", normalize("VIR SEPA XYZ").rail
  end

  test "strips a cash withdrawal prefix" do
    result = normalize("RETRAIT DAB 02/09 PARIS OPERA")

    assert_equal "PARIS OPERA", result.name
    assert_equal "withdrawal", result.rail
  end

  test "recognises bank fees" do
    assert_equal "fee", normalize("COMMISSION D INTERVENTION").rail
    assert_equal "fee", normalize("FRAIS TENUE DE COMPTE").rail
    assert_equal "TENUE DE COMPTE", normalize("FRAIS TENUE DE COMPTE").name
  end

  test "keeps the original label when nothing meaningful survives" do
    result = normalize("CHEQUE N 1234567")

    assert_equal "CHEQUE N 1234567", result.name
    assert_equal "cheque", result.rail
  end

  test "resolves a year-less date to the previous year across New Year" do
    result = normalize("CB 30/12 FNAC", on: Date.new(2026, 1, 3))

    assert_equal Date.new(2025, 12, 30), result.operation_date
    assert_equal "FNAC", result.name
  end

  test "reads an explicit year when the label carries one" do
    assert_equal Date.new(2025, 9, 2), normalize("FACTURE CARTE DU 020925 SNCF").operation_date
    assert_equal "SNCF", normalize("FACTURE CARTE DU 020925 SNCF").name
  end

  # Banks are not consistent about the case of the DU token, and the compact
  # variant below already matched case-insensitively. Leaving the slashed one
  # case-sensitive split "CB du 02/09 CARREFOUR" into a payee literally called
  # "du CARREFOUR", away from the same merchant billed in upper case.
  test "strips the DU token whatever its case" do
    %w[du DU Du dU].each do |token|
      result = normalize("CB #{token} 02/09 CARREFOUR")

      assert_equal "CARREFOUR", result.name, "#{token} was not stripped"
      assert_equal Date.new(2026, 9, 2), result.operation_date
    end
  end

  test "returns no operation date when the entry date is unknown" do
    result = normalize("CB 02/09 CARREFOUR", on: nil)

    assert_nil result.operation_date
    assert_equal "CARREFOUR", result.name
  end

  test "leaves a merchant name that merely starts with a prefix letter sequence alone" do
    assert_equal "VIRGIN MEGASTORE", normalize("VIRGIN MEGASTORE").name
    assert_nil normalize("VIRGIN MEGASTORE").rail
    assert_equal "CBD SHOP", normalize("CBD SHOP").name
  end

  test "leaves plain user-entered text untouched" do
    result = normalize("Groceries")

    assert_equal "Groceries", result.name
    assert_nil result.rail
    assert_nil result.operation_date
  end

  test "drops trailing card and contract numbers" do
    assert_equal "MONOPRIX", normalize("CB 02/09 MONOPRIX CARTE 1234567").name
    assert_equal "EDF", normalize("PRLV SEPA EDF REF 998877665544").name
  end

  test "reports whether it changed anything" do
    assert normalize("CB 02/09 CARREFOUR").normalized?("CB 02/09 CARREFOUR")
    assert_not normalize("Groceries").normalized?("Groceries")
  end

  test "handles a blank label without raising" do
    assert_equal "", normalize("").name
    assert_equal "", normalize(nil).name
  end

  test "recognises a refund, which the domain has no other way to express" do
    assert_equal "refund", normalize("AVOIR AMAZON EU").rail
    assert_equal "AMAZON EU", normalize("AVOIR AMAZON EU").name
    assert_equal "refund", normalize("REMBOURSEMENT SNCF").rail
    assert_equal "refund", normalize("ANNULATION CB FNAC").rail
  end

  # A refund that keeps its nested card marker groups as a different payee from
  # the purchase it reverses, which defeats the whole point of normalizing.
  test "a refund reduces to the same merchant as the purchase it reverses" do
    purchase = normalize("CB FNAC")

    assert_equal purchase.name, normalize("ANNULATION CB FNAC").name
    assert_equal purchase.name, normalize("REMBOURSEMENT CARTE FNAC").name
    assert_equal "refund", normalize("ANNULATION CB FNAC").rail
    assert_equal "refund", normalize("REMBOURSEMENT CARTE FNAC").rail
  end

  test "reads a loan instalment as a loan payment, not as a refund" do
    assert_equal "loan_payment", normalize("REMB PRET IMMO").rail
    assert_equal "loan_payment", normalize("ECHEANCE PRET ETUDIANT").rail
    assert_equal "PRET ETUDIANT", normalize("ECHEANCE PRET ETUDIANT").name
  end
end
