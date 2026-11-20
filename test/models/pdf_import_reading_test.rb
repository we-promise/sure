require "test_helper"

# How a PDF import is read: "Read as" per upload, Auto's tuning per account
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

  test "Auto also learns from a statement without balances, where it stopped with nothing left to fix" do
    imports(:pdf).update!(account: @account, read_with: "images", read_model: "gpt-4.1-mini",
                          extraction_checks: { "passed" => false, "settled" => true, "reconciles" => nil })

    assert_equal "images", PdfImport.last_passing_way(account: @account, model: "gpt-4.1-mini")
  end

  test "a job's ReadPdf and extraction share one reader, so the PDF is downloaded once" do
    @import.expects(:pdf_file_content).once.returns("%PDF-1.4")

    assert_same @import.pdf_reading, @import.pdf_reading
  end

  test "an extraction that failed its checks is flagged with the checks it failed" do
    @import.update!(extraction_checks: { "passed" => false, "reconciles" => false, "amounts_in_source" => true, "dates_anchored" => 0.2 })

    assert @import.extraction_flagged?
    assert_equal %w[reconciles dates_anchored], @import.failed_checks

    @import.update!(extraction_checks: { "passed" => false, "reconciles" => nil, "amounts_in_source" => nil, "dates_anchored" => nil })
    assert_equal %w[balances], @import.failed_checks, "a statement without balances is flagged as unchecked"

    @import.update!(extraction_checks: { "passed" => true, "reconciles" => true })
    assert_not @import.extraction_flagged?
    assert_empty @import.failed_checks
  end

  test "reading again another way queues the job, which clears the unpublished rows when it starts" do
    @import.update!(read_with: "text", extraction_checks: { "passed" => false }, extracted_data: { "transactions" => [] })
    @import.stubs(:pdf_uploaded?).returns(true)
    @import.stubs(:pdf_reading).returns(stub(ways: { images: nil }))
    row = @import.rows.create!(source_row_number: 1, date: "01/15/2024", amount: "-50.00", name: "Coffee Shop", currency: "USD")

    assert_enqueued_with(job: ProcessPdfJob) { assert @import.reread!("images") }
    token = enqueued_jobs.last[:args].last["reread_token"]

    @import.reload
    assert_equal "images", @import.read_as
    assert_equal "importing", @import.status
    assert_equal token, @import.reread_token
    assert Import::Row.exists?(row.id), "kept until the job starts"
    assert @import.clear_reading!(reread_token: token)
    assert_not Import::Row.exists?(row.id)
    assert_equal 0, @import.reload.rows.count
    assert_nil @import.ai_summary
    assert_nil @import.extraction_checks
    assert_equal token, @import.reread_token, "the active retry must still own the import after cleanup"
  end

  test "clearing a reread keeps its token so a redelivered job can resume" do
    @import.stubs(:pdf_uploaded?).returns(true)
    @import.stubs(:pdf_reading).returns(stub(ways: { images: nil }))
    @import.rows.create!(source_row_number: 1, date: "01/15/2024", amount: "-50.00", name: "Coffee Shop", currency: "USD")
    assert @import.reread!("images")
    token = @import.reload.reread_token

    assert @import.clear_reading!(reread_token: token)
    import = @import.reload
    assert_equal 0, import.rows.count
    assert_equal token, import.reread_token, "cleanup must not strand the active claim"
    assert_not import.clear_reading!(reread_token: "older-attempt"), "a superseded token is still rejected"
  end

  test "a delayed reread cannot clear a newer claim or a publish" do
    @import.stubs(:pdf_uploaded?).returns(true)
    @import.stubs(:pdf_reading).returns(stub(ways: { images: nil }))
    row = @import.rows.create!(source_row_number: 1, date: "01/15/2024", amount: "-50.00", name: "Coffee Shop", currency: "USD")
    assert @import.reread!("images")
    old_token = @import.reload.reread_token

    @import.update!(status: :pending, reread_token: nil)
    newer_token = SecureRandom.uuid
    @import.update!(status: :importing, reread_token: newer_token)
    assert_not @import.clear_reading!(reread_token: old_token), "an older attempt loses to the newer reread"
    assert Import::Row.exists?(row.id)

    @import.update!(reread_token: nil) # a publish took the claim
    assert_not @import.clear_reading!(reread_token: old_token)
    assert_not @import.clear_reading!(reread_token: newer_token)
    assert Import::Row.exists?(row.id), "the published rows are not a stale reread's to clear"
  end

  test "a reread that can't be queued restores its way and keeps the previous reading" do
    reading = { "transactions" => [ { "date" => "2024-01-15", "amount" => "-50.00", "name" => "Coffee Shop" } ] }
    @import.update!(read_as: "auto", extracted_data: reading)
    @import.stubs(:pdf_uploaded?).returns(true)
    @import.stubs(:pdf_reading).returns(stub(ways: { images: nil }))
    ProcessPdfJob.stubs(:perform_later).raises(StandardError, "queue down")

    assert_equal :enqueue_failed, @import.reread!("images")

    @import.reload
    assert @import.pending?
    assert_equal "auto", @import.read_as
    assert_equal reading, @import.extracted_data
    assert_nil @import.reread_token
  end

  test "reading again is refused once anything is published" do
    @import.stubs(:imported_count).returns(3)

    assert_not @import.reread!("images")
    assert_raises(ArgumentError) { @import.reread!("fax") }
  end
end
