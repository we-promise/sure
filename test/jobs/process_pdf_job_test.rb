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

    ProcessPdfJob.perform_now(@import)

    assert_equal "pending", @import.reload.status
  end

  test "skips if already processed" do
    processed_import = imports(:pdf_processed)

    ProcessPdfJob.perform_now(processed_import)

    # Should not change status since already complete
    assert_equal "complete", processed_import.reload.status
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
