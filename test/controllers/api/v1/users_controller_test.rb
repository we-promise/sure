# frozen_string_literal: true

require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )
  end

  # -- Authentication --------------------------------------------------------

  test "reset requires authentication" do
    delete "/api/v1/users/reset"
    assert_response :unauthorized
  end

  test "destroy requires authentication" do
    delete "/api/v1/users/me"
    assert_response :unauthorized
  end

  # -- Scope enforcement -----------------------------------------------------

  test "reset requires write scope" do
    delete "/api/v1/users/reset", headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "destroy requires write scope" do
    delete "/api/v1/users/me", headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  # -- Reset -----------------------------------------------------------------


  test "reset requires admin role" do
    non_admin_api_key = ApiKey.create!(
      user: users(:family_member),
      name: "Member Read-Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_member_#{SecureRandom.hex(8)}"
    )

    assert_no_enqueued_jobs only: FamilyResetJob do
      delete "/api/v1/users/reset", headers: api_headers(non_admin_api_key)
    end

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "You are not authorized to perform this action", body["message"]
  end

  test "reset enqueues FamilyResetJob and returns 200" do
    assert_enqueued_with(job: FamilyResetJob, args: [ @user.family ]) do
      delete "/api/v1/users/reset", headers: api_headers(@api_key)
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Account reset has been initiated", body["message"]
    assert_equal "queued", body["status"]
    assert_equal @user.family.id, body["family_id"]
    assert body["job_id"].present?
    assert_equal "/api/v1/users/reset/status", body["status_url"]
  end

  test "reset returns controlled error when enqueue fails" do
    FamilyResetJob.stub(:perform_later, ->(_family) { raise StandardError, "queue down" }) do
      delete "/api/v1/users/reset", headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    body = JSON.parse(response.body)
    assert_equal "reset_enqueue_failed", body["error"]
    assert_equal "Account reset could not be queued", body["message"]
    assert_not_includes response.body, "queue down"
  end

  test "reset status requires authentication" do
    get "/api/v1/users/reset/status"
    assert_response :unauthorized
  end

  test "reset status requires admin role" do
    non_admin_api_key = ApiKey.create!(
      user: users(:family_member),
      name: "Member Read Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_member_read_#{SecureRandom.hex(8)}"
    )

    get "/api/v1/users/reset/status", headers: api_headers(non_admin_api_key)

    assert_response :forbidden
  end

  test "reset status returns family data counts" do
    get "/api/v1/users/reset/status", headers: api_headers(@read_only_api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @user.family.id, body["family_id"]
    assert_includes %w[complete data_remaining], body["status"]
    assert_equal body["counts"].values.sum.zero?, body["reset_complete"]
    assert body["counts"].key?("accounts")
    assert body["counts"].key?("categories")
    assert body["counts"].key?("tags")
    assert body["counts"].key?("merchants")
    assert body["counts"].key?("plaid_items")
    assert body["counts"].key?("imports")
    assert body["counts"].key?("budgets")
  end

  # -- Delete account --------------------------------------------------------

  test "destroy deactivates user and returns 200" do
    solo_family = Family.create!(name: "Solo Family", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
    solo_user = solo_family.users.create!(
      email: "solo@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :admin
    )
    solo_api_key = ApiKey.create!(
      user: solo_user,
      name: "Solo Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_solo_#{SecureRandom.hex(8)}"
    )

    delete "/api/v1/users/me", headers: api_headers(solo_api_key)
    assert_response :ok

    body = JSON.parse(response.body)
    assert_equal "Account has been deleted", body["message"]

    solo_user.reload
    assert_not solo_user.active?
    assert_not_equal "solo@example.com", solo_user.email
  end

  test "destroy returns 422 when admin has other family members" do
    delete "/api/v1/users/me", headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    body = JSON.parse(response.body)
    assert_equal "Failed to delete account", body["error"]
  end

  # -- Deactivated user ------------------------------------------------------

  test "rejects deactivated user with 401" do
    @user.update_column(:active, false)

    delete "/api/v1/users/reset", headers: api_headers(@api_key)
    assert_response :unauthorized

    body = JSON.parse(response.body)
    assert_equal "Account has been deactivated", body["message"]
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
