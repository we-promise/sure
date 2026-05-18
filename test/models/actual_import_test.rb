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

    assert_equal (1..4).to_a, import.rows.order(:source_row_number).pluck(:source_row_number)
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
end
