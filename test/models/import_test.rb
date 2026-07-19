require "test_helper"

class ImportTest < ActiveSupport::TestCase
  test "publish skips imports in terminal statuses" do
    import = imports(:transaction)
    import.update_columns(status: "complete")

    import.expects(:import!).never

    import.publish

    assert_equal "complete", import.reload.status
  end

  test "publish skips imports that are reverting" do
    import = imports(:transaction)
    import.update_columns(status: "reverting")

    import.expects(:import!).never

    import.publish

    assert_equal "reverting", import.reload.status
  end

  test "clean fails stuck imports but leaves PdfImports to their own reclaim" do
    stuck_csv = imports(:transaction)
    stuck_csv.update_columns(status: "importing", updated_at: 7.hours.ago)

    stuck_pdf = imports(:pdf)
    stuck_pdf.update_columns(status: "importing", updated_at: 7.hours.ago)

    Import.clean

    assert_equal "failed", stuck_csv.reload.status
    assert_equal "importing", stuck_pdf.reload.status
  end

  test "clean leaves session-owned chunks to ImportSession.clean" do
    family = families(:dylan_family)
    session = family.import_sessions.create!(status: "importing")
    chunk = TransactionImport.create!(
      family: family,
      import_session: session,
      sequence: 1,
      checksum: Digest::SHA256.hexdigest("chunk"),
      status: "importing"
    )
    chunk.update_columns(updated_at: 7.hours.ago)

    Import.clean

    assert_equal "importing", chunk.reload.status
  end

  test "clean completes a stuck import whose data already committed" do
    stuck = imports(:transaction)
    stuck.update_columns(status: "importing", updated_at: 7.hours.ago)
    entries(:transaction).update_columns(import_id: stuck.id)

    Import.clean

    stuck.reload
    assert_equal "complete", stuck.status
    assert_nil stuck.error
  end

  test "clean moves a stuck revert to revert_failed" do
    stuck = imports(:transaction)
    stuck.update_columns(status: "reverting", updated_at: 7.hours.ago)

    Import.clean

    assert_equal "revert_failed", stuck.reload.status
  end

  test "PdfImport clean reclaims the AI claim but completes a committed publish" do
    ai_claim = imports(:pdf)
    ai_claim.update_columns(status: "importing", updated_at: 7.hours.ago)

    published = imports(:pdf_processed)
    published.update_columns(status: "importing", updated_at: 7.hours.ago)
    entries(:transaction).update_columns(import_id: published.id)

    PdfImport.clean

    assert_equal "pending", ai_claim.reload.status
    assert_equal "complete", published.reload.status
  end

  test "PdfImport clean moves a stuck revert to revert_failed" do
    stuck = imports(:pdf)
    stuck.update_columns(status: "reverting", updated_at: 7.hours.ago)

    PdfImport.clean

    assert_equal "revert_failed", stuck.reload.status
  end

  test "force_fail! refuses records that have not been idle long enough" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 5.minutes.ago)

    assert_not import.force_fail!
    assert_equal "importing", import.reload.status
  end

  test "force_fail! fails a lost import and keeps reverts retryable" do
    lost_import = imports(:transaction)
    lost_import.update_columns(status: "importing", updated_at: 2.hours.ago)

    assert lost_import.force_fail!
    assert_equal "failed", lost_import.reload.status
    assert_equal Import.lost_error_message, lost_import.error

    lost_revert = imports(:trade)
    lost_revert.update_columns(status: "reverting", updated_at: 2.hours.ago)

    assert lost_revert.force_fail!
    assert_equal "revert_failed", lost_revert.reload.status
  end

  test "force_fail! refuses terminal statuses" do
    import = imports(:transaction)
    import.update_columns(status: "complete", updated_at: 2.hours.ago)

    assert_not import.force_fail!
    assert_equal "complete", import.reload.status
  end

  test "force_fail! releases a lost PdfImport claim back to pending" do
    pdf = imports(:pdf)
    pdf.update_columns(status: "importing", updated_at: 2.hours.ago)

    assert pdf.force_fail!
    assert_equal "pending", pdf.reload.status
  end
end
