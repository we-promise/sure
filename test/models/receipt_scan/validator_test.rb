require "test_helper"

class ReceiptScan::ValidatorTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @today = Date.new(2026, 11, 16)
  end

  test "clean receipt has no problems" do
    assert_empty problems(date: @today)
  end

  test "missing total" do
    assert_includes reasons(total: nil), "missing_total"
  end

  test "non-positive total" do
    assert_includes reasons(total: BigDecimal("-12.00"), line_items: []), "non_positive_total"
    assert_includes reasons(total: BigDecimal("0"), line_items: []), "non_positive_total"
  end

  test "missing date" do
    assert_includes reasons(date: nil), "missing_date"
  end

  test "future date" do
    assert_includes reasons(date: @today + 1.day), "future_date"
  end

  test "old date" do
    assert_includes reasons(date: @today - 2.years - 1.day), "old_date"
  end

  test "invalid nip" do
    assert_includes reasons(nip: "5260250275"), "invalid_nip"
    assert_not_includes reasons(nip: "5260250274"), "invalid_nip"
  end

  test "items total mismatch" do
    items = [ { "name" => "A", "amount" => "30.00", "discount" => "5.00" }, { "name" => "B", "amount" => "20.00", "discount" => "0" } ]

    problem = problems(line_items: items).find { _1["reason"] == "items_total_mismatch" }

    assert_equal "45.0", problem["items_total"]
    assert_equal "50.0", problem["total"]
  end

  test "items total within a cent is fine" do
    items = [ { "name" => "A", "amount" => "50.01", "discount" => "0" } ]

    assert_not_includes reasons(line_items: items), "items_total_mismatch"
  end

  test "no line items skips the items check" do
    assert_not_includes reasons(line_items: []), "items_total_mismatch"
  end

  test "vat total mismatch" do
    vat = [ { "letter" => "A", "rate" => "23", "net" => "30.00", "vat" => "6.90", "gross" => "36.90" } ]

    assert_includes reasons(vat_breakdown: vat), "vat_total_mismatch"
  end

  test "currency mismatch" do
    assert_includes reasons(currency: "EUR"), "currency_mismatch"
  end

  test "unknown currency" do
    assert_includes reasons(currency: "XYZ"), "unknown_currency"
    assert_includes reasons(currency: nil), "unknown_currency"
  end

  test "valid_nip? checks the checksum" do
    assert ReceiptScan::Validator.valid_nip?("5260250274")
    assert ReceiptScan::Validator.valid_nip?("526-025-02-74")
    assert_not ReceiptScan::Validator.valid_nip?("5260250275")
    assert_not ReceiptScan::Validator.valid_nip?("123")
  end

  private
    def problems(**overrides)
      extraction = build_receipt_extraction(**{ date: @today }.merge(overrides))
      ReceiptScan::Validator.new(extraction, account: @account, today: @today).problems
    end

    def reasons(**overrides)
      problems(**overrides).map { _1["reason"] }
    end
end
