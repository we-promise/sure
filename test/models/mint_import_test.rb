require "test_helper"

class MintImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "default column mappings are applied after create" do
    import = @family.imports.create!(type: "MintImport")

    MintImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
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

  test "the transaction type sets the direction whatever the amount's sign" do
    import = mint_import(<<~CSV)
      Date,Amount,Account Name,Description,Category,Labels,Currency,Notes,Transaction Type
      01/01/2024,8.55,Checking,Coffee,Food & Drink,,USD,,debit
      01/02/2024,-8.55,Checking,Coffee,Food & Drink,,USD,,debit
      01/03/2024,2000,Checking,Paycheck,Income,,USD,,credit
      01/04/2024,-2000,Checking,Paycheck,Income,,USD,,credit
    CSV

    assert_equal [ 8.55, 8.55, -2000, -2000 ], signed_amounts(import)
  end

  test "the sample CSV imports its debit as an outflow and its credit as an inflow" do
    import = mint_import(MintImport.new.csv_template.to_csv)

    assert_equal [ 8.55, -2000 ], signed_amounts(import)
  end

  test "formatted amounts are parsed with the import's number format" do
    import = mint_import(<<~CSV)
      Date,Amount,Account Name,Description,Category,Labels,Currency,Notes,Transaction Type
      01/01/2024,"$1,234.56",Checking,Rent,Rent,,USD,,debit
      01/02/2024,"1,234.56",Checking,Refund,Rent,,USD,,credit
    CSV

    assert_equal [ 1234.56, -1234.56 ], signed_amounts(import)
  end

  private
    def mint_import(csv)
      @family.imports.create!(type: "MintImport", raw_file_str: csv, col_sep: ",").tap(&:generate_rows_from_csv)
    end

    def signed_amounts(import)
      import.rows.order(:source_row_number).map { |row| row.signed_amount.to_f }
    end
end
