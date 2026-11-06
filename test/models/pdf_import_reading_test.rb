require "test_helper"

# How a PDF import is read (2e plan, step 7): "Read as" per upload, Auto's tuning per account
# and model, the review flag for an extraction that failed its checks, and reading again.
class PdfImportReadingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    use_ai_routes
    @import = imports(:pdf_with_rows)
    @account = accounts(:depository)
  end

  test "read_as is one of the ways, or unset" do
    @import.read_as = "images"
    assert @import.valid?
    @import.read_as = "fax"
    assert_not @import.valid?
  end

  test "Auto starts from the way that last passed for the same account and model" do
    passed = imports(:pdf).tap { _1.update!(account: @account, read_with: "images", read_model: "gpt-4.1-mini", extraction_checks: { "passed" => true }) }
    imports(:pdf_processed).update!(account: @account, read_with: "text", read_model: "gpt-4.1-mini", extraction_checks: { "passed" => false })

    assert_equal "images", PdfImport.last_passing_way(account: @account, model: "gpt-4.1-mini")
    assert_nil PdfImport.last_passing_way(account: @account, model: "qwen3-8b"), "a new model starts afresh"
    assert_nil PdfImport.last_passing_way(account: nil, model: "gpt-4.1-mini")

    passed.update!(read_with: "ocr")
    assert_equal "ocr", PdfImport.last_passing_way(account: @account, model: "gpt-4.1-mini")
  end

  test "an extraction that failed its checks is flagged with the checks it failed" do
    @import.update!(extraction_checks: { "passed" => false, "reconciles" => false, "amounts_in_source" => true, "dates_anchored" => 0.2 })

    assert @import.extraction_flagged?
    assert_equal %w[reconciles dates_anchored], @import.failed_checks

    @import.update!(extraction_checks: { "passed" => true, "reconciles" => true })
    assert_not @import.extraction_flagged?
    assert_empty @import.failed_checks
  end

  test "reading again another way clears the unpublished rows and queues the job" do
    @import.update!(read_with: "text", extraction_checks: { "passed" => false }, extracted_data: { "transactions" => [] })
    @import.stubs(:pdf_uploaded?).returns(true)

    assert_enqueued_with(job: ProcessPdfJob) { assert @import.reread!("images") }

    @import.reload
    assert_equal "images", @import.read_as
    assert_equal 0, @import.rows.count
    assert_nil @import.ai_summary
    assert_nil @import.extraction_checks
    assert_equal "importing", @import.status
  end

  test "reading again is refused once anything is published" do
    @import.stubs(:imported_count).returns(3)

    assert_not @import.reread!("images")
    assert_raises(ArgumentError) { @import.reread!("fax") }
  end
end
