require "test_helper"

class Import::AccountSheetDetectorTest < ActiveSupport::TestCase
  setup do
    path = Rails.root.join("test/fixtures/files/imports/sample_bank_export.xlsx")
    @workbook = Import::XlsxWorkbook.open(File.binread(path))
    @detector = Import::AccountSheetDetector.new(@workbook)
  end

  test "detects account sheets from the hidden manifest" do
    sheets = @detector.detected_sheets
    assert_equal 2, sheets.size

    cpt = sheets.find { |s| s.type == :cpt }
    assert_equal "Cpt 02619 00099999901", cpt.sheet_name
    assert_equal "02619 00099999901", cpt.account_number
    assert_equal "0261900099999901", cpt.account_key
    assert_equal "Compte Courant Test", cpt.account_name
    assert_equal "EUR", cpt.currency
    assert_equal 3, cpt.row_count
  end

  test "card sheet shares the account number of its current account" do
    cb = @detector.detected_sheets.find { |s| s.type == :cb }

    assert_equal "CB 02619 00099999901 # 052026", cb.sheet_name
    assert_equal "0261900099999901", cb.account_key
    assert_equal "Compte Courant Test", cb.account_name
  end

  test "parses transactions and skips zero/blank informational rows" do
    cpt = @detector.detected_sheets.find { |s| s.type == :cpt }
    txns = @detector.transactions(cpt)

    assert_equal 2, txns.size # the zero-amount "NOUVEAU TAUX" row is skipped
    assert_equal Date.new(2025, 12, 31), txns.first[:date]
    assert_equal BigDecimal("12.34"), txns.first[:amount]
    assert_equal "INTERETS 2025", txns.first[:name]
    assert_equal "EUR", txns.first[:currency]
  end

  test "parses signed card amounts" do
    cb = @detector.detected_sheets.find { |s| s.type == :cb }
    txns = @detector.transactions(cb)

    assert_equal 3, txns.size
    assert_equal(-23.0, txns.first[:amount].to_f)
    assert_equal "OPENAI CHATGPT", txns.first[:name]
  end
end
