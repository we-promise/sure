# frozen_string_literal: true

require "test_helper"

class Api::V1::SyncsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.first

    Sync.for_family(@family).destroy_all

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    redis = Redis.new
    redis.del("api_rate_limit:#{@api_key.id}")
    redis.del("api_rate_limit:#{@read_only_api_key.id}")
    redis.close
  end

  test "lists family scoped syncs" do
    family_sync = Sync.create!(syncable: @family, status: "completed", completed_at: 1.hour.ago)
    account_sync = Sync.create!(syncable: @account, status: "syncing", syncing_at: Time.current)
    other_sync = Sync.create!(syncable: families(:empty), status: "completed", completed_at: 1.hour.ago)

    get api_v1_syncs_url, headers: api_headers(@read_only_api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    sync_ids = json_response["data"].map { |sync| sync["id"] }

    assert_includes sync_ids, family_sync.id
    assert_includes sync_ids, account_sync.id
    assert_not_includes sync_ids, other_sync.id
    assert_equal 2, json_response["meta"]["total_count"]
  end

  test "does not list account syncs outside caller account access" do
    private_account = @family.accounts.create!(
      owner: @user,
      name: "Private Sync Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    inaccessible_sync = Sync.create!(syncable: private_account, status: "completed", completed_at: 1.hour.ago)

    @read_only_api_key.update_column(:user_id, users(:family_member).id)

    get api_v1_syncs_url, headers: api_headers(@read_only_api_key)
    assert_response :success

    sync_ids = JSON.parse(response.body)["data"].map { |sync| sync["id"] }
    assert_not_includes sync_ids, inaccessible_sync.id
  end

  test "shows a sync" do
    sync = Sync.create!(
      syncable: @family,
      status: "completed",
      completed_at: 1.hour.ago,
      window_start_date: Date.current - 7.days,
      window_end_date: Date.current
    )

    get api_v1_sync_url(sync), headers: api_headers(@read_only_api_key)
    assert_response :success

    data = JSON.parse(response.body)["data"]
    assert_equal sync.id, data["id"]
    assert_equal "completed", data["status"]
    assert_equal false, data["in_progress"]
    assert_equal true, data["terminal"]
    assert_equal "Family", data["syncable"]["type"]
    assert_equal @family.id, data["syncable"]["id"]
    assert_nil data["error"]
  end

  test "returns latest sync" do
    Sync.create!(syncable: @family, status: "completed", created_at: 2.hours.ago, completed_at: 2.hours.ago)
    latest_sync = Sync.create!(syncable: @account, status: "pending", created_at: 1.minute.ago)

    get latest_api_v1_syncs_url, headers: api_headers(@read_only_api_key)
    assert_response :success

    assert_equal latest_sync.id, JSON.parse(response.body)["data"]["id"]
  end

  test "latest returns null data when no sync exists" do
    get latest_api_v1_syncs_url, headers: api_headers(@read_only_api_key)
    assert_response :success

    assert_nil JSON.parse(response.body)["data"]
  end

  test "does not expose raw sync errors" do
    sync = Sync.create!(
      syncable: @family,
      status: "failed",
      failed_at: Time.current,
      error: "provider token secret leaked"
    )

    get api_v1_sync_url(sync), headers: api_headers(@read_only_api_key)
    assert_response :success

    data = JSON.parse(response.body)["data"]
    assert data["error"].present?
    assert_equal "Sync failed", data["error"]["message"]
    refute_includes response.body, "provider token secret leaked"
  end

  test "reports failed sync errors as present without raw error text" do
    sync = Sync.create!(
      syncable: @family,
      status: "failed",
      failed_at: Time.current,
      error: nil
    )

    get api_v1_sync_url(sync), headers: api_headers(@read_only_api_key)
    assert_response :success

    assert JSON.parse(response.body).dig("data", "error").present?
    assert_equal "Sync failed", JSON.parse(response.body).dig("data", "error", "message")
  end

  test "omits stale sync error payload when no error is present" do
    sync = Sync.create!(
      syncable: @family,
      status: "stale"
    )

    get api_v1_sync_url(sync), headers: api_headers(@read_only_api_key)
    assert_response :success

    assert_nil JSON.parse(response.body).dig("data", "error")
  end

  test "returns not found for another family sync" do
    sync = Sync.create!(syncable: families(:empty), status: "completed")

    get api_v1_sync_url(sync), headers: api_headers(@read_only_api_key)
    assert_response :not_found

    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "returns not found for malformed sync id" do
    get api_v1_sync_url("not-a-uuid"), headers: api_headers(@read_only_api_key)
    assert_response :not_found

    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "index requires authentication" do
    get api_v1_syncs_url
    assert_response :unauthorized
  end

  test "latest requires authentication" do
    get latest_api_v1_syncs_url
    assert_response :unauthorized
  end

  test "show requires authentication" do
    sync = Sync.create!(syncable: @family, status: "completed", completed_at: 1.hour.ago)

    get api_v1_sync_url(sync)
    assert_response :unauthorized
  end

  test "index requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "monitoring",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_syncs_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
