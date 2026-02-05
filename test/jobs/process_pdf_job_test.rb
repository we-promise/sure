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
end
