require "test_helper"

class SyncCleanerJobTest < ActiveSupport::TestCase
  test "reaps records stuck by lost jobs and spares fresh ones" do
    stuck_import = imports(:transaction)
    stuck_import.update_columns(status: "importing", updated_at: 7.hours.ago)

    stuck_revert = imports(:trade)
    stuck_revert.update_columns(status: "reverting", updated_at: 7.hours.ago)

    stuck_pdf = imports(:pdf)
    stuck_pdf.update_columns(status: "importing", updated_at: 7.hours.ago)

    stuck_export = FamilyExport.create!(family: families(:dylan_family))
    stuck_export.update_columns(status: "processing", updated_at: 3.hours.ago)

    stuck_session = families(:dylan_family).import_sessions.create!(status: :importing)
    stuck_session.update_columns(updated_at: 7.hours.ago)

    fresh_import = imports(:account)
    fresh_import.update_columns(status: "importing", updated_at: 1.hour.ago)

    fresh_export = FamilyExport.create!(family: families(:dylan_family))
    fresh_export.update_columns(status: "processing", updated_at: 30.minutes.ago)

    SyncCleanerJob.perform_now

    assert_equal "failed", stuck_import.reload.status
    assert_equal Import.interrupted_error_message, stuck_import.error

    assert_equal "revert_failed", stuck_revert.reload.status

    # PdfImport's importing status is a processing claim — reclaimed, not failed
    assert_equal "pending", stuck_pdf.reload.status

    assert_equal "failed", stuck_export.reload.status
    assert_equal "failed", stuck_session.reload.status
    assert_equal "import_interrupted", stuck_session.error_details["code"]

    assert_equal "importing", fresh_import.reload.status
    assert_equal "processing", fresh_export.reload.status
  end

  test "clears provider activity fetch flags stuck by lost job chains" do
    stuck = snaptrade_accounts(:fidelity_401k)
    stuck.update_columns(activities_fetch_pending: true, updated_at: 7.hours.ago)

    SyncCleanerJob.perform_now

    assert_not stuck.reload.activities_fetch_pending
  end

  test "a failing sweep does not block the others" do
    Sync.expects(:clean).raises(StandardError.new("boom"))

    stuck_export = FamilyExport.create!(family: families(:dylan_family))
    stuck_export.update_columns(status: "processing", updated_at: 3.hours.ago)

    assert_nothing_raised do
      SyncCleanerJob.perform_now
    end

    assert_equal "failed", stuck_export.reload.status
  end

  test "reaped records are captured as debug log entries" do
    stuck_import = imports(:transaction)
    stuck_import.update_columns(status: "importing", updated_at: 7.hours.ago)

    assert_difference "DebugLogEntry.count", 1 do
      SyncCleanerJob.perform_now
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "background_jobs", entry.category
    assert_equal stuck_import.family, entry.family
    assert_equal stuck_import.id, entry.metadata["record_id"]
  end

  test "activity-flag sweep isolates a failing model so later models still run" do
    snaptrade = snaptrade_accounts(:fidelity_401k)
    snaptrade.update_columns(activities_fetch_pending: true, updated_at: 7.hours.ago)

    questrade = questrade_accounts(:one)
    questrade.update_columns(activities_fetch_pending: true, updated_at: 7.hours.ago)

    # SnaptradeAccount is swept before QuestradeAccount; a failing update! on a
    # Snaptrade record must not skip the models that follow it.
    SnaptradeAccount.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(SnaptradeAccount.new))

    assert_nothing_raised { SyncCleanerJob.perform_now }

    assert snaptrade.reload.activities_fetch_pending      # rolled back, still stuck
    assert_not questrade.reload.activities_fetch_pending  # still cleared
  end
end
