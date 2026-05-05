# frozen_string_literal: true

require "test_helper"

class Api::V1::FamilyExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family

    @admin.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @admin,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_only_api_key = ApiKey.create!(
      user: @admin,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @member_api_key = ApiKey.create!(
      user: @member,
      name: "Member Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_member_#{SecureRandom.hex(8)}",
      source: "web"
    )

    redis = Redis.new
    redis.del("api_rate_limit:#{@api_key.id}")
    redis.del("api_rate_limit:#{@read_only_api_key.id}")
    redis.del("api_rate_limit:#{@member_api_key.id}")
    redis.close
  end

  test "lists family exports" do
    completed_export = @family.family_exports.create!(status: "completed")
    processing_export = @family.family_exports.create!(status: "processing")

    get api_v1_family_exports_url, headers: api_headers(@read_only_api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    export_ids = json_response["data"].map { |export| export["id"] }

    assert_includes export_ids, completed_export.id
    assert_includes export_ids, processing_export.id
    assert_equal @family.family_exports.count, json_response["meta"]["total_count"]
  end

  test "shows a family export" do
    export = @family.family_exports.create!(status: "completed")
    export.export_file.attach(
      io: StringIO.new("test zip content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    get api_v1_family_export_url(export), headers: api_headers(@read_only_api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal export.id, json_response["data"]["id"]
    assert_equal "completed", json_response["data"]["status"]
    assert_equal true, json_response["data"]["downloadable"]
    assert_equal download_api_v1_family_export_path(export), json_response["data"]["download_path"]
    assert_equal true, json_response["data"]["file"]["attached"]
    assert_equal "application/zip", json_response["data"]["file"]["content_type"]
  end

  test "creates a family export job" do
    assert_enqueued_with(job: FamilyDataExportJob) do
      assert_difference("@family.family_exports.count") do
        post api_v1_family_exports_url, headers: api_headers(@api_key)
      end
    end

    assert_response :accepted
    json_response = JSON.parse(response.body)
    export = FamilyExport.find(json_response["data"]["id"])

    assert_equal "pending", export.status
    assert_equal @family.id, export.family_id
  end

  test "read-only key cannot create a family export" do
    assert_no_difference("@family.family_exports.count") do
      post api_v1_family_exports_url, headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "create rejects unsupported params" do
    assert_no_difference("@family.family_exports.count") do
      post api_v1_family_exports_url,
           params: { family_export: { status: "completed" } },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_params", JSON.parse(response.body)["error"]
  end

  test "non-admin cannot access family exports" do
    get api_v1_family_exports_url, headers: api_headers(@member_api_key)
    assert_response :forbidden

    assert_equal "forbidden", JSON.parse(response.body)["error"]
  end

  test "returns not found for another family's export" do
    other_family = families(:empty)
    other_export = other_family.family_exports.create!(status: "completed")

    get api_v1_family_export_url(other_export), headers: api_headers(@read_only_api_key)
    assert_response :not_found

    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "returns not found for malformed export id" do
    get api_v1_family_export_url("not-a-uuid"), headers: api_headers(@read_only_api_key)
    assert_response :not_found

    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "download returns not found for malformed export id" do
    get download_api_v1_family_export_url("not-a-uuid"), headers: api_headers(@read_only_api_key)
    assert_response :not_found

    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "redirects completed export downloads to the attached file" do
    export = @family.family_exports.create!(status: "completed")
    export.export_file.attach(
      io: StringIO.new("test zip content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    get download_api_v1_family_export_url(export), headers: api_headers(@read_only_api_key)
    assert_response :redirect
    assert_includes response.location, "/rails/active_storage/blobs/redirect/"
    assert_includes response.location, "test.zip"
  end

  test "download returns conflict when export is not ready" do
    export = @family.family_exports.create!(status: "processing")

    get download_api_v1_family_export_url(export), headers: api_headers(@read_only_api_key)
    assert_response :conflict

    json_response = JSON.parse(response.body)
    assert_equal "export_not_ready", json_response["error"]
  end

  test "download handles storage URL failures without leaking details" do
    export = @family.family_exports.create!(status: "completed")
    export.export_file.attach(
      io: StringIO.new("test zip content"),
      filename: "test.zip",
      content_type: "application/zip"
    )

    Api::V1::FamilyExportsController.any_instance
      .stubs(:rails_blob_url)
      .raises(StandardError, "storage down")

    get download_api_v1_family_export_url(export), headers: api_headers(@read_only_api_key)
    assert_response :internal_server_error

    json_response = JSON.parse(response.body)
    assert_equal "internal_server_error", json_response["error"]
    assert_equal "An unexpected error occurred", json_response["message"]
    assert_not_includes response.body, "storage down"
  end

  test "requires authentication" do
    get api_v1_family_exports_url
    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
