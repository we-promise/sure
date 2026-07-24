require "test_helper"

class FamilyExportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @export = @family.family_exports.create!
  end

  test "belongs to family" do
    assert_equal @family, @export.family
  end

  test "has default status of pending" do
    assert_equal "pending", @export.status
  end

  test "force_fail! fails a lost export but refuses fresh or terminal ones" do
    @export.update_columns(status: "processing", updated_at: 2.hours.ago)
    assert @export.force_fail!
    assert_equal "failed", @export.reload.status

    fresh = @family.family_exports.create!
    fresh.update_columns(status: "processing", updated_at: 5.minutes.ago)
    assert_not fresh.force_fail!
    assert_equal "processing", fresh.reload.status

    assert_not @export.force_fail!
    assert_equal "failed", @export.reload.status
  end

  test "can have export file attached" do
    @export.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    assert @export.export_file.attached?
    assert_equal "test.zip", @export.export_file.filename.to_s
    assert_equal "application/zip", @export.export_file.content_type
  end

  test "filename is generated correctly" do
    travel_to Time.zone.local(2024, 1, 15, 14, 30, 0) do
      export = @family.family_exports.create!
      expected_filename = "sure_export_20240115_143000.zip"
      assert_equal expected_filename, export.filename
    end
  end

  test "downloadable? returns true for completed export with file" do
    @export.update!(status: "completed")
    @export.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    assert @export.downloadable?
  end

  test "downloadable? returns false for pending export" do
    @export.update!(status: "pending")
    @export.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    assert_not @export.downloadable?
  end

  test "downloadable? returns false for completed export without file" do
    @export.update!(status: "completed")

    assert_not @export.downloadable?
  end

  test "downloadable? returns false for failed export with file" do
    @export.update!(status: "failed")
    @export.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    assert_not @export.downloadable?
  end

  test "export file is purged when export is destroyed" do
    @export.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    # Verify file is attached
    assert @export.export_file.attached?
    file_id = @export.export_file.id
    blob_id = @export.export_file.blob.id

    # Destroy the export
    @export.destroy!

    # Verify the export record is gone
    assert_not FamilyExport.exists?(@export.id)

    # Verify the Active Storage attachment is gone
    assert_not ActiveStorage::Attachment.exists?(file_id)

    # Note: Active Storage purges blobs asynchronously with dependent: :purge_later
    # In tests, we can verify the attachment is gone, which is the immediate effect
    # The blob will be purged in the background
  end

  test "can transition through statuses" do
    assert_equal "pending", @export.status

    @export.processing!
    assert_equal "processing", @export.status

    @export.completed!
    assert_equal "completed", @export.status

    @export.failed!
    assert_equal "failed", @export.status
  end

  test "ordered scope returns exports in descending order" do
    # Clear existing exports to avoid interference
    @family.family_exports.destroy_all

    # Create exports with specific timestamps
    old_export = @family.family_exports.create!
    old_export.update_column(:created_at, 2.days.ago)

    new_export = @family.family_exports.create!
    new_export.update_column(:created_at, 1.day.ago)

    ordered_exports = @family.family_exports.ordered.to_a
    assert_equal 2, ordered_exports.length
    assert_equal new_export.id, ordered_exports.first.id
    assert_equal old_export.id, ordered_exports.last.id
  end

  test "clean isolates a record whose update! fails so the sweep does not abort" do
    @export.update_columns(status: "processing", updated_at: 3.hours.ago)

    # A validation/DB error on one stuck record must not abort the sweep for
    # the rest (mirrors Import.clean's per-record rescue).
    FamilyExport.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(FamilyExport.new))

    assert_nothing_raised { FamilyExport.clean }
    assert_equal "processing", @export.reload.status
  end
end
