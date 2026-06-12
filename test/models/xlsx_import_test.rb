require "test_helper"

class XlsxImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FIXTURE = "test/fixtures/files/imports/sample_bank_export.xlsx".freeze
  ACCOUNT_KEY = "0261900099999901".freeze

  setup do
    @family = families(:dylan_family)
    @import = XlsxImport.create!(family: @family, date_format: "%Y-%m-%d")
    @import.xlsx_file.attach(
      io: File.open(Rails.root.join(FIXTURE)),
      filename: "sample_bank_export.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end

  test "uploaded? reflects the attachment" do
    assert @import.uploaded?
  end

  test "detected_sheets reads the two account sheets" do
    assert_equal 2, @import.detected_sheets.size
  end

  test "suggested_account_for matches an existing account by external_account_number" do
    cpt = @import.detected_sheets.find { |s| s.type == :cpt }
    assert_nil @import.suggested_account_for(cpt)

    account = @family.accounts.create!(
      name: "Existing", balance: 0, currency: "EUR",
      accountable: Depository.new, external_account_number: ACCOUNT_KEY
    )

    assert_equal account, @import.suggested_account_for(cpt)
  end

  test "apply_sheet_selections creates a new account, persists the RIB, and generates rows" do
    cpt = @import.detected_sheets.find { |s| s.type == :cpt }
    selections = [
      { "sheet_name" => cpt.sheet_name, "selected" => "1", "account_id" => "new", "account_name" => "My Checking" }
    ]

    assert_difference -> { @family.accounts.count }, 1 do
      @import.apply_sheet_selections!(selections)
    end

    account = @family.accounts.find_by(external_account_number: ACCOUNT_KEY)
    assert_equal "My Checking", account.name
    assert_equal "EUR", account.currency
    assert_equal 2, @import.rows_count # the zero-amount row is skipped
    assert @import.rows.all? { |row| row.account == account.id }
  end

  test "unchecked sheets are not imported" do
    selections = @import.detected_sheets.map do |sheet|
      { "sheet_name" => sheet.sheet_name, "selected" => (sheet.type == :cpt ? "1" : "0"), "account_id" => "new" }
    end

    @import.apply_sheet_selections!(selections)

    # Only the cpt sheet (2 non-zero rows) is imported; the cb sheet is skipped.
    assert_equal 2, @import.rows_count
  end

  test "mapping to an existing account backfills its external_account_number" do
    account = @family.accounts.create!(name: "Existing", balance: 0, currency: "EUR", accountable: Depository.new)
    cpt = @import.detected_sheets.find { |s| s.type == :cpt }

    @import.apply_sheet_selections!([
      { "sheet_name" => cpt.sheet_name, "selected" => "1", "account_id" => account.id }
    ])

    assert_equal ACCOUNT_KEY, account.reload.external_account_number
    assert_equal 2, @import.rows_count
  end

  test "publish imports transactions into the mapped account" do
    cpt = @import.detected_sheets.find { |s| s.type == :cpt }
    @import.apply_sheet_selections!([
      { "sheet_name" => cpt.sheet_name, "selected" => "1", "account_id" => "new", "account_name" => "Checking FR" }
    ])

    account = @family.accounts.find_by(external_account_number: ACCOUNT_KEY)

    assert_difference -> { account.entries.count }, 2 do
      @import.publish
    end

    assert @import.complete?
  end

  test "import flow hooks" do
    assert_equal %i[date name amount currency], @import.column_keys
    assert_empty @import.mapping_steps
    assert_not @import.requires_csv_workflow?
  end
end
