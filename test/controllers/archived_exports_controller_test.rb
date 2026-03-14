require "test_helper"

class ArchivedExportsControllerTest < ActionDispatch::IntegrationTest
  test "redirects to file with valid token" do
    archive = ArchivedExport.create!(
      email: "test@example.com",
      family_name: "Test",
      expires_at: 30.days.from_now
    )
    archive.export_file.attach(
      io: StringIO.new("test zip content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    get archived_export_path(token: archive.download_token)
    assert_response :redirect
  end

  test "returns 410 gone for expired token" do
    archive = ArchivedExport.create!(
      email: "test@example.com",
      family_name: "Test",
      expires_at: 1.day.ago
    )
    archive.export_file.attach(
      io: StringIO.new("test zip content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    get archived_export_path(token: archive.download_token)
    assert_response :gone
  end

  test "returns 404 for invalid token" do
    assert_raises ActiveRecord::RecordNotFound do
      get archived_export_path(token: "nonexistent-token")
    end
  end

  test "does not require authentication" do
    archive = ArchivedExport.create!(
      email: "test@example.com",
      family_name: "Test",
      expires_at: 30.days.from_now
    )
    archive.export_file.attach(
      io: StringIO.new("test zip content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    # No sign_in call - should still work
    get archived_export_path(token: archive.download_token)
    assert_response :redirect
  end
end
