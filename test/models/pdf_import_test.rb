require "test_helper"

class PdfImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:pdf)
    @processed_import = imports(:pdf_processed)
    @import_with_rows = imports(:pdf_with_rows)
  end

  test "processing without a model that can read statements is unavailable with the router's reason" do
    use_ai_routes(extract_pdf: %w[embed/nomic-embed-text])

    error = assert_raises(Ai::Error::Unavailable) { @import.process_with_ai }

    assert_equal :capability_missing, error.reason
  end

  test "pdf_uploaded? returns false when no file attached" do
    assert_not @import.pdf_uploaded?
  end

  test "pdf_uploaded? returns true for statement backed import" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert import.pdf_uploaded?
    assert import.statement_backed?
    assert_equal statement.original_file.download, import.pdf_file_content
    assert_equal statement.filename, import.pdf_filename
  end

  test "ai_processed? returns false before ReadPdf has answered" do
    assert_not @import.ai_processed?
  end

  test "ai_processed? returns true once a document type is stored, with or without a summary" do
    assert @processed_import.ai_processed?

    @processed_import.update!(ai_summary: nil)
    assert @processed_import.reload.ai_processed?, "the summary is optional prose"
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

  test "status detail cleaned check requires account and transaction statement" do
    @import_with_rows.update!(account: accounts(:depository), document_type: "bank_statement")

    assert @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 1)

    @import_with_rows.update!(account: nil)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)

    @import_with_rows.update!(account: accounts(:depository), document_type: "other")
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
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
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_with job: ProcessPdfJob, args: [ import ] do
      assert import.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not enqueue duplicate jobs while importing" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_jobs 1, only: ProcessPdfJob do
      assert import.process_with_ai_later
      assert_not import.reload.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not claim import without pdf content" do
    assert_no_enqueued_jobs only: ProcessPdfJob do
      assert_not @import.process_with_ai_later
    end

    assert_equal "pending", @import.reload.status
  end

  test "process_with_ai_later resets pending when enqueue fails" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    ProcessPdfJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_not import.process_with_ai_later
    assert_equal "pending", import.reload.status
  end

  test "process_with_ai_later gives the import back when the queue declines without raising" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    ProcessPdfJob.stubs(:perform_later).returns(false)

    assert_not import.process_with_ai_later
    assert_equal "pending", import.reload.status
  end

  test "a lost reread that had already cleared the reading fails, so it can be read again" do
    import = @import_with_rows
    import.update_columns(status: "importing", reread_token: "attempt-1", updated_at: 7.hours.ago)
    import.rows.delete_all
    PdfImport.reset_counters(import.id, :rows)

    PdfImport.reap_stuck!(import.reload)

    assert import.reload.failed?
    assert_nil import.reread_token
  end

  test "reading again after the last route was removed is refused, not raised" do
    import = @import_with_rows
    import.stubs(:pdf_uploaded?).returns(true)
    import.stubs(:pdf_reading).returns(stub.tap { _1.stubs(:usable?).raises(Ai::Error::Unavailable, "not_configured") })

    assert_equal false, import.reread!("images")
    assert import.reload.pending?
  end

  test "reading again claims the import and keeps the previous reading until the job clears it" do
    import = @import_with_rows
    import.stubs(:pdf_uploaded?).returns(true)
    rows = import.rows_count

    assert_enqueued_with(job: ProcessPdfJob) { assert import.reread!("auto") }

    assert import.reload.importing?
    assert_equal rows, import.rows_count, "nothing is cleared before the job starts"
    import.clear_reading!
    assert_equal 0, import.reload.rows_count
    assert_not import.ai_processed?
  end

  test "a reread that can't be queued loses nothing and gives the import back" do
    import = @import_with_rows
    import.stubs(:pdf_uploaded?).returns(true)
    rows = import.rows_count
    ProcessPdfJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_equal :enqueue_failed, import.reread!("auto")

    assert import.reload.pending?
    assert_equal rows, import.rows_count
    assert import.ai_processed?
    assert_nil import.reread_token
  end

  test "reading again a way this file can't be read changes nothing" do
    import = @import_with_rows
    import.stubs(:pdf_uploaded?).returns(true)
    import.stubs(:pdf_reading).returns(stub.tap { _1.expects(:usable?).with("images").returns(false) })

    assert_no_enqueued_jobs(only: ProcessPdfJob) { assert_not import.reread!("images") }
    assert import.reload.pending?
  end

  test "a reread and a publish can't both claim the import" do
    import = @import_with_rows
    import.stubs(:publishable?).returns(true)
    import.update!(status: :importing)   # a reread claimed it

    assert_raises(RuntimeError) { import.publish_later }
  end

  test "a flagged reading that completed without rows can be read again; a published one can't" do
    import = @processed_import
    import.update!(status: :complete, extraction_checks: { "passed" => false, "reconciles" => false })
    assert import.rereadable?

    # The first call saw no entries; one created after it must still close the guard.
    import.entries.create!(account: accounts(:depository), date: Date.current, name: "Published row",
                           amount: -1, currency: "USD", entryable: Transaction.new)
    assert_not import.rereadable?
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
      source_row_number: 1,
      date: "01/15/2024",
      amount: -50.00,
      currency: "USD",
      name: "Test Transaction",
      category: "Groceries"
    )
    assert_equal [ Import::CategoryMapping ], @import_with_rows.mapping_steps
  end

  test "mapping_steps does not include AccountMapping even when account is nil" do
    # PDF imports handle account selection via direct UI, not mapping system
    assert_nil @import.account
    assert_not_includes @import.mapping_steps, Import::AccountMapping
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

  test "destroying statement backed import keeps statement file" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    attachment_id = statement.original_file.id

    perform_enqueued_jobs do
      import.destroy!
    end

    assert ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "statement backed import prevents source statement destroy" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert_no_difference "AccountStatement.count" do
      assert_not statement.destroy
    end

    assert_equal statement, import.reload.account_statement
  end

  test "statement backed import memoizes pdf content" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    statement.original_file.expects(:download).once.returns("%PDF-test")

    assert_equal "%PDF-test", import.pdf_file_content
    assert_equal "%PDF-test", import.pdf_file_content
  end

  test "statement backed import reuse requires current account and date format" do
    statement = create_pdf_statement
    stale_import = PdfImport.create_from_statement!(statement: statement)
    formats = Family::DATE_FORMATS.map(&:last)
    alternate_date_format = (formats - [ statement.family.date_format ]).first || "#{statement.family.date_format}-alternate"
    stale_import.update!(account: nil, date_format: alternate_date_format)

    fresh_import = PdfImport.create_from_statement!(statement: statement)

    assert_not_equal stale_import, fresh_import
    assert_equal statement.account, fresh_import.account
    assert_equal statement.family.date_format, fresh_import.date_format
  end

  test "statement backed import reuses matching reusable import" do
    statement = create_pdf_statement
    existing_import = PdfImport.create_from_statement!(statement: statement)

    assert_equal existing_import, PdfImport.create_from_statement!(statement: statement)
  end

  test "assigning account links statement backed import statement" do
    statement = create_pdf_statement(account: nil)
    import = PdfImport.create_from_statement!(statement: statement)
    account = accounts(:depository)

    import.assign_account!(account)

    assert_equal account, import.reload.account
    assert_equal account, statement.reload.account
    assert statement.linked?
  end

  test "statement backed import requires pdf statement" do
    csv_statement = AccountStatement.create_from_upload!(
      family: @import.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    import = PdfImport.new(family: @import.family, account_statement: csv_statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  test "statement backed import requires statement from same family" do
    statement = AccountStatement.create_from_upload!(
      family: families(:empty),
      account: nil,
      file: uploaded_file(
        filename: "other_family_statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    import = PdfImport.new(family: @import.family, account_statement: statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  test "a duplicate upload doesn't change the way a claimed import is being read" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement:, read_as: "text")
    import.update!(status: :importing)

    PdfImport.create_from_statement!(statement:, read_as: "images")

    assert_equal "text", import.reload.read_as
  end

  private

    def create_pdf_statement(account: accounts(:depository))
      AccountStatement.create_from_upload!(
        family: @import.family,
        account: account,
        file: uploaded_file(
          filename: "sample_bank_statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
