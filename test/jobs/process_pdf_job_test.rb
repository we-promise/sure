require "test_helper"

class ProcessPdfJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @import = imports(:pdf)
    @family = @import.family
    use_ai_routes
  end

  test "skips non-PdfImport imports" do
    transaction_import = imports(:transaction)

    ProcessPdfJob.perform_now(transaction_import)

    assert_equal "pending", transaction_import.reload.status
  end

  test "skips if PDF not uploaded" do
    assert_not @import.pdf_uploaded?
    @import.update_columns(status: "importing", updated_at: 31.minutes.ago)

    ProcessPdfJob.perform_now(@import)

    assert_equal "pending", @import.reload.status
  end

  test "skips if PDF not uploaded without releasing fresh processing claim" do
    assert_not @import.pdf_uploaded?
    @import.update!(status: :importing)

    ProcessPdfJob.perform_now(@import)

    assert_equal "importing", @import.reload.status
  end

  test "skips if already processed" do
    processed_import = imports(:pdf_processed)

    ProcessPdfJob.perform_now(processed_import)

    # Should not change status since already complete
    assert_equal "complete", processed_import.reload.status
  end

  test "skips already processed importing import and releases processing claim" do
    processed_import = imports(:pdf_processed)
    attach_pdf!(processed_import)
    processed_import.update!(document_type: "financial_document")
    processed_import.update_columns(status: "importing", updated_at: 31.minutes.ago)
    processed_import.expects(:process_with_ai).never

    ProcessPdfJob.perform_now(processed_import)

    assert_equal "pending", processed_import.reload.status
  end

  test "skips already processed importing import without releasing fresh processing claim" do
    processed_import = imports(:pdf_processed)
    attach_pdf!(processed_import)
    processed_import.update!(status: :importing, document_type: "financial_document")
    processed_import.expects(:process_with_ai).never

    ProcessPdfJob.perform_now(processed_import)

    assert_equal "importing", processed_import.reload.status
  end

  test "uploads non-bank PDF to vector store with classified type metadata" do
    pdf_content = attach_pdf!(@import)
    process_result = Struct.new(:document_type).new("financial_document")

    @import.expects(:process_with_ai).once.returns(process_result)
    @import.stubs(:send_next_steps_email)
    @import.expects(:extract_transactions).never

    @family.expects(:upload_document).with do |file_content:, filename:, metadata:|
      assert_equal pdf_content, file_content
      assert_equal "sample_bank_statement.pdf", filename
      assert_equal({ "type" => "financial_document", "pdf_import_id" => @import.id }, metadata)
      true
    end.returns(family_documents(:tax_return))

    ProcessPdfJob.perform_now(@import)

    assert_equal "complete", @import.reload.status
  end

  test "skips the vector store when embed is unavailable" do
    use_ai_routes(embed: [])
    attach_pdf!(@import)
    @import.expects(:process_with_ai).once.returns(Struct.new(:document_type).new("financial_document"))
    @import.stubs(:send_next_steps_email)
    @family.expects(:upload_document).never

    ProcessPdfJob.perform_now(@import)

    assert_equal "complete", @import.reload.status
  end

  test "uploads bank statement PDF to vector store with classified type metadata" do
    pdf_content = attach_pdf!(@import)
    process_result = Struct.new(:document_type).new("bank_statement")

    @import.expects(:process_with_ai).once.returns(process_result)
    @import.expects(:extract_transactions).once do
      @import.update!(
        extracted_data: {
          "transactions" => [
            {
              "date" => "2024-01-01",
              "amount" => "10.00",
              "name" => "Coffee Shop"
            }
          ]
        }
      )
    end
    @import.expects(:sync_mappings).once
    @import.stubs(:send_next_steps_email)

    @family.expects(:upload_document).with do |file_content:, filename:, metadata:|
      assert_equal pdf_content, file_content
      assert_equal "sample_bank_statement.pdf", filename
      assert_equal({ "type" => "bank_statement", "pdf_import_id" => @import.id }, metadata)
      true
    end.returns(family_documents(:tax_return))

    ProcessPdfJob.perform_now(@import)

    assert_equal "complete", @import.reload.status
  end

  test "discards permanently and marks failed with the reason when no model can read the PDF" do
    attach_pdf!(@import)
    use_no_ai

    assert_nothing_raised { ProcessPdfJob.perform_now(@import) }

    assert_equal "failed", @import.reload.status
    assert_equal I18n.t("imports.pdf_import.errors.unavailable.not_configured"), @import.error
  end

  test "a failure to record the failed status propagates so the job retry isn't discarded" do
    @import.update!(status: :importing)
    @import.stubs(:update!).raises(StandardError, "database down")

    error = assert_raises(StandardError) do
      ProcessPdfJob.new.send(:record_failed_status, @import, Ai::Error::NoCredit.new("No credit", status: 400))
    end
    assert_equal "database down", error.message, "a generic error isn't swallowed by discard_on(Ai::Error::Base)"
  end

  test "a provider's error shows its own message, as Provider::Error did, not the class name" do
    attach_pdf!(@import)
    @import.expects(:process_with_ai).once.raises(Ai::Error::NoCredit.new("Your credit balance is too low to access the Anthropic API.", status: 400))

    assert_nothing_raised { ProcessPdfJob.perform_now(@import) }

    assert_equal "failed", @import.reload.status
    assert_equal "Your credit balance is too low to access the Anthropic API.", @import.error
  end

  test "a rendering failure keeps its concrete reason (#3275)" do
    attach_pdf!(@import)
    @import.expects(:process_with_ai).once.raises(Pdf::PageImages::Error.new("pdftoppm is not installed (poppler-utils)", code: :missing_binary))

    assert_nothing_raised { ProcessPdfJob.perform_now(@import) }

    assert_equal "failed", @import.reload.status
    assert_match "poppler-utils", @import.error
  end

  test "reads a statement end to end through the plumbing, recording how it was read and its checks" do
    attach_pdf!(@import)
    @import.stubs(:send_next_steps_email)
    use_ai_routes(embed: [])
    requests = stub_ai(:extract_pdf) do |request|
      if request.schema_name == "document_analysis"
        { document_type: "bank_statement", summary: "A statement", extracted_data: nil }
      else
        { bank_name: "Bank", account_holder: nil, account_number: nil, currency: "USD", opening_balance: 100.0, closing_balance: 90.0,
          statement_period: { start_date: "2024-01-01", end_date: "2024-01-31" },
          transactions: [ { date: "2024-01-05", description: "Coffee Shop", amount: -10.0, reference: nil, category: nil } ] }
      end
    end

    events = capture_ai_events { ProcessPdfJob.perform_now(@import) }

    @import.reload
    assert_equal [ "pdf_import:#{@import.id}" ], events.map { _1.payload[:correlation_id] }.uniq
    assert_equal "bank_statement", @import.document_type
    assert_equal "A statement", @import.ai_summary
    assert_equal "pdf", @import.read_with, "the test route's model reads PDFs"
    assert_equal "gpt-4.1-mini", @import.read_model
    assert_equal true, @import.extraction_checks["passed"]
    assert_equal [ "Coffee Shop" ], @import.extracted_transactions.map { _1["name"] }
    assert_equal 1, @import.rows_count
    assert_equal %w[document_analysis bank_statement], requests.map(&:schema_name)
  end

  test "skips already failed import" do
    attach_pdf!(@import)
    @import.update!(status: :failed)
    @import.expects(:process_with_ai).never

    ProcessPdfJob.perform_now(@import)

    assert_equal "failed", @import.reload.status
  end

  test "a reread clears the previous reading only while its attempt still holds the claim" do
    import = imports(:pdf_with_rows)
    ProcessPdfJob.any_instance.stubs(:process)

    ProcessPdfJob.perform_now(import, reread: true, reread_token: "stale")
    assert_equal 2, import.reload.rows_count, "not claimed: the previous reading stays"

    import.update!(status: :importing, reread_token: "current")
    ProcessPdfJob.perform_now(import, reread: true, reread_token: "stale")
    assert_equal 2, import.reload.rows_count, "a stale job cannot clear a newer reread"

    ProcessPdfJob.perform_now(import, reread: true)
    assert_equal 2, import.reload.rows_count, "a legacy reread without a token cannot clear a claim"

    ProcessPdfJob.perform_now(import, reread: true, reread_token: "current")
    assert_equal 0, import.reload.rows_count
    assert_not import.ai_processed?
  end

  test "a reread's failure is recorded before the job is discarded" do
    import = imports(:pdf_with_rows)
    attach_pdf!(import)
    import.update!(status: :importing, reread_token: "attempt")
    import.expects(:process_with_ai).raises(Ai::Error::NoCredit.new("No credit", status: 400))

    assert_nothing_raised { ProcessPdfJob.perform_now(import, reread: true, reread_token: "attempt") }

    import.reload
    assert import.failed?
    assert_equal "No credit", import.error
  end

  test "a provider's own error message never reaches the import's error or the log" do
    error = Ai::Error::Refused.new("400: account 12345678 is invalid")

    message = ProcessPdfJob.new.send(:sanitize_error_message, error)

    assert_not_includes message, "12345678"
    assert_includes message, "Refused"
  end

  private

    def attach_pdf!(import)
      pdf_content = file_fixture("imports/sample_bank_statement.pdf").binread
      import.pdf_file.attach(
        io: StringIO.new(pdf_content),
        filename: "sample_bank_statement.pdf",
        content_type: "application/pdf"
      )
      pdf_content
    end
end
