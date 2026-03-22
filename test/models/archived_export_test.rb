require "test_helper"

class ArchivedExportTest < ActiveSupport::TestCase
  test "downloadable? returns true when not expired and file attached" do
    archive = ArchivedExport.create!(
      email: "test@example.com",
      family_name: "Test",
      expires_at: 30.days.from_now
    )
    archive.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    assert archive.downloadable?
  end

  test "downloadable? returns false when expired" do
    archive = ArchivedExport.create!(
      email: "test@example.com",
      family_name: "Test",
      expires_at: 1.day.ago
    )
    archive.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    assert_not archive.downloadable?
  end

  test "downloadable? returns false when file not attached" do
    archive = ArchivedExport.create!(
      email: "test@example.com",
      family_name: "Test",
      expires_at: 30.days.from_now
    )

    assert_not archive.downloadable?
  end

  test "expired scope returns only expired records" do
    expired = ArchivedExport.create!(
      email: "expired@example.com",
      family_name: "Expired",
      expires_at: 1.day.ago
    )
    active = ArchivedExport.create!(
      email: "active@example.com",
      family_name: "Active",
      expires_at: 30.days.from_now
    )

    results = ArchivedExport.expired
    assert_includes results, expired
    assert_not_includes results, active
  end

  test "generates download_token automatically" do
    archive = ArchivedExport.create!(
      email: "test@example.com",
      family_name: "Test",
      expires_at: 30.days.from_now
    )

    assert archive.download_token.present?
  end
end
