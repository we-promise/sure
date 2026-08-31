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

    @non_amortizable_loan_account = Account.create! \
      family: @family,
      name: "No Rate Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "other",
        interest_rate: nil,
        term_months: 360,
        rate_type: "fixed"
      )
  end

  def api_headers(api_key = @api_key)
    { "X-Api-Key" => api_key.plain_key }
  end

  test "returns amortization schedule for fixed rate loan" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal loan.id, json["loan"]["id"]
    assert_equal loan.account.id, json["loan"]["account_id"]
    assert json["schedule"].present?
    assert json["payments"].present?
    assert json["schedule"]["monthly_payment"].present?
    assert json["schedule"]["total_interest"].present?
    assert json["schedule"]["payoff_date"].present?
  end

  test "returns paginated payments" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        params: { page: 1, per_page: 10 },
        headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 10, json["payments"].length
    assert json["pagination"]["total_count"] >= 360
    assert_equal 0, json["pagination"]["offset"]
  end

  test "lazily builds the schedule on first read, then reuses it on later reads" do
    loan = @loan_account.accountable
    # Loan.create! commonly runs before the loan has an account (it's created
    # standalone, then passed into Account.create!(accountable: loan)), so
    # the schedule isn't built until something actually needs it.
    assert_equal 0, loan.amortizations.count

    assert_difference -> { loan.amortizations.count }, 360 do
      get api_v1_loan_amortization_schedule_path(loan),
          params: { page: 1, per_page: 5 },
          headers: api_headers
    end
    assert_response :success

    # Later reads shouldn't rebuild -- cost scales with the page, not the term
    assert_no_difference -> { loan.amortizations.count } do
      get api_v1_loan_amortization_schedule_path(loan),
          params: { page: 2, per_page: 5 },
          headers: api_headers
    end
    assert_response :success
  end

  test "rebuilds the persisted schedule when loan terms change" do
    loan = @loan_account.accountable
    loan.rebuild_amortization_schedule
    assert_equal 360, loan.amortizations.count
    original_payment = loan.amortizations.ordered.first.payment_amount

    loan.update!(interest_rate: 5.0)

    assert_equal 360, loan.amortizations.count
    assert_not_equal original_payment, loan.amortizations.ordered.first.payment_amount
  end

  test "gracefully rejects malformed pagination params instead of erroring" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        params: { page: [ 1, 2 ], per_page: [ "x" ] },
        headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 25, json["pagination"]["limit"]
    assert_equal 0, json["pagination"]["offset"]
  end

  test "returns 404 for a malformed loan id instead of erroring" do
    get api_v1_loan_amortization_schedule_path("not-a-valid-uuid"),
        headers: api_headers
    assert_response :not_found
  end

  test "returns amortization schedule for variable rate loan using the flat rate" do
    loan = @variable_loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["schedule"].present?
    assert json["payments"].present?
    assert_equal loan.interest_rate.to_f, json["payments"].first["interest_rate"].to_f
  end

  test "returns amortization schedule for variable rate loan with rate changes" do
    loan = @variable_loan_account.accountable
    loan.add_variable_rate_change(Date.current - 1.year, 3.5)
    loan.add_variable_rate_change(Date.current + 1.year, 4.0)

    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["schedule"].present?
    assert json["payments"].present?
  end

  test "returns error for loan without an interest rate" do
    loan = @non_amortizable_loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        headers: api_headers
    assert_response :unprocessable_entity

    json = JSON.parse(response.body)
    assert_equal "not_amortizable", json["error"]
  end

  test "requires API key authentication" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan)
    assert_response :unauthorized
  end

  test "requires read scope" do
    write_only_key = ApiKey.create!(user: @user, permissions: ["write"])
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        headers: api_headers(write_only_key)
    assert_response :forbidden
  end

  test "respects account access control" do
    other_family = families(:family_two)
    other_user = other_family.users.first
    other_api_key = ApiKey.create!(user: other_user, permissions: ["read"])

    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        headers: api_headers(other_api_key)
    assert_response :forbidden
  end

  test "returns 404 for non-existent loan" do
    get api_v1_loan_amortization_schedule_path("00000000-0000-0000-0000-000000000000"),
        headers: api_headers
    assert_response :not_found
  end
end
