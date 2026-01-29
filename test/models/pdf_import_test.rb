require "test_helper"

class PdfImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:pdf)
    @processed_import = imports(:pdf_processed)
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

  test "configured? returns true when AI processed" do
    assert @processed_import.configured?
    assert_not @import.configured?
  end

  test "cleaned? returns true when AI processed" do
    assert @processed_import.cleaned?
    assert_not @import.cleaned?
  end

  test "publishable? always returns false for PDF imports" do
    assert_not @import.publishable?
    assert_not @processed_import.publishable?
  end

  test "column_keys returns empty array" do
    assert_equal [], @import.column_keys
  end

  test "required_column_keys returns empty array" do
    assert_equal [], @import.required_column_keys
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
end
