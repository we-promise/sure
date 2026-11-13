require "test_helper"

class AiE2ePdfImportTest < ActiveSupport::TestCase
  include AiE2eHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  # bac_ocr.pdf has a text layer (13 transactions), so "text" reads it without vision, which the
  # free model may not have.
  test "Kilo reads a bank statement's rows through ProcessPdfJob" do
    import = with_live_ai do
      upload = uploaded_file(filename: "bac_ocr.pdf", content_type: "application/pdf",
                             content: file_fixture("statements/bac_ocr.pdf").binread)
      PdfImport.create_from_upload!(family: @family, file: upload, user: @user, read_as: "text").tap do
        ProcessPdfJob.perform_now(_1)
      end
    end
    import.reload

    assert_includes %w[pending complete], import.status, import.error
    assert import.statement_with_transactions?, "read as #{import.document_type.inspect}"
    assert_equal "text", import.read_with
    assert_operator import.rows_count, :>, 0
    # A failing extraction is kept and flagged, never dropped: either way the checks are recorded.
    assert_includes [ true, false ], import.extraction_checks["passed"]
    assert_ai_usage(@family, :extract_pdf)
  end
end
