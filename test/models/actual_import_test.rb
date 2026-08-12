require "test_helper"

class ActualImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "default column mappings are applied after create" do
    import = @family.imports.create!(type: "ActualImport")

    ActualImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
  end

  test "generated rows preserve stable source row numbers" do
    import = @family.imports.create!(
      type: "ActualImport",
      raw_file_str: file_fixture("imports/actual.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv

    assert_equal (1..5).to_a, import.rows.order(:source_row_number).pluck(:source_row_number)
  end

  test "generated rows combine category group and category" do
    import = @family.imports.create!(
      type: "ActualImport",
      raw_file_str: file_fixture("imports/actual.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv

    assert_equal "Food: Coffee", import.rows.order(:source_row_number).second.category
    assert_equal "Income: Paycheck", import.rows.order(:source_row_number).third.category
    assert_equal "Transfer", import.rows.order(:source_row_number).fourth.category
  end

  test "generated rows fall back to category group when category is blank" do
    import = @family.imports.create!(
      type: "ActualImport",
      raw_file_str: file_fixture("imports/actual.csv").read.sub("Housing,Rent", "Housing,"),
      col_sep: ","
    )

    import.generate_rows_from_csv

    assert_equal "Housing", import.rows.order(:source_row_number).first.category
  end

  test "blank payee falls back to notes, then to the default row name" do
    import = @family.imports.create!(
      type: "ActualImport",
      raw_file_str: file_fixture("imports/actual.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv

    # Reconciliation row has a blank Payee but a meaningful Notes value
    assert_equal "Reconciliation balance adjustment",
      import.rows.order(:source_row_number).last.name

    # When both Payee and Notes are blank, fall back to the generic default name
    blank_both_csv = <<~CSV
      Account,Date,Payee,Notes,Category_Group,Category,Amount,Split_Amount,Cleared
      Checking Account,2024-01-04,,,Income,Income,0.43,0,Reconciled
    CSV

    blank_both = @family.imports.create!(type: "ActualImport", raw_file_str: blank_both_csv, col_sep: ",")
    blank_both.generate_rows_from_csv

    assert_equal "Imported item", blank_both.rows.order(:source_row_number).first.name
  end

  test "imports rows with a blank payee without failing the whole import" do
    csv = <<~CSV
      Account,Date,Payee,Notes,Category_Group,Category,Amount,Split_Amount,Cleared
      Cash,2024-01-01,Employer,Salary,Income,Paycheck,2500.00,0,Reconciled
      Cash,2024-01-04,,Reconciliation balance adjustment,Income,Income,0.43,0,Reconciled
    CSV

    import = @family.imports.create!(type: "ActualImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    import.mappings.create! key: "Income: Paycheck", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Income: Income", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Cash", mappable: accounts(:depository), type: "Import::AccountMapping"
    import.reload

    assert_difference -> { Entry.count } => 2, -> { Transaction.count } => 2 do
      import.publish
    end

    assert_equal "complete", import.status
    assert_includes import.entries.reload.map(&:name), "Reconciliation balance adjustment"
  end
end
