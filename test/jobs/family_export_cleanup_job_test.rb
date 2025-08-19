require "test_helper"

class FamilyExportCleanupJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @export = @family.family_exports.create!
    @filename = "test_export.zip"
  end

  test "performs cleanup for export with attached file" do
    # Attach a file to the export
    @export.export_file.attach(
      io: StringIO.new("test content"),
      filename: @filename,
      content_type: "application/zip"
    )

    # The job should complete without errors
    assert_nothing_raised do
      perform_enqueued_jobs do
        FamilyExportCleanupJob.perform_later(@export.id, @filename)
      end
    end
  end

  test "handles cleanup errors gracefully" do
    # Force an error by passing invalid data
    assert_nothing_raised do
      perform_enqueued_jobs do
        FamilyExportCleanupJob.perform_later(nil, @filename)
      end
    end
  end

  test "cleanup job is queued with correct parameters" do
    assert_enqueued_with(job: FamilyExportCleanupJob, args: [ @export.id, @export.filename ]) do
      FamilyExportCleanupJob.perform_later(@export.id, @export.filename)
    end
  end
end
