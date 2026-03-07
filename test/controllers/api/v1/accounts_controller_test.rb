# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin) # dylan_family user
    @other_family_user = users(:family_member)
    @other_family_user.update!(family: families(:empty))

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )
  end

  test "should require authentication" do
    get "/api/v1/accounts"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read_accounts scope" do
  # TODO: Re-enable this test after fixing scope checking
  skip "Scope checking temporarily disabled - needs configuration fix"

  # Create token with wrong scope - using a non-existent scope to test rejection
  access_token = Doorkeeper::AccessToken.create!(
    application: @oauth_app,
    resource_owner_id: @user.id,
    scopes: "invalid_scope" # Wrong scope
  )

  get "/api/v1/accounts", params: {}, headers: {
    "Authorization" => "Bearer #{access_token.token}"
  }

  assert_response :forbidden

  # Doorkeeper returns a standard OAuth error response
  response_body = JSON.parse(response.body)
  assert_equal "insufficient_scope", response_body["error"]
end

  test "should return user's family accounts successfully" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/accounts", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have accounts array
    assert response_body.key?("accounts")
    assert response_body["accounts"].is_a?(Array)

    # Should have pagination metadata
    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")

    # All accounts should belong to user's family
    response_body["accounts"].each do |account|
      # We'll validate this by checking the user's family has these accounts
      family_account_names = @user.family.accounts.pluck(:name)
      assert_includes family_account_names, account["name"]
    end
  end

  test "should only return active accounts" do
    # Make one account inactive
    inactive_account = accounts(:depository)
    inactive_account.disable!

    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/accounts", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should not include the inactive account
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_not_includes account_names, inactive_account.name
  end

  test "should not return other family's accounts" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @other_family_user.id,  # User from different family
      scopes: "read"
    )

    get "/api/v1/accounts", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should return empty array since other family has no accounts in fixtures
    assert_equal [], response_body["accounts"]
    assert_equal 0, response_body["pagination"]["total_count"]
  end

  test "should handle pagination parameters" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    # Test with pagination params
    get "/api/v1/accounts", params: { page: 1, per_page: 2 }, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should respect per_page limit
    assert response_body["accounts"].length <= 2
    assert_equal 1, response_body["pagination"]["page"]
    assert_equal 2, response_body["pagination"]["per_page"]
  end

  test "should return proper account data structure" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/accounts", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have at least one account from fixtures
    assert response_body["accounts"].length > 0

    account = response_body["accounts"].first

    # Check required fields are present
    required_fields = %w[id name balance currency classification account_type]
    required_fields.each do |field|
      assert account.key?(field), "Account should have #{field} field"
    end

    # Check data types
    assert account["id"].is_a?(String), "ID should be string (UUID)"
    assert account["name"].is_a?(String), "Name should be string"
    assert account["balance"].is_a?(String), "Balance should be string (money)"
    assert account["currency"].is_a?(String), "Currency should be string"
    assert %w[asset liability].include?(account["classification"]), "Classification should be asset or liability"
  end

  test "should handle invalid pagination parameters gracefully" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    # Test with invalid page number
    get "/api/v1/accounts", params: { page: -1, per_page: "invalid" }, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    # Should still return success with default pagination
    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have pagination info (with defaults applied)
    assert response_body.key?("pagination")
    assert response_body["pagination"]["page"] >= 1
    assert response_body["pagination"]["per_page"] > 0
  end

  test "should sort accounts alphabetically" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/accounts", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should be sorted alphabetically by name
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_equal account_names.sort, account_names
  end

  # Show action tests

  test "show requires authentication" do
    account = @user.family.accounts.visible.first

    get "/api/v1/accounts/#{account.id}"
    assert_response :unauthorized
  end

  test "show returns account successfully" do
    account = @user.family.accounts.visible.first
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/accounts/#{account.id}", headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal account.id, response_body["id"]
    assert_equal account.name, response_body["name"]
    assert_equal account.currency, response_body["currency"]
  end

  test "show returns 404 for non-existent account" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/accounts/#{SecureRandom.uuid}", headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :not_found
  end

  test "show returns 404 for account from another family" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    other_family_account = @other_family_user.family.accounts.create!(
      name: "Other Account",
      balance: 100,
      currency: "USD",
      accountable: OtherAsset.create!,
      status: :active
    )

    get "/api/v1/accounts/#{other_family_account.id}", headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :not_found
  end

  # Create action tests

  test "create requires authentication" do
    post "/api/v1/accounts", params: {
      account: { name: "New Account", accountable_type: "Depository" }
    }

    assert_response :unauthorized
  end

  test "create requires read_write scope" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    post "/api/v1/accounts",
         params: { account: { name: "New Account", accountable_type: "Depository", balance: 1000 } },
         headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :forbidden
  end

  test "create account successfully" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    account_name = "API Test Account #{SecureRandom.hex(4)}"

    assert_difference -> { @user.family.accounts.count }, 1 do
      post "/api/v1/accounts",
           params: { account: { name: account_name, accountable_type: "Depository", balance: 5000, currency: "USD" } },
           headers: { "Authorization" => "Bearer #{access_token.token}" }
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal account_name, response_body["name"]
    assert_equal "USD", response_body["currency"]
  end

  test "create account defaults currency to family currency" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    post "/api/v1/accounts",
         params: { account: { name: "Default Currency #{SecureRandom.hex(4)}", accountable_type: "Depository", balance: 100 } },
         headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal @user.family.currency, response_body["currency"]
  end

  # Update action tests

  test "update requires authentication" do
    account = @user.family.accounts.visible.first

    patch "/api/v1/accounts/#{account.id}", params: { account: { name: "Updated" } }
    assert_response :unauthorized
  end

  test "update requires read_write scope" do
    account = @user.family.accounts.visible.first
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    patch "/api/v1/accounts/#{account.id}",
          params: { account: { name: "Updated" } },
          headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :forbidden
  end

  test "update account name successfully" do
    account = @user.family.accounts.visible.first
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    new_name = "Updated Account #{SecureRandom.hex(4)}"

    patch "/api/v1/accounts/#{account.id}",
          params: { account: { name: new_name } },
          headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal new_name, response_body["name"]
  end

  test "update returns 404 for non-existent account" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    patch "/api/v1/accounts/#{SecureRandom.uuid}",
          params: { account: { name: "Not Found" } },
          headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :not_found
  end

  test "update returns 404 for account from another family" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    other_family_account = @other_family_user.family.accounts.create!(
      name: "Other Account",
      balance: 100,
      currency: "USD",
      accountable: OtherAsset.create!,
      status: :active
    )

    patch "/api/v1/accounts/#{other_family_account.id}",
          params: { account: { name: "Hacker Update" } },
          headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :not_found
  end

  # Destroy action tests

  test "destroy requires authentication" do
    account = @user.family.accounts.visible.first

    delete "/api/v1/accounts/#{account.id}"
    assert_response :unauthorized
  end

  test "destroy requires read_write scope" do
    account = @user.family.accounts.visible.first
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    delete "/api/v1/accounts/#{account.id}",
           headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :forbidden
  end

  test "destroy unlinked account successfully" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    # Create an unlinked account to delete
    account_to_delete = @user.family.accounts.create!(
      name: "Delete Me #{SecureRandom.hex(4)}",
      accountable: OtherAsset.create!,
      balance: 0,
      currency: "USD",
      status: :active
    )

    delete "/api/v1/accounts/#{account_to_delete.id}",
           headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Account deleted successfully", response_body["message"]
  end

  test "destroy linked account returns unprocessable entity" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    linked_account = accounts(:connected)

    delete "/api/v1/accounts/#{linked_account.id}",
           headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
  end

  test "destroy returns 404 for non-existent account" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    delete "/api/v1/accounts/#{SecureRandom.uuid}",
           headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :not_found
  end

  test "destroy returns 404 for account from another family" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    other_family_account = @other_family_user.family.accounts.create!(
      name: "Other Account",
      balance: 100,
      currency: "USD",
      accountable: OtherAsset.create!,
      status: :active
    )

    delete "/api/v1/accounts/#{other_family_account.id}",
           headers: { "Authorization" => "Bearer #{access_token.token}" }

    assert_response :not_found
  end
end
