require "test_helper"

class YnabImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  setup do
    @subject = @import = imports(:ynab)
  end

  test "auto-configures column mappings on create" do
    import = Import.create!(
      type: "YnabImport",
      family: families(:dylan_family)
    )

    assert_equal "Date", import.date_col_label
    assert_equal "%m/%d/%Y", import.date_format
    assert_equal "Payee", import.name_col_label
    assert_equal "Account", import.account_col_label
    assert_equal "Category", import.category_col_label
    assert_equal "Memo", import.notes_col_label
    assert_equal "inflows_negative", import.signage_convention
  end

  test "computes signed amount from outflow and inflow columns" do
    import = load_ynab_import

    rows = import.rows.order(:date)

    # Outflow $78.32 → positive (expense in Sure)
    assert_equal "78.32", rows[0].amount

    # Inflow $2,500.00 → negative (income in Sure)
    assert_equal "-2500.0", rows[1].amount

    # Outflow $4.25 → positive
    assert_equal "4.25", rows[2].amount

    # Outflow $200.00 (transfer)
    assert_equal "200.0", rows[3].amount
  end

  test "maps payee to name and memo to notes" do
    import = load_ynab_import

    rows = import.rows.order(:date)

    assert_equal "Grocery Store", rows[0].name
    assert_equal "Weekly groceries", rows[0].notes
    assert_equal "ACME Corp", rows[1].name
    assert_equal "Bi-weekly paycheck", rows[1].notes
  end

  test "maps category and account columns" do
    import = load_ynab_import

    rows = import.rows.order(:date)

    assert_equal "Groceries", rows[0].category
    assert_equal "Checking", rows[0].account
    assert_equal "Salary", rows[1].category
    assert_equal "Checking", rows[1].account
    assert_equal "Dining Out", rows[2].category
    assert_equal "Credit Card", rows[2].account
  end

  test "imports full YNAB export with accounts, categories, and transactions" do
    import = load_ynab_import

    # Set up mappings
    import.mappings.create! key: "Groceries", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Salary", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Dining Out", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "", create_when_empty: false, mappable: nil, type: "Import::CategoryMapping"
    import.mappings.create! key: "Checking", mappable: accounts(:depository), type: "Import::AccountMapping"
    import.mappings.create! key: "Credit Card", mappable: accounts(:credit_card), type: "Import::AccountMapping"

    assert_difference "Entry.count", 4 do
      import.publish
    end

    assert import.complete?
  end

  test "handles amounts with dollar signs and comma separators" do
    configure_ynab_mappings(@import)

    csv = <<~CSV
      "Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
      "Checking","","01/15/2024","Large Purchase","Bills: Rent","Bills","Rent","Monthly rent","$1,250.00","$0.00","Cleared"
      "Checking","","01/16/2024","Employer","Income: Salary","Income","Salary","Paycheck","$0.00","$5,432.10","Cleared"
    CSV

    @import.update!(raw_file_str: csv)
    @import.generate_rows_from_csv
    @import.reload

    rows = @import.rows.order(:date)

    assert_equal "1250.0", rows[0].amount
    assert_equal "-5432.1", rows[1].amount
  end

  test "handles rows where both outflow and inflow are zero" do
    configure_ynab_mappings(@import)

    csv = <<~CSV
      "Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
      "Checking","","01/15/2024","Zero Transaction","","","","Test","$0.00","$0.00","Cleared"
    CSV

    @import.update!(raw_file_str: csv)
    @import.generate_rows_from_csv
    @import.reload

    assert_equal "0.0", @import.rows.first.amount
  end

  private
    def configure_ynab_mappings(import)
      import.update!(
        date_col_label: "Date",
        date_format: "%m/%d/%Y",
        name_col_label: "Payee",
        amount_col_label: "Outflow",
        account_col_label: "Account",
        category_col_label: "Category",
        notes_col_label: "Memo",
        signage_convention: "inflows_negative"
      )
    end

    def load_ynab_import
      configure_ynab_mappings(@import)
      csv_content = file_fixture("imports/ynab.csv").read
      @import.update!(raw_file_str: csv_content)
      @import.generate_rows_from_csv
      @import.reload
      @import
    end
end
