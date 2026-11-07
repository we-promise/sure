require "test_helper"

class ProcessPdfJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @import = imports(:pdf)
    @family = @import.family
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
      assert_equal({ "type" => "financial_document" }, metadata)
      true
    end.returns(family_documents(:tax_return))

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
      assert_equal({ "type" => "bank_statement" }, metadata)
      true
    end.returns(family_documents(:tax_return))

    ProcessPdfJob.perform_now(@import)

    assert_equal "complete", @import.reload.status
  end

  test "discards permanently and marks failed on Provider::Error" do
    attach_pdf!(@import)
    @import.expects(:process_with_ai).once.raises(Provider::Error, "Could not convert PDF to images")

    assert_nothing_raised do
      ProcessPdfJob.perform_now(@import)
    end

    assert_equal "failed", @import.reload.status
    assert @import.error.present?
  end

  test "completion email records successful document search upload" do
    attach_pdf!(@import)
    @import.expects(:process_with_ai).returns(Struct.new(:document_type).new("financial_document"))
    @family.expects(:upload_document).returns(family_documents(:tax_return))

    assert_enqueued_email_with PdfImportMailer, :next_steps,
      params: { user: users(:family_admin), pdf_import: @import, document_uploaded_for_search: true } do
      ProcessPdfJob.perform_now(@import)
    end

    assert_equal "complete", @import.reload.status
  end

  test "unsuccessful document upload does not fail PDF analysis or claim searchable storage" do
    attach_pdf!(@import)
    @import.expects(:process_with_ai).returns(Struct.new(:document_type).new("financial_document"))
    @family.expects(:upload_document).returns(nil)

    assert_enqueued_email_with PdfImportMailer, :next_steps,
      params: { user: users(:family_admin), pdf_import: @import, document_uploaded_for_search: false } do
      ProcessPdfJob.perform_now(@import)
    end

    assert_equal "complete", @import.reload.status
  end

  { "anthropic" => Provider::Anthropic, "openrouter" => Provider::Openrouter }.each do |provider_name, provider_class|
    test "family #{provider_name} extracts transactions without document search" do
      @family.create_ai_configuration!(provider: provider_name, api_key: "synthetic-family-key", model: provider_name == "openrouter" ? "openai/gpt-4.1-mini" : Provider::Anthropic::DEFAULT_MODEL)
      attach_pdf!(@import)
      result = Provider::LlmConcept::PdfProcessingResult.new(summary: "Bank statement", document_type: "bank_statement", extracted_data: nil)
      transactions = { transactions: [ { date: "2024-01-15", amount: "-50.00", name: "Coffee Shop" } ] }
      provider_class.any_instance.expects(:process_pdf).returns(Provider::Response.new(success?: true, data: result, error: nil))
      provider_class.any_instance.expects(:extract_bank_statement).returns(Provider::Response.new(success?: true, data: transactions, error: nil))
      VectorStore::Openai.expects(:new).never

      assert_no_difference "FamilyDocument.count" do
        assert_enqueued_email_with PdfImportMailer, :next_steps,
          params: { user: users(:family_admin), pdf_import: @import, document_uploaded_for_search: false } do
          ProcessPdfJob.perform_now(@import)
        end
      end

      assert_equal "pending", @import.reload.status
      assert_equal "Bank statement", @import.ai_summary
      assert_equal 1, @import.rows_count
      assert_equal "Coffee Shop", @import.rows.first.name
    end
  end

  test "skips already failed import" do
    attach_pdf!(@import)
    @import.update!(status: :failed)
    @import.expects(:process_with_ai).never

    ProcessPdfJob.perform_now(@import)

    assert_equal "failed", @import.reload.status
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
