require "test_helper"

class MintImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "generated rows preserve stable source row numbers" do
    import = @family.imports.create!(
      type: "MintImport",
      raw_file_str: file_fixture("imports/mint.csv").read,
      col_sep: ","
    )

    import.generate_rows_from_csv

    assert_equal (1..10).to_a, import.rows.order(:source_row_number).pluck(:source_row_number)
  end
end
