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
end
