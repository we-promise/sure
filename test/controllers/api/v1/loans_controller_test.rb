require "test_helper"

class Api::V1::LoansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @api_key = ApiKey.create!(
      user: @user,
      name: "Loan API Test Key",
      scopes: [ "read" ],
      source: "web",
      key: ApiKey.generate_secure_key
    )

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
    @loan_account.accountable.rebuild_amortization_schedule

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
    @variable_loan_account.accountable.rebuild_amortization_schedule

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
    { "X-Api-Key" => api_key.display_key }
  end

  test "returns amortization schedule for fixed rate loan" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal loan.id, json["loan"]["id"]
    assert_equal loan.account.id, json["loan"]["account_id"]
    assert_equal "current", json["schedule"]["status"]
    assert json["payments"].present?
    assert json["schedule"]["monthly_payment"].present?
    assert json["schedule"]["total_interest"].present?
    assert json["schedule"]["payoff_date"].present?
    assert_kind_of String, json["payments"].first["payment_amount"]
    assert_kind_of String, json["payments"].first["principal_payment"]
    assert_kind_of String, json["payments"].first["interest_payment"]
    assert_kind_of String, json["payments"].first["interest_rate"]
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

  test "a read-scoped request never mutates the database, even for a never-built schedule" do
    loan = @non_amortizable_loan_account.accountable
    loan.update_column(:interest_rate, 3.5) # make it amortizable without going through the save callback
    assert_equal 0, loan.amortizations.count

    assert_no_difference -> { loan.reload.amortizations.count } do
      assert_enqueued_with(job: LoanAmortizationRebuildJob, args: [ loan.id ]) do
        get api_v1_loan_amortization_schedule_path(loan),
            params: { page: 1, per_page: 5 },
            headers: api_headers
      end
    end
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "missing", json["schedule"]["status"]
    assert_equal [], json["payments"]
  end

  test "lazily builds the schedule in the background on first read, then reuses it on later reads" do
    loan = @non_amortizable_loan_account.accountable
    loan.update_column(:interest_rate, 3.5)
    assert_equal 0, loan.amortizations.count

    get api_v1_loan_amortization_schedule_path(loan),
        params: { page: 1, per_page: 5 },
        headers: api_headers
    assert_response :success
    assert_equal "missing", JSON.parse(response.body)["schedule"]["status"]
    assert_equal 0, loan.amortizations.count

    perform_enqueued_jobs
    assert_equal 360, loan.amortizations.count

    # Later reads shouldn't rebuild -- cost scales with the page, not the term
    assert_no_enqueued_jobs do
      get api_v1_loan_amortization_schedule_path(loan),
          params: { page: 2, per_page: 5 },
          headers: api_headers
    end
    assert_response :success
    assert_equal "current", JSON.parse(response.body)["schedule"]["status"]
  end

  test "serves the last known-good schedule and reports it stale when loan terms change" do
    loan = @loan_account.accountable
    original_payment = loan.amortizations.ordered.first.payment_amount

    loan.update!(interest_rate: 5.0) # enqueues a rebuild but does not run it inline

    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "stale", json["schedule"]["status"]
    assert_equal original_payment.to_s, json["payments"].first["payment_amount"]

    perform_enqueued_jobs
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

  test "bounds an excessively large page number" do
    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        params: { page: 2_000_000 },
        headers: api_headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal (Api::V1::LoansController::MAX_PAGE - 1) * 25, json["pagination"]["offset"]
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
    assert_equal "current", json["schedule"]["status"]
    assert json["payments"].present?
    assert_equal loan.interest_rate.to_f, json["payments"].first["interest_rate"].to_f
  end

  test "returns amortization schedule for variable rate loan with rate changes" do
    loan = @variable_loan_account.accountable
    loan.add_variable_rate_change(Date.current - 1.year, 3.5)
    loan.add_variable_rate_change(Date.current + 1.year, 4.0)
    perform_enqueued_jobs

    get api_v1_loan_amortization_schedule_path(loan), headers: api_headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "current", json["schedule"]["status"]
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

  test "returns 404, not 403, for a loan belonging to another family" do
    other_user = users(:empty) # admin of the `empty` family, unrelated to dylan_family
    other_api_key = ApiKey.create!(
      user: other_user,
      name: "Other Family Loan API Test Key",
      scopes: [ "read" ],
      source: "web",
      key: ApiKey.generate_secure_key
    )

    loan = @loan_account.accountable
    get api_v1_loan_amortization_schedule_path(loan),
        headers: api_headers(other_api_key)
    # A distinct status here (e.g. 403) would let a caller enumerate loan ids
    # that exist but aren't theirs, so this must be indistinguishable from a
    # nonexistent loan.
    assert_response :not_found
    assert_equal "not_found", JSON.parse(response.body)["error"]
  end

  test "returns 404 for non-existent loan" do
    get api_v1_loan_amortization_schedule_path("00000000-0000-0000-0000-000000000000"),
        headers: api_headers
    assert_response :not_found
  end
end
