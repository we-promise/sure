require "test_helper"

class ArchivedExportsControllerTest < ActionDispatch::IntegrationTest
  test "sends the file with a valid token" do
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
    assert_response :success
    assert_equal "test zip content", response.body
    assert_equal "application/zip", response.media_type
    assert_match(/\Aattachment; filename="test.zip"/, response.headers["Content-Disposition"])
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
    get archived_export_path(token: "nonexistent-token")
    assert_response :not_found
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
    assert_response :success
    assert_equal "test zip content", response.body
  end

  test "blob routes do not serve archived exports to signed-in users" do
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

    sign_in users(:family_admin)
    get rails_blob_path(archive.export_file)

    assert_response :not_found
  end

  test "returns not found when the archive file is missing from storage" do
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
    ActiveStorage::Blob.any_instance.stubs(:download).raises(ActiveStorage::FileNotFoundError)

    get archived_export_path(token: archive.download_token)

    assert_response :not_found
  end
end
