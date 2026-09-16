# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = accounts(:investment)
    @holding = holdings(:one)

    # An account owned by another family member, never shared with @user.
    @other_member = users(:family_member)
    @private_account = @family.accounts.create!(
      name: "Member Brokerage",
      accountable: Investment.new,
      balance: 5000,
      currency: "USD",
      owner: @other_member
    )
    @private_holding = @private_account.holdings.create!(
      security: securities(:msft),
      date: Date.current,
      qty: 5,
      price: 100,
      amount: 500,
      currency: "USD"
    )
  end

  test "lists holdings scoped to accessible accounts" do
    get api_v1_holdings_url, headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_includes holding_ids, @holding.id
    assert_not_includes holding_ids, @private_holding.id
  end

  test "account_ids filter cannot reach inaccessible accounts" do
    get api_v1_holdings_url,
        params: { account_ids: [ @private_account.id ] },
        headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_not_includes holding_ids, @private_holding.id
  end

  test "account_id filter cannot reach inaccessible accounts" do
    get api_v1_holdings_url,
        params: { account_id: @private_account.id },
        headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_not_includes holding_ids, @private_holding.id
  end

  test "shows an accessible holding" do
    get api_v1_holding_url(@holding), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @holding.id, response_data["id"]
  end

  test "returns not found for an inaccessible holding" do
    get api_v1_holding_url(@private_holding), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "requires authentication" do
    get api_v1_holdings_url

    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
