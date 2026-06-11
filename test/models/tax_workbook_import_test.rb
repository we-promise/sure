require "test_helper"

class TaxWorkbookImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "belongs to family and uploader with pending defaults" do
    import = @family.tax_workbook_imports.create!(
      uploaded_by: @user,
      filename: "india-tax-april-2026.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      byte_size: 1024,
      checksum: "b" * 64,
      template_version: "2026-06-11",
      status: "pending"
    )

    assert_equal @family, import.family
    assert_equal @user, import.uploaded_by
    assert import.pending?
    assert_equal({}, import.row_counts)
    assert_equal([], import.validation_errors)
    assert_equal({}, import.metadata)
  end

  test "allows attaching a source workbook" do
    import = tax_workbook_imports(:april_2026)

    import.source_file.attach(
      io: StringIO.new("xlsx-bytes"),
      filename: "india-tax-april-2026.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE
    )

    assert import.source_file.attached?
    assert_equal "india-tax-april-2026.xlsx", import.source_file.filename.to_s
  end

  test "orders newest imports first" do
    older = tax_workbook_imports(:april_2026)
    newer = @family.tax_workbook_imports.create!(
      uploaded_by: @user,
      filename: "india-tax-may-2026.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      byte_size: 2048,
      checksum: "b" * 64,
      template_version: "2026-06-11",
      status: "importing"
    )

    older.update_column(:created_at, 2.days.ago)
    newer.update_column(:created_at, 1.day.ago)

    assert_equal [ newer.id, older.id ], @family.tax_workbook_imports.ordered.limit(2).pluck(:id)
  end

  test "validates workbook metadata" do
    import = @family.tax_workbook_imports.build(
      uploaded_by: @user,
      filename: nil,
      content_type: "text/plain",
      byte_size: 0,
      checksum: "short",
      template_version: nil,
      status: "invalid"
    )

    assert_not import.valid?
    assert_includes import.errors[:filename], "can't be blank"
    assert_includes import.errors[:content_type], "is not included in the list"
    assert_includes import.errors[:byte_size], "must be greater than 0"
    assert_includes import.errors[:checksum], "is the wrong length (should be 64 characters)"
    assert_includes import.errors[:template_version], "can't be blank"
    assert_includes import.errors[:status], "is not included in the list"
  end

  test "validates checksum uniqueness within family" do
    duplicate = @family.tax_workbook_imports.build(
      uploaded_by: @user,
      filename: "duplicate-tax-workbook.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      byte_size: 1024,
      checksum: "a" * 64,
      template_version: "2026-06-11",
      status: "pending"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:checksum], "has already been taken"
  end

  test "requires uploader to belong to import family when present" do
    import = @family.tax_workbook_imports.build(
      uploaded_by: users(:empty),
      filename: "cross-family-tax-workbook.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      byte_size: 1024,
      checksum: "c" * 64,
      template_version: "2026-06-11",
      status: "pending"
    )

    assert_not import.valid?
    assert_includes import.errors[:uploaded_by], "must belong to the same family"
  end

  test "aggregates parsed record totals" do
    import = tax_workbook_imports(:april_2026)

    import.gst_outward_lines.create!(
      family: @family,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      gstr1_table_code: "4A",
      invoice_no: "INV-001",
      invoice_date: Date.new(2026, 4, 10),
      taxable_value: 1000,
      igst: 0,
      cgst: 90,
      sgst_ugst: 90,
      cess: 10
    )

    challan = import.tds_challans.create!(
      family: @family,
      source_row_number: 3,
      tax_period_quarter: "Q1",
      tan: "MUMR12345A",
      challan_ref: "CH-001",
      tax: 150,
      total_amount: 150
    )

    import.tds_deductions.create!(
      family: @family,
      tds_challan: challan,
      source_row_number: 4,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194C",
      amount_paid: 1000,
      tds_amount: 100,
      surcharge: 10,
      cess: 5
    )

    assert_equal BigDecimal("190"), import.gst_tax_total
    assert_equal BigDecimal("1000"), import.gst_taxable_total
    assert_equal BigDecimal("100"), import.tds_total
  end

  test "allows negative gst outward credit note rows" do
    import = tax_workbook_imports(:april_2026)

    line = import.gst_outward_lines.create!(
      family: @family,
      source_row_number: 9,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      gstr1_table_code: "9B",
      invoice_no: "CN-002",
      invoice_date: Date.new(2026, 4, 15),
      is_credit_note: true,
      taxable_value: -500,
      igst: 0,
      cgst: -45,
      sgst_ugst: -45,
      cess: -5
    )

    assert_predicate line, :persisted?
    assert_equal BigDecimal("-500"), line.taxable_value
  end

  test "preserves import when uploader is deleted" do
    user = users(:family_member)
    import = @family.tax_workbook_imports.create!(
      uploaded_by: user,
      filename: "uploader-delete-tax-workbook.xlsx",
      content_type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
      byte_size: 1024,
      checksum: "d" * 64,
      template_version: "2026-06-11",
      status: "pending"
    )

    user.destroy!

    assert_nil import.reload.uploaded_by
  end

  test "destroys parsed records with the import" do
    import = tax_workbook_imports(:april_2026)

    import.gst_outward_lines.create!(
      family: @family,
      source_row_number: 2,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      gstr1_table_code: "4A",
      invoice_no: "INV-002",
      invoice_date: Date.new(2026, 4, 12),
      taxable_value: 500,
      igst: 0,
      cgst: 45,
      sgst_ugst: 45,
      cess: 0
    )

    import.gst3b_summaries.create!(
      family: @family,
      source_row_number: 5,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      section_code: "3.1(a)"
    )

    import.gst_hsn_summaries.create!(
      family: @family,
      source_row_number: 6,
      tax_period_month: Date.new(2026, 4, 1),
      gstin: "27ABCDE1234F1Z5",
      hsn_code: "9983",
      bucket: "B2B"
    )

    challan = import.tds_challans.create!(
      family: @family,
      source_row_number: 7,
      tax_period_quarter: "Q1",
      tan: "MUMR12345A",
      challan_ref: "CH-002",
      tax: 75,
      total_amount: 75
    )

    import.tds_deductions.create!(
      family: @family,
      tds_challan: challan,
      source_row_number: 8,
      tax_period_month: Date.new(2026, 4, 1),
      tax_period_quarter: "Q1",
      deductor_tan: "MUMR12345A",
      deductee_pan_or_aadhaar: "ABCDE1234F",
      section_code: "194J",
      amount_paid: 750,
      tds_amount: 75
    )

    assert_difference [ "GstOutwardLine.count", "Gst3bSummary.count", "GstHsnSummary.count", "TdsChallan.count", "TdsDeduction.count" ], -1 do
      import.destroy
    end
  end
end
