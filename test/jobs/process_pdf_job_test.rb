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

    @import.expects(:process_with_ai).with(user: nil).once.returns(process_result)
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

    @import.expects(:process_with_ai).with(user: nil).once.returns(process_result)
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

  test "passes the initiating user to PDF processing" do
    pdf_content = attach_pdf!(@import)
    user = users(:family_member)
    process_result = Struct.new(:document_type).new("financial_document")

    @import.expects(:process_with_ai).with(user: user).once.returns(process_result)
    @import.stubs(:send_next_steps_email)

    @family.expects(:upload_document).with do |file_content:, filename:, metadata:|
      assert_equal pdf_content, file_content
      assert_equal "sample_bank_statement.pdf", filename
      assert_equal({ "type" => "financial_document" }, metadata)
      true
    end.returns(family_documents(:tax_return))

    ProcessPdfJob.perform_now(@import, user)

    assert_equal "complete", @import.reload.status
  end

  test "does not auto-assign account from reconciliation output" do
    pdf_content = attach_pdf!(@import)
    process_result = Struct.new(:document_type).new("bank_statement")

    @import.update!(
      extracted_data: {
        "reconciliation" => {
          "performed" => true,
          "account_id" => accounts(:depository).id,
          "balance_match" => false,
          "statement_transaction_count" => 1
        }
      }
    )
    PdfImport.any_instance.expects(:process_with_ai).with(user: nil).once.returns(process_result)
    PdfImport.any_instance.expects(:extract_transactions).once do |import|
      import.update!(
        extracted_data: import.extracted_data.deep_merge(
          "transactions" => [
            {
              "date" => "2024-01-01",
              "amount" => "10.00",
              "name" => "Coffee Shop"
            }
          ]
        )
      )
    end
    PdfImport.any_instance.expects(:sync_mappings).once
    PdfImport.any_instance.stubs(:send_next_steps_email)

    @family.expects(:upload_document).with do |file_content:, filename:, metadata:|
      assert_equal pdf_content, file_content
      assert_equal "sample_bank_statement.pdf", filename
      assert_equal({ "type" => "bank_statement" }, metadata)
      true
    end.returns(family_documents(:tax_return))

    ProcessPdfJob.perform_now(@import)

    assert_nil @import.reload.account
  end

  test "does not skip extraction when reconciliation has unmatched transactions" do
    attach_pdf!(@import)

    @import.update!(
      ai_summary: nil,
      status: :pending,
      document_type: "bank_statement",
      extracted_data: {
        "reconciliation" => {
          "performed" => true,
          "account_id" => accounts(:depository).id,
          "balance_match" => true,
          "statement_transaction_count" => 2,
          "synced_transaction_count" => 2,
          "matched_count" => 1,
          "new_count" => 1,
          "missing_count" => 0,
          "new_transactions" => [
            { "date" => "2024-01-02", "amount" => "-12.34", "description" => "Unmatched" }
          ],
          "missing_transactions" => []
        }
      }
    )
    provider_response = Struct.new(:data) do
      def success? = true
      def error = nil
    end
    provider = Class.new do
      attr_reader :extract_called

      def initialize(process_result, provider_response)
        @process_result = process_result
        @provider_response = provider_response
        @extract_called = false
      end

      def supports_pdf_processing? = true

      def process_pdf(pdf_content:, family:, user:)
        @provider_response.new(@process_result)
      end

      def extract_bank_statement(pdf_content:, family:)
        @extract_called = true
        @provider_response.new(
          {
            transactions: [
              {
                date: "2024-01-01",
                amount: "10.00",
                name: "Coffee Shop"
              }
            ]
          }
        )
      end
    end.new(
      Provider::LlmConcept::PdfProcessingResult.new(
        summary: "Processed",
        document_type: "bank_statement",
        extracted_data: @import.extracted_data.except("reconciliation"),
        reconciliation: @import.extracted_data.fetch("reconciliation")
      ),
      provider_response
    )
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    @family.stubs(:upload_document).returns(family_documents(:tax_return))
    @import.stubs(:send_next_steps_email)

    ProcessPdfJob.perform_now(@import)

    assert provider.extract_called, "expected unmatched reconciliation to continue to extraction"
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
