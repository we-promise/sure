require "test_helper"

class PdfImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:pdf)
    @processed_import = imports(:pdf_processed)
    @import_with_rows = imports(:pdf_with_rows)
  end

  test "pdf_uploaded? returns false when no file attached" do
    assert_not @import.pdf_uploaded?
  end

  test "ai_processed? returns false when no summary present" do
    assert_not @import.ai_processed?
  end

  test "ai_processed? returns true when summary present" do
    assert @processed_import.ai_processed?
  end

  test "uploaded? delegates to pdf_uploaded?" do
    assert_not @import.uploaded?
  end

  test "configured? requires AI processed and rows" do
    assert_not @import.configured?
    assert_not @processed_import.configured?
    assert @import_with_rows.configured?
  end

  test "cleaned? requires configured and valid rows" do
    assert_not @import.cleaned?
    assert_not @processed_import.cleaned?
  end

  test "publishable? requires bank statement with cleaned rows and valid mappings" do
    assert_not @import.publishable?
    assert_not @processed_import.publishable?
  end

  test "column_keys returns transaction columns" do
    assert_equal %i[date amount name category notes], @import.column_keys
  end

  test "required_column_keys returns date and amount" do
    assert_equal %i[date amount], @import.required_column_keys
  end

  test "document_type validates against allowed types" do
    @import.document_type = "bank_statement"
    assert @import.valid?

    @import.document_type = "invalid_type"
    assert_not @import.valid?
    assert @import.errors[:document_type].present?
  end

  test "document_type allows nil" do
    @import.document_type = nil
    assert @import.valid?
  end

  test "process_with_ai_later enqueues ProcessPdfJob" do
    assert_enqueued_with job: ProcessPdfJob, args: [ @import ] do
      @import.process_with_ai_later
    end
  end

  test "generate_rows_from_extracted_data creates import rows" do
    import = imports(:pdf_with_rows)
    import.rows.destroy_all
    import.update_column(:rows_count, 0)

    import.generate_rows_from_extracted_data

    assert_equal 2, import.rows.count
    assert_equal 2, import.rows_count

    coffee_row = import.rows.find_by(name: "Coffee Shop")
    assert_not_nil coffee_row
    assert_equal "-50.0", coffee_row.amount
    assert_equal "Food & Drink", coffee_row.category

    salary_row = import.rows.find_by(name: "Salary")
    assert_not_nil salary_row
    assert_equal "1500.0", salary_row.amount
  end

  test "generate_rows_from_extracted_data does nothing without extracted transactions" do
    @import.generate_rows_from_extracted_data
    assert_equal 0, @import.rows.count
  end

  test "extracted_transactions returns transactions from extracted_data" do
    assert_equal 2, @import_with_rows.extracted_transactions.size
    assert_equal "Coffee Shop", @import_with_rows.extracted_transactions.first["name"]
  end

  test "extracted_transactions returns empty array when no data" do
    assert_equal [], @import.extracted_transactions
  end

  test "has_extracted_transactions? returns true with transactions" do
    assert @import_with_rows.has_extracted_transactions?
  end

  test "has_extracted_transactions? returns false without transactions" do
    assert_not @import.has_extracted_transactions?
  end

  test "mapping_steps is empty when no categories in rows" do
    # PDF imports use direct account selection in UI, not AccountMapping
    assert_equal [], @import.mapping_steps
  end

  test "mapping_steps includes CategoryMapping when rows have categories" do
    @import_with_rows.rows.create!(
      date: "01/15/2024",
      amount: -50.00,
      currency: "USD",
      name: "Test Transaction",
      category: "Groceries"
    )
    assert_equal [ Import::CategoryMapping ], @import_with_rows.mapping_steps
  end

  test "mapping_steps does not include AccountMapping even when account is nil" do
    assert_nil @import.account
    assert_not_includes @import.mapping_steps, Import::AccountMapping
  end

  test "investment_statement? returns true for investment_statement type" do
    @import_investment = imports(:pdf_investment)
    assert @import_investment.investment_statement?
  end

  test "investment_statement? returns false for bank_statement type" do
    assert_not @import_with_rows.investment_statement?
  end

  test "column_keys returns trade columns for investment statements" do
    @import_investment = imports(:pdf_investment)
    assert_equal %i[date ticker qty price name], @import_investment.column_keys
  end

  test "required_column_keys returns trade required columns for investment statements" do
    @import_investment = imports(:pdf_investment)
    assert_equal %i[date ticker qty price], @import_investment.required_column_keys
  end

  test "has_extracted_trades? returns true with trades" do
    @import_investment = imports(:pdf_investment)
    assert @import_investment.has_extracted_trades?
  end

  test "has_extracted_trades? returns false without trades" do
    assert_not @import.has_extracted_trades?
  end

  test "extracted_trades returns trades from extracted_data" do
    @import_investment = imports(:pdf_investment)
    assert_equal 2, @import_investment.extracted_trades.size
    assert_equal "AAPL", @import_investment.extracted_trades.first["ticker"]
  end

  test "generate_rows_from_extracted_data creates trade rows for investment statements" do
    @import_investment = imports(:pdf_investment)
    @import_investment.rows.destroy_all
    @import_investment.update_column(:rows_count, 0)

    @import_investment.generate_rows_from_extracted_data

    assert_equal 2, @import_investment.rows.count
    assert_equal 2, @import_investment.rows_count

    aapl_row = @import_investment.rows.find_by(ticker: "AAPL")
    assert_not_nil aapl_row
    assert_equal "10", aapl_row.qty
    assert_equal "175.50", aapl_row.price
    assert_equal "Apple Inc.", aapl_row.name

    msft_row = @import_investment.rows.find_by(ticker: "MSFT")
    assert_not_nil msft_row
    assert_equal "-5", msft_row.qty
    assert_equal "380.00", msft_row.price
  end

  test "publishable? returns true for investment statement with valid setup" do
    @import_investment = imports(:pdf_investment)
    @import_investment.rows.destroy_all
    @import_investment.generate_rows_from_extracted_data

    assert @import_investment.publishable?
  end

  test "mapping_steps is empty for investment statements" do
    @import_investment = imports(:pdf_investment)
    assert_equal [], @import_investment.mapping_steps
  end

  test "trade_entry_name_for uses neutral label for zero quantity" do
    import = imports(:pdf_investment)
    row = Import::Row.new(qty: "0", ticker: "AAPL", name: "")
    assert_equal "Trade AAPL", import.send(:trade_entry_name_for, row)
  end

  test "trade_entry_name_for uses Imported trade when zero qty and no ticker" do
    import = imports(:pdf_investment)
    row = Import::Row.new(qty: "0", ticker: "", name: "")
    assert_equal "Imported trade", import.send(:trade_entry_name_for, row)
  end

  test "trade_entry_name_for uses Trade.build_name when quantity is nonzero" do
    import = imports(:pdf_investment)
    row = Import::Row.new(qty: "10", ticker: "AAPL", name: "")
    assert_equal Trade.build_name("buy", "10", "AAPL"), import.send(:trade_entry_name_for, row)
  end

  test "investment statement rejects accounts that cannot hold trades" do
    import = imports(:pdf_investment)
    import.account = accounts(:depository)
    assert_not import.valid?
    assert import.errors[:account].present?
  end

  test "investment statement allows investment and crypto accounts" do
    import = imports(:pdf_investment)
    assert import.valid?

    import.account = accounts(:crypto)
    assert import.valid?
  end

  test "import! raises when investment statement is linked to a depository account" do
    import = imports(:pdf_investment)
    import.update_column(:account_id, accounts(:depository).id)
    import.reload

    error = assert_raises(RuntimeError) { import.import! }
    assert_equal I18n.t("imports.errors.investment_statement_account_type"), error.message
  end

  test "publishable? is false for investment statement with incompatible account" do
    import = imports(:pdf_investment)
    import.update_column(:account_id, accounts(:depository).id)
    import.reload

    assert_not import.publishable?
  end

  test "destroying import purges attached pdf_file" do
    @import.pdf_file.attach(
      io: StringIO.new("fake-pdf-content"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )

    attachment_id = @import.pdf_file.id
    assert ActiveStorage::Attachment.exists?(attachment_id)

    perform_enqueued_jobs do
      @import.destroy!
    end

    assert_not ActiveStorage::Attachment.exists?(attachment_id)
  end
end
