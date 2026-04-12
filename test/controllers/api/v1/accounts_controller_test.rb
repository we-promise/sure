# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    @api_key = api_keys(:active_key) # pipelock:ignore Credential in URL
    @read_key = api_keys(:read_only_key) # pipelock:ignore Credential in URL
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

  private

    def api_headers(key = @api_key)
      { "X-Api-Key" => key.display_key }
    end
end
