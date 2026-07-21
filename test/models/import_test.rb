require "test_helper"

class ImportTest < ActiveSupport::TestCase
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
