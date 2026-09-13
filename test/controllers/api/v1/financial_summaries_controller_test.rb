require "test_helper"

class Api::V1::FinancialSummariesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @auth = ApiKey.create!(user: @user, name: "Summary Read", scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile")
    Redis.new.del("api_rate_limit:#{@auth.id}")
  end

  test "requires authentication" do
    get "/api/v1/financial_summary"
    assert_response :unauthorized
  end

  test "supports read and read_write and defaults to family month" do
    @user.family.update!(timezone: "Pacific Time (US & Canada)")
    travel_to Time.utc(2024, 3, 1, 1) do
      %w[read read_write].each do |scope|
        @auth.update!(scopes: [ scope ])
        get "/api/v1/financial_summary", headers: api_headers(@auth)
        assert_response :success
        body = response.parsed_body
        assert_equal "2024-02-01", body["month"]
        assert_equal "2024-02-29", body["as_of"]
        assert_equal "America/Los_Angeles", body["time_zone"]
        assert_equal 29, body.dig("spending_comparison", "current").size
      end
    end
  end

  test "rejects invalid and future periods" do
    [ "2024-02-02", "2024-13-01", "not-a-date", "9999-01-01", "" ].each do |month|
      get "/api/v1/financial_summary", params: { month: month }, headers: api_headers(@auth)
      assert_response :unprocessable_entity
      assert_equal "invalid_month", response.parsed_body["error"]
    end
  end

  test "summary uses the authenticated user's finance account selection" do
    month = Date.new(2024, 2, 1)
    own = @user.family.accounts.create!(name: "Own", owner: @user, currency: "USD", balance: 0, accountable: Depository.new)
    other = @user.family.users.where.not(id: @user.id).first!
    excluded = @user.family.accounts.create!(name: "Read only share", owner: other, currency: "USD", balance: 0, accountable: Depository.new)
    excluded.account_shares.create!(user: @user, permission: "read_only", include_in_finances: false)
    create_transaction(account: own, amount: 12, date: month)
    create_transaction(account: excluded, amount: 900, date: month)
    get "/api/v1/financial_summary", params: { month: month.iso8601 }, headers: api_headers(@auth)
    assert_response :success
    assert_equal "12.0", response.parsed_body["spending"]
    assert_equal "12.0", response.parsed_body.dig("spending_comparison", "current_total")
  end

  private
    def api_headers(auth)
      { "X-Api-Key" => auth.display_key }
    end
end
