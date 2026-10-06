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
    assert response_body.key?("net_worth")
    assert response_body.key?("assets")
    assert response_body.key?("liabilities")

    %w[net_worth assets liabilities].each do |field|
      assert response_body[field].key?("amount"), "#{field} should have amount"
      assert response_body[field].key?("currency"), "#{field} should have currency"
      assert response_body[field].key?("formatted"), "#{field} should have formatted"
    end
  end

  test "should return availability with upcoming releases" do
    deposit = @family.accounts.create!(name: "Term deposit", balance: 2_500, currency: "USD",
                                       accountable: Depository.new(subtype: "cd"),
                                       liquidity_choice: "locked", available_on: Date.current + 30)

    get "/api/v1/balance_sheet", headers: api_headers(@auth)

    assert_response :success
    availability = JSON.parse(response.body).fetch("availability")

    %w[available_net_worth available_assets bound_assets short_term_liabilities].each do |field|
      assert availability[field].key?("amount"), "#{field} should have amount"
    end

    release = availability["upcoming_releases"].find { |r| r["account_id"] == deposit.id }
    assert_equal (Date.current + 30).iso8601, release["date"]
    assert_equal false, release["auto_renew"]
  end

  test "availability does not list another member's unshared accounts" do
    @family.accounts.create!(name: "Private deposit", balance: 1_000, currency: "USD",
                             owner: users(:family_member),
                             accountable: Depository.new(subtype: "cd"),
                             liquidity_choice: "locked", available_on: Date.current + 30)

    get "/api/v1/balance_sheet", headers: api_headers(@auth)

    assert_response :success
    names = JSON.parse(response.body).dig("availability", "upcoming_releases").map { |release| release["account_name"] }
    assert_not_includes names, "Private deposit"
  end

  private

    def api_headers(auth)
      { "X-Api-Key" => auth.display_key }
    end
end
