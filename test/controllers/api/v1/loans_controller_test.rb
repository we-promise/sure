require "test_helper"

class Api::V1::LoansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @user = @family.users.first
    @api_key = ApiKey.create!(user: @user, permissions: ["read"])

    @loan_account = Account.create! \
      family: @family,
      name: "Test Mortgage",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    @variable_loan_account = Account.create! \
      family: @family,
      name: "Variable Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "line_of_credit",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "variable"
      )
  end

  def api_headers
    { "X-Api-Key" => @api_key.plain_key }
  end

  test "returns amortization schedule for fixed rate loan" do
    get api_v1_account_amortization_schedule_path(@loan_account), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["schedule"].present?
    assert json["payments"].present?
    assert json["schedule"]["monthly_payment"].present?
    assert json["schedule"]["total_interest"].present?
    assert json["schedule"]["payoff_date"].present?
  end

  test "returns paginated payments" do
    get api_v1_account_amortization_schedule_path(@loan_account),
        params: { page: 1, per_page: 10 },
        headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 10, json["payments"].length
    assert json["pagination"]["total_count"] >= 360
    assert_equal 1, json["pagination"]["offset"]
  end

  test "returns error for variable rate loan" do
    get api_v1_account_amortization_schedule_path(@variable_loan_account),
        headers: api_headers
    assert_response :unprocessable_entity

    json = JSON.parse(response.body)
    assert_equal "not_amortizable", json["error"]
  end

  test "requires API key authentication" do
    get api_v1_account_amortization_schedule_path(@loan_account)
    assert_response :unauthorized
  end

  test "requires read scope" do
    write_only_key = ApiKey.create!(user: @user, permissions: ["write"])
    get api_v1_account_amortization_schedule_path(@loan_account),
        headers: { "X-Api-Key" => write_only_key.plain_key }
    assert_response :forbidden
  end

  test "respects account access control" do
    other_family = families(:family_two)
    other_user = other_family.users.first
    other_api_key = ApiKey.create!(user: other_user, permissions: ["read"])

    get api_v1_account_amortization_schedule_path(@loan_account),
        headers: { "X-Api-Key" => other_api_key.plain_key }
    assert_response :forbidden
  end

  test "returns 404 for non-existent account" do
    get api_v1_account_amortization_schedule_path("00000000-0000-0000-0000-000000000000"),
        headers: api_headers
    assert_response :not_found
  end
end
