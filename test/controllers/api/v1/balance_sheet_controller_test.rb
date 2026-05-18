# frozen_string_literal: true

require "test_helper"

class Api::V1::BalanceSheetControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    @user.api_keys.active.destroy_all

    @auth = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@auth.id}")
  end

  test "should require authentication" do
    get "/api/v1/balance_sheet"
    assert_response :unauthorized
  end

  test "should return balance sheet with net worth data" do
    get "/api/v1/balance_sheet", headers: api_headers(@auth)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body.key?("currency")
    assert response_body.key?("include_disabled")
    assert_equal false, response_body["include_disabled"]
    assert response_body.key?("net_worth")
    assert response_body.key?("assets")
    assert response_body.key?("liabilities")

    %w[net_worth assets liabilities].each do |field|
      assert response_body[field].key?("amount"), "#{field} should have amount"
      assert response_body[field].key?("currency"), "#{field} should have currency"
      assert response_body[field].key?("formatted"), "#{field} should have formatted"
    end
  end

  test "should include disabled account totals when requested" do
    disabled_account = @family.accounts.create!(
      name: "Disabled Savings",
      accountable: Depository.new,
      balance: 500,
      currency: "USD"
    )
    disabled_account.disable!

    get "/api/v1/balance_sheet", headers: api_headers(@auth)
    assert_response :success
    default_assets = JSON.parse(response.body).dig("assets", "amount").to_d

    get "/api/v1/balance_sheet", params: { include_disabled: true }, headers: api_headers(@auth)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal true, response_body["include_disabled"]
    assert_equal BigDecimal("500"), response_body.dig("assets", "amount").to_d - default_assets
  end

  private

    def api_headers(auth)
      { "X-Api-Key" => auth.display_key }
    end
end
