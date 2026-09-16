# The ingestion value contract can be used without Rails or a provider namespace.
require "minitest/autorun"
require_relative "../../../app/models/ingestion/record"

class Ingestion::RecordTest < Minitest::Test
  def test_file_import_values_share_the_financial_contract
    record = Ingestion::Record.transaction(
      external_id: "csv-row-12", name: "Groceries", amount: BigDecimal("12.34"),
      currency: "USD", date: Date.new(2026, 9, 14), pending: false,
      metadata: { "import" => { "row" => 12 } }
    )

    assert_equal "transaction", record.kind
    assert_equal BigDecimal("12.34"), record[:amount]
    assert_equal 12, record[:metadata]["import"]["row"]
    assert record.frozen?
    assert_raises(FrozenError) { record[:metadata]["import"]["row"] = 13 }
  end

  def test_source_metadata_retains_typed_normalization_hints
    metadata = {
      "notes" => "shared import note",
      "kind" => "transfer",
      "merchant" => { "external_id" => "merchant-1", "name" => "Shop" },
      "extra" => { "source" => { "fx_from" => "EUR", "pending" => false } }
    }
    record = Ingestion::Record.transaction(
      external_id: "stable-source-id", name: "Purchase", amount: BigDecimal("5"),
      currency: "USD", date: Date.new(2026, 9, 14), pending: false, metadata: metadata
    )
    metadata["merchant"]["name"].replace("changed")

    assert_equal "Shop", record[:metadata]["merchant"]["name"]
    assert_equal false, record[:metadata]["extra"]["source"]["pending"]
    refute_includes record.inspect, "shared import note"
  end

  def test_activity_meaning_and_ledger_representation_are_independent
    attributes = { external_id: "distribution", name: "Dividend", currency: "USD", date: Date.new(2026, 9, 14),
      amount: BigDecimal("0"), activity_type: "dividend" }
    assert_equal "transaction", Ingestion::Record.activity(**attributes).ledger_type
    assert_equal "trade", Ingestion::Record.activity(**attributes, ledger_type: "trade").ledger_type
    assert_raises(ArgumentError) { Ingestion::Record.activity(**attributes, ledger_type: "Valuation") }
  end
end
