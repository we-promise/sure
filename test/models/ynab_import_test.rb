require "test_helper"

class YnabImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "default column mappings are applied after create" do
    import = @family.imports.create!(type: "YnabImport")

    YnabImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
  end

  test "generated rows preserve stable source row numbers" do
    import = ynab_import(file_fixture("imports/ynab.csv").read)
    import.generate_rows_from_csv

    assert_equal (1..5).to_a, import.rows.order(:source_row_number).pluck(:source_row_number)
  end

  test "outflow becomes a positive (expense) amount and inflow a negative (income) amount" do
    import = ynab_import(file_fixture("imports/ynab.csv").read)
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    # Row 1 is a pure outflow (rent): an expense, stored positive in Sure's convention
    assert_equal BigDecimal("1500"), rows.first.signed_amount
    # Row 3 is a pure inflow (paycheck): income, stored negative in Sure's convention
    assert_equal BigDecimal("-2500"), rows.third.signed_amount
  end

  test "strips currency symbols and thousands separators from outflow/inflow" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo,Outflow,Inflow
      Checking,02/01/2024,Big Bill,Bills: Utilities,Quarterly,"$1,234.56",
      Checking,02/02/2024,Refund,Income: Refund,,,"$1,000.00"
    CSV
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal BigDecimal("1234.56"), rows.first.signed_amount
    assert_equal BigDecimal("-1000"), rows.second.signed_amount
  end

  test "combines the category group and category from the single YNAB column" do
    import = ynab_import(file_fixture("imports/ynab.csv").read)
    import.generate_rows_from_csv

    assert_equal "Housing: Rent", import.rows.order(:source_row_number).first.category
  end

  test "composes separate Category Group and Category columns" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group,Category,Memo,Outflow,Inflow
      Checking,03/01/2024,Store,Food,Groceries,Weekly,42.00,0.00
      Checking,03/02/2024,Misc,Food,,No category,5.00,0.00
    CSV
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal "Food: Groceries", rows.first.category
    assert_equal "Food", rows.second.category
  end

  test "composes legacy YNAB 4 Master Category and Sub Category columns" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category,Master Category,Sub Category,Memo,Outflow,Inflow
      Checking,03/10/2024,Store,Everyday Expenses: Groceries,Everyday Expenses,Groceries,Weekly,42.00,0.00
      Checking,03/11/2024,Misc,Everyday Expenses,Everyday Expenses,,No sub,5.00,0.00
    CSV
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal "Everyday Expenses: Groceries", rows.first.category
    assert_equal "Everyday Expenses", rows.second.category
  end

  test "a single signed Amount column takes precedence over outflow/inflow" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo,Amount
      Checking,04/01/2024,Employer,Income: Salary,Paycheck,2000.00
      Checking,04/02/2024,Store,Food: Groceries,Weekly,-50.00
    CSV
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal BigDecimal("-2000"), rows.first.signed_amount  # inflow positive -> income negative
    assert_equal BigDecimal("50"), rows.second.signed_amount    # outflow negative -> expense positive
  end

  test "blank payee falls back to memo, then to the default row name" do
    import = ynab_import(file_fixture("imports/ynab.csv").read)
    import.generate_rows_from_csv

    # Last row has a blank Payee but a meaningful Memo
    assert_equal "Reconciliation balance adjustment",
      import.rows.order(:source_row_number).last.name

    blank_both = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo,Outflow,Inflow
      Checking,01/04/2024,,,,0.00,0.43
    CSV
    blank_both.generate_rows_from_csv

    assert_equal "Imported item", blank_both.rows.order(:source_row_number).first.name
  end

  test "publishes entries with combined money movement and mapped category/account" do
    import = ynab_import(file_fixture("imports/ynab.csv").read)
    import.generate_rows_from_csv

    import.mappings.create! key: "Housing: Rent", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Food: Coffee", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Income: Paycheck", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Checking", mappable: accounts(:depository), type: "Import::AccountMapping"
    import.mappings.create! key: "Credit Card", mappable: accounts(:credit_card), type: "Import::AccountMapping"
    import.reload

    assert_difference -> { Entry.count } => 5, -> { Transaction.count } => 5 do
      import.publish
    end

    assert_equal "complete", import.status

    entries = import.entries.reload
    assert_equal BigDecimal("1500"), entries.find { |e| e.name == "Landlord" }.amount   # expense, positive
    assert_equal BigDecimal("-2500"), entries.find { |e| e.name == "Employer" }.amount   # income, negative
  end

  test "nets the amount when both outflow and inflow are present on a row" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo,Outflow,Inflow
      Checking,05/01/2024,Adjustment,Income: Adjust,Net,30.00,100.00
    CSV
    import.generate_rows_from_csv

    # inflow 100 - outflow 30 = +70 (income), reversed to -70 in Sure's convention
    assert_equal BigDecimal("-70"), import.rows.first.signed_amount
  end

  test "treats an already-signed (negative) outflow as a magnitude" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo,Outflow,Inflow
      Checking,05/02/2024,Store,Food: Groceries,Signed,-25.00,
    CSV
    import.generate_rows_from_csv

    # A negative outflow is still an expense (+25 in Sure's convention), never income
    assert_equal BigDecimal("25"), import.rows.first.signed_amount
  end

  test "non-numeric outflow/inflow yields a zero amount instead of erroring" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo,Outflow,Inflow
      Checking,05/03/2024,Weird,Food: Groceries,Garbage,n/a,
    CSV
    import.generate_rows_from_csv

    assert_equal BigDecimal("0"), import.rows.first.signed_amount
  end

  test "leaves the account blank when the export omits an Account column" do
    import = ynab_import(<<~CSV)
      Date,Payee,Category Group/Category,Memo,Outflow,Inflow
      05/04/2024,Store,Food: Groceries,No account column,5.00,
    CSV
    import.generate_rows_from_csv

    assert_equal "", import.rows.first.account
  end

  test "blocks the import when no Outflow/Inflow/Amount column is present" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo
      Checking,01/01/2024,Store,Food: Groceries,No amount columns here
    CSV
    import.generate_rows_from_csv

    row = import.rows.first
    # No amount source -> blank amount -> fails the required-column validation
    assert_predicate row.amount.to_s, :blank?
    assert_not row.valid?
    assert_includes row.errors[:amount], "is required"
    assert_not import.cleaned?
  end

  test "still allows a genuine zero-dollar row when amount columns exist" do
    import = ynab_import(<<~CSV)
      Account,Date,Payee,Category Group/Category,Memo,Outflow,Inflow
      Checking,01/01/2024,Placeholder,Food: Groceries,Zero,$0.00,$0.00
    CSV
    import.generate_rows_from_csv

    row = import.rows.first
    assert_equal BigDecimal("0"), row.signed_amount
    assert row.valid?
  end

  private
    def ynab_import(csv)
      @family.imports.create!(type: "YnabImport", raw_file_str: csv, col_sep: ",")
    end
end
