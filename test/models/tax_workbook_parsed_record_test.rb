require "test_helper"

class TaxWorkbookParsedRecordTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @import = tax_workbook_imports(:april_2026)
  end

  test "gst outward lines validate required fields, identifier lengths, and nonnegative amounts" do
    line = GstOutwardLine.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 0,
      tax_period_month: nil,
      gstin: "X" * 16,
      gstr1_table_code: nil,
      invoice_no: nil,
      invoice_date: nil,
      taxable_value: -1,
      igst: -1,
      cgst: 0,
      sgst_ugst: 0,
      cess: 0
    )

    assert_not line.valid?
    assert_includes line.errors[:source_row_number], "must be greater than 0"
    assert_includes line.errors[:tax_period_month], "can't be blank"
    assert_includes line.errors[:gstin], "is too long (maximum is 15 characters)"
    assert_includes line.errors[:gstr1_table_code], "can't be blank"
    assert_includes line.errors[:invoice_no], "can't be blank"
    assert_includes line.errors[:invoice_date], "can't be blank"
    assert_includes line.errors[:taxable_value], "must be greater than or equal to 0"
    assert_includes line.errors[:igst], "must be greater than or equal to 0"
  end

  test "gst3b summaries require section codes and valid gstin length" do
    summary = Gst3bSummary.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 0,
      tax_period_month: nil,
      gstin: "X" * 16,
      section_code: nil
    )

    assert_not summary.valid?
    assert_includes summary.errors[:source_row_number], "must be greater than 0"
    assert_includes summary.errors[:tax_period_month], "can't be blank"
    assert_includes summary.errors[:gstin], "is too long (maximum is 15 characters)"
    assert_includes summary.errors[:section_code], "can't be blank"
  end

  test "gst hsn summaries require bucket and valid gstin length" do
    summary = GstHsnSummary.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 0,
      tax_period_month: nil,
      gstin: "X" * 16,
      hsn_code: nil,
      bucket: nil
    )

    assert_not summary.valid?
    assert_includes summary.errors[:source_row_number], "must be greater than 0"
    assert_includes summary.errors[:tax_period_month], "can't be blank"
    assert_includes summary.errors[:gstin], "is too long (maximum is 15 characters)"
    assert_includes summary.errors[:hsn_code], "can't be blank"
    assert_includes summary.errors[:bucket], "can't be blank"
  end

  test "tds challans require quarter identifiers and nonnegative totals" do
    challan = TdsChallan.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 0,
      tax_period_quarter: nil,
      tan: "X" * 11,
      challan_ref: nil,
      total_amount: -1
    )

    assert_not challan.valid?
    assert_includes challan.errors[:source_row_number], "must be greater than 0"
    assert_includes challan.errors[:tax_period_quarter], "can't be blank"
    assert_includes challan.errors[:tan], "is too long (maximum is 10 characters)"
    assert_includes challan.errors[:challan_ref], "can't be blank"
    assert_includes challan.errors[:total_amount], "must be greater than or equal to 0"
  end

  test "tds deductions require tax identifiers and nonnegative amounts" do
    deduction = TdsDeduction.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 0,
      tax_period_month: nil,
      tax_period_quarter: nil,
      deductor_tan: "X" * 11,
      deductee_pan_or_aadhaar: nil,
      section_code: nil,
      amount_paid: -1,
      tds_amount: -1
    )

    assert_not deduction.valid?
    assert_includes deduction.errors[:source_row_number], "must be greater than 0"
    assert_includes deduction.errors[:tax_period_month], "can't be blank"
    assert_includes deduction.errors[:tax_period_quarter], "can't be blank"
    assert_includes deduction.errors[:deductor_tan], "is too long (maximum is 10 characters)"
    assert_includes deduction.errors[:deductee_pan_or_aadhaar], "can't be blank"
    assert_includes deduction.errors[:section_code], "can't be blank"
    assert_includes deduction.errors[:amount_paid], "must be greater than or equal to 0"
    assert_includes deduction.errors[:tds_amount], "must be greater than or equal to 0"
  end
end
