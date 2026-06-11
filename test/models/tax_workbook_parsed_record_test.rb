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

  test "gst outward lines validate known gstr1 table codes" do
    line = GstOutwardLine.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      gstr1_table_code: "NOPE",
      invoice_no: "INV-001",
      invoice_date: Date.new(2026, 4, 10)
    )

    assert_not line.valid?
    assert_includes line.errors[:gstr1_table_code], "is not included in the list"
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

  test "gst3b summaries validate known section codes" do
    summary = Gst3bSummary.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      section_code: "NOPE"
    )

    assert_not summary.valid?
    assert_includes summary.errors[:section_code], "is not included in the list"
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

  test "gst hsn summaries validate known buckets" do
    summary = GstHsnSummary.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      hsn_code: "9983",
      bucket: "NOPE"
    )

    assert_not summary.valid?
    assert_includes summary.errors[:bucket], "is not included in the list"
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

  test "tds challans normalize blank challan ref" do
    challan = TdsChallan.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_quarter: "Q1",
      tan: "MUMR12345A",
      challan_ref: " "
    )

    assert_not challan.valid?
    assert_nil challan.challan_ref
    assert_includes challan.errors[:challan_ref], "can't be blank"
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

  test "tds deductions validate known section codes" do
    deduction = TdsDeduction.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "NOPE"
    )

    assert_not deduction.valid?
    assert_includes deduction.errors[:section_code], "is not included in the list"
  end

  test "parsed records require the import to belong to the same family" do
    other_family = families(:empty)

    [
      GstOutwardLine.new(family: other_family, tax_workbook_import: @import, source_row_number: 2, tax_period_month: Date.new(2026, 4, 1), gstin: "27ABCDE1234F1Z5", gstr1_table_code: "4A", invoice_no: "INV-001", invoice_date: Date.new(2026, 4, 10)),
      Gst3bSummary.new(family: other_family, tax_workbook_import: @import, source_row_number: 2, tax_period_month: Date.new(2026, 4, 1), gstin: "27ABCDE1234F1Z5", section_code: "3.1(a)"),
      GstHsnSummary.new(family: other_family, tax_workbook_import: @import, source_row_number: 2, tax_period_month: Date.new(2026, 4, 1), gstin: "27ABCDE1234F1Z5", hsn_code: "9983", bucket: "B2B"),
      TdsChallan.new(family: other_family, tax_workbook_import: @import, source_row_number: 2, tax_period_quarter: "Q1", tan: "MUMR12345A", challan_ref: "CH-001"),
      TdsDeduction.new(family: other_family, tax_workbook_import: @import, source_row_number: 2, tax_period_month: Date.new(2026, 4, 1), tax_period_quarter: "Q1", deductor_tan: "MUMR12345A", deductee_pan_or_aadhaar: "ABCDE1234F", section_code: "194C")
    ].each do |record|
      assert_not record.valid?, "#{record.class.name} should reject cross-family import"
      assert_includes record.errors[:tax_workbook_import], "must belong to the same family"
    end
  end

  test "tds deductions require challan to match family and import" do
    other_import = TaxWorkbookImport.create!(
      family: @family,
      uploaded_by: users(:family_admin),
      filename: "other-tax-workbook.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      byte_size: 1024,
      checksum: "d" * 64,
      template_version: "2026-06-11",
      status: "pending"
    )
    other_challan = TdsChallan.create!(
      family: @family,
      tax_workbook_import: other_import,
      source_row_number: 2,
      tax_period_quarter: "Q1",
      tan: "MUMR12345A",
      challan_ref: "CH-OTHER"
    )

    deduction = TdsDeduction.new(
      family: @family,
      tax_workbook_import: @import,
      tds_challan: other_challan,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194C"
    )

    assert_not deduction.valid?
    assert_includes deduction.errors[:tds_challan], "must belong to the same tax workbook import"
  end

  test "tds deductions require challan to match family" do
    other_family = families(:empty)
    other_import = TaxWorkbookImport.create!(
      family: other_family,
      uploaded_by: users(:empty),
      filename: "other-family-tax-workbook.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      byte_size: 1024,
      checksum: "e" * 64,
      template_version: "2026-06-11",
      status: "pending"
    )
    other_challan = TdsChallan.create!(
      family: other_family,
      tax_workbook_import: other_import,
      source_row_number: 2,
      tax_period_quarter: "Q1",
      tan: "MUMR12345A",
      challan_ref: "CH-OTHER-FAMILY"
    )

    deduction = TdsDeduction.new(
      family: @family,
      tax_workbook_import: @import,
      tds_challan: other_challan,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194C"
    )

    assert_not deduction.valid?
    assert_includes deduction.errors[:tds_challan], "must belong to the same family"
  end

  test "tds deductions require challan ref to resolve within import" do
    deduction = TdsDeduction.new(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194C",
      challan_ref: "MISSING"
    )

    assert_not deduction.valid?
    assert_includes deduction.errors[:challan_ref], "must match a challan in the same import"
  end

  test "tds deductions normalize blank challan ref" do
    deduction = TdsDeduction.create!(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194C",
      challan_ref: " "
    )

    assert_nil deduction.challan_ref
  end

  test "tds deductions require attached challan to match challan ref" do
    challan = TdsChallan.create!(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_quarter: "Q1",
      tan: "MUMR12345A",
      challan_ref: "CH-MATCH"
    )

    deduction = TdsDeduction.new(
      family: @family,
      tax_workbook_import: @import,
      tds_challan: challan,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194C",
      challan_ref: "CH-DIFFERENT"
    )

    assert_not deduction.valid?
    assert_includes deduction.errors[:tds_challan], "must match challan_ref"
  end

  test "tds challans cannot be destroyed while deductions reference them" do
    challan = TdsChallan.create!(
      family: @family,
      tax_workbook_import: @import,
      source_row_number: 2,
      tax_period_quarter: "Q1",
      tan: "MUMR12345A",
      challan_ref: "CH-RESTRICT"
    )
    TdsDeduction.create!(
      family: @family,
      tax_workbook_import: @import,
      tds_challan: challan,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194C",
      challan_ref: "CH-RESTRICT"
    )

    assert_not challan.destroy
    assert_includes challan.errors[:base], "Cannot delete record because dependent tds deductions exist"
  end
end
