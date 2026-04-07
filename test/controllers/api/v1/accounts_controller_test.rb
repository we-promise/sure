# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    # Create fresh API keys instead of using fixtures to avoid parallel test conflicts (rate limiting)
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_key.id}")
  end

  test "can list accounts" do
    get api_v1_accounts_url, headers: api_headers

    assert_response :ok

    response_body = JSON.parse(response.body)
    assert response_body.key?("accounts")
    assert response_body["accounts"].is_a?(Array)
    assert response_body["accounts"].length > 0
  end

  test "can show account" do
    account = @family.accounts.visible.first

    get api_v1_account_url(account), headers: api_headers

    assert_response :ok

    response_body = JSON.parse(response.body)
    assert_equal account.id, response_body["id"]
    assert_equal account.name, response_body["name"]
    assert_equal account.currency, response_body["currency"]
    assert response_body.key?("balance")
    assert response_body.key?("classification")
    assert response_body.key?("account_type")
    assert response_body.key?("created_at")
    assert response_body.key?("updated_at")
  end

  test "returns 404 for unknown account" do
    get api_v1_account_url(id: SecureRandom.uuid), headers: api_headers

    assert_response :not_found

    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "returns 404 for account from another family" do
    other_family = families(:empty)
    other_account = Account.create!(
      family: other_family, name: "Other Account", currency: "USD",
      balance: 100, accountable: Depository.new
    )

    get api_v1_account_url(other_account), headers: api_headers

    assert_response :not_found
  end

  test "can create account" do
    assert_difference -> { @family.accounts.count }, 1 do
      post api_v1_accounts_url,
           params: { account: { name: "New Savings", accountable_type: "Depository", balance: 1000, currency: "USD" } },
           headers: api_headers
    end

    assert_response :created

    response_body = JSON.parse(response.body)
    assert_equal "New Savings", response_body["name"]
    assert_equal "USD", response_body["currency"]
    assert_equal "depository", response_body["account_type"]
    assert response_body.key?("id")
    assert response_body.key?("balance")
  end

  test "returns 422 for invalid account" do
    assert_no_difference -> { @family.accounts.count } do
      post api_v1_accounts_url,
           params: { account: { accountable_type: "Depository" } },
           headers: api_headers
    end

    assert_response :unprocessable_entity

    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
  end

  test "requires read_write scope for create" do
    assert_no_difference -> { @family.accounts.count } do
      post api_v1_accounts_url,
           params: { account: { name: "Blocked Account", accountable_type: "Depository" } },
           headers: api_headers(@read_key)
    end

    assert_response :forbidden
  end

  test "requires authentication for index" do
    get api_v1_accounts_url
    assert_response :unauthorized
  end

  test "requires authentication for show" do
    account = @family.accounts.visible.first
    get api_v1_account_url(account)
    assert_response :unauthorized
  end

  test "requires authentication for create" do
    assert_no_difference -> { @family.accounts.count } do
      post api_v1_accounts_url,
           params: { account: { name: "No Auth", accountable_type: "Depository" } }
    end
    assert_response :unauthorized
  end

  # UPDATE action tests

  test "can update account name" do
    account = @family.accounts.visible.first

    patch api_v1_account_url(account),
          params: { account: { name: "Updated Name" } },
          headers: api_headers

    assert_response :ok

    response_body = JSON.parse(response.body)
    assert_equal "Updated Name", response_body["name"]
    assert_equal account.id, response_body["id"]
  end

  test "can update account balance" do
    account = @family.accounts.visible.first

    patch api_v1_account_url(account),
          params: { account: { balance: 9999.99 } },
          headers: api_headers

    assert_response :ok
  end

  test "requires read_write scope for update" do
    account = @family.accounts.visible.first

    patch api_v1_account_url(account),
          params: { account: { name: "Should Fail" } },
          headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "returns 404 for updating non-existent account" do
    patch api_v1_account_url(id: SecureRandom.uuid),
          params: { account: { name: "Not Found" } },
          headers: api_headers

    assert_response :not_found
  end

  test "returns 404 for updating account from another family" do
    other_account = Account.create!(
      family: families(:empty), name: "Other Account", currency: "USD",
      balance: 100, accountable: Depository.new
    )

    patch api_v1_account_url(other_account),
          params: { account: { name: "Hijack" } },
          headers: api_headers

    assert_response :not_found
  end

  # DESTROY action tests

  test "can delete account" do
    account = Account.create!(
      family: @family, name: "Delete Me", currency: "USD",
      balance: 0, accountable: Depository.new
    )

    delete api_v1_account_url(account), headers: api_headers

    assert_response :ok

    response_body = JSON.parse(response.body)
    assert_equal "Account deleted successfully", response_body["message"]
  end

  test "requires read_write scope for destroy" do
    account = @family.accounts.visible.first

    delete api_v1_account_url(account), headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "returns 404 for deleting non-existent account" do
    delete api_v1_account_url(id: SecureRandom.uuid), headers: api_headers

    assert_response :not_found
  end

  test "returns 404 for deleting account from another family" do
    other_account = Account.create!(
      family: families(:empty), name: "Other Account", currency: "USD",
      balance: 100, accountable: Depository.new
    )

    delete api_v1_account_url(other_account), headers: api_headers

    assert_response :not_found
  end

  private

    def api_headers(key = @api_key)
      { "X-Api-Key" => key.display_key }
    end
end
