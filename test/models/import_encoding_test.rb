require "test_helper"

class ImportEncodingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "successfully imports Windows-1250 encoded CSV" do
    # Test that Windows-1250 encoded files are properly converted to UTF-8
    file_path = Rails.root.join("test/fixtures/files/imports/windows1250.csv")
    csv_content = File.binread(file_path)

    # Verify the file is not UTF-8
    assert_equal Encoding::ASCII_8BIT, csv_content.encoding
    refute csv_content.force_encoding("UTF-8").valid_encoding?, "Test file should not be valid UTF-8"

    import = @family.imports.create!(
      type: "TransactionImport",
      account: @account,
      date_format: "%Y-%m-%d",
      date_col_label: "Date",
      amount_col_label: "Amount",
      name_col_label: "Name",
      category_col_label: "Category",
      tags_col_label: "Tags",
      account_col_label: "Account",
      notes_col_label: "Notes",
      signage_convention: "inflows_negative",
      amount_type_strategy: "signed_amount"
    )

    # With encoding detection, the import should succeed
    assert_nothing_raised do
      import.update!(raw_file_str: csv_content)
    end

    # Verify the raw_file_str was converted to UTF-8
    assert_equal Encoding::UTF_8, import.raw_file_str.encoding
    assert import.raw_file_str.valid_encoding?, "Converted string should be valid UTF-8"

    # Verify we can generate rows from the CSV
    assert_nothing_raised do
      import.generate_rows_from_csv
    end

    # Verify that rows were created
    import.reload
    assert import.rows_count > 0, "Expected rows to be created from Windows-1250 CSV"
    assert_equal 3, import.rows_count, "Expected 3 data rows"

    # Verify Polish characters were preserved correctly
    # Check that any row contains the Polish characters (test is about encoding, not ordering)
    assert import.rows.any? { |row| row.name&.include?("spożywczy") }, "Polish characters should be preserved"
    # Also verify other Polish characters from different rows
    assert import.rows.any? { |row| row.name&.include?("Café") }, "Extended Latin characters should be preserved"
  end

  test "handles UTF-8 files without modification" do
    # Test that valid UTF-8 files are not modified
    file_path = Rails.root.join("test/fixtures/files/imports/transactions.csv")
    csv_content = File.read(file_path, encoding: "UTF-8")

    import = @family.imports.create!(
      type: "TransactionImport",
      account: @account,
      date_format: "%Y-%m-%d",
      raw_file_str: csv_content
    )

    # UTF-8 content should remain unchanged
    assert_equal Encoding::UTF_8, import.raw_file_str.encoding
    assert import.raw_file_str.valid_encoding?
  end
end
