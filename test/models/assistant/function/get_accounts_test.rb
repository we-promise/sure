require "test_helper"

class Assistant::Function::GetAccountsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetAccounts.new(@user)
  end

  test "has correct name" do
    assert_equal "get_accounts", @fn.name
  end

  test "has a description" do
    assert_not_empty @fn.description
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "returns account ids and omits the balance series by default" do
    result = @fn.call

    assert result[:accounts].any?

    result[:accounts].each do |account|
      assert account[:id].present?
      assert_not account.key?(:historical_balances)
    end
  end

  test "excludes hidden accounts" do
    hidden = @family.accounts.visible.first
    hidden.update!(status: "disabled")

    result = @fn.call

    assert_not_includes result[:accounts].map { |a| a[:id] }, hidden.id
  end

  test "includes a balance series bounded by the requested period when asked" do
    result = @fn.call({ "include_balance_series" => true, "series_period" => "last_30_days" })

    account = result[:accounts].first
    series = account[:historical_balances]

    assert series.present?
    assert series[:start_date] >= 30.days.ago.to_date
    assert_equal Date.current, series[:end_date]
    assert(series[:values].all? { |v| v.is_a?(Numeric) })
  end

  test "falls back to last_365_days for an unknown series period" do
    result = @fn.call({ "include_balance_series" => true, "series_period" => "bogus" })

    series = result[:accounts].first[:historical_balances]

    assert series[:start_date] >= 366.days.ago.to_date
  end

  test "an account starting beyond the period skips its series without failing the call" do
    future_account = @family.accounts.create!(
      name: "Future Start Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    future_account.entries.create!(
      name: "Scheduled opening deposit",
      date: 30.days.from_now.to_date,
      amount: -100,
      currency: "USD",
      entryable: Transaction.new
    )

    result = @fn.call({ "include_balance_series" => true, "series_period" => "last_7_days" })

    assert_not result.key?(:error)

    future_payload = result[:accounts].find { |a| a[:id] == future_account.id }

    assert_not_nil future_payload
    assert_not future_payload.key?(:historical_balances)
    assert(result[:accounts].any? { |a| a.key?(:historical_balances) })
  end

  test "returns the current account subtype" do
    result = @fn.call

    account = result[:accounts].find { |item| item[:id] == accounts(:depository).id }
    assert_nil account[:subtype]
  end

  test "returns goal funding status and available allocation for fundable accounts" do
    account = @family.accounts.create!(owner: @user, name: "Goal funding account", accountable: Depository.new, balance: 5_000, currency: "USD")
    @family.goals.create!(name: "Whole claim", target_amount: 5_000, currency: "USD") do |goal|
      goal.goal_accounts.build(account: account)
    end

    payload = @fn.call[:accounts].find { |item| item[:id] == account.id }

    assert_equal "whole_account_claimed", payload.dig(:goal_funding, :status)
    assert_equal 5_000, payload.dig(:goal_funding, :free_to_earmark)
  end

  test "marks non-fundable account types explicitly" do
    account = @family.accounts.create!(owner: @user, name: "Not goal fundable", accountable: OtherAsset.new, balance: 100, currency: "USD")

    payload = @fn.call[:accounts].find { |item| item[:id] == account.id }

    assert_equal "unsupported_account_type", payload.dig(:goal_funding, :status)
    assert_nil payload.dig(:goal_funding, :free_to_earmark)
  end

  test "returns stable ids and write capability for transaction actions" do
    user = users(:family_member)
    result = Assistant::Function::GetAccounts.new(user).call

    checking = result[:accounts].find { |account| account[:name] == accounts(:depository).name }
    credit_card = result[:accounts].find { |account| account[:name] == accounts(:credit_card).name }

    assert_equal accounts(:depository).id, checking[:id]
    assert_equal true, checking[:writable]
    assert_equal "full_control", checking[:permission]
    assert_equal({ financial: true, annotations: true }, checking[:transaction_editing])

    assert_equal accounts(:credit_card).id, credit_card[:id]
    assert_equal false, credit_card[:writable]
    assert_equal "read_only", credit_card[:permission]
    assert_equal({ financial: false, annotations: false }, credit_card[:transaction_editing])
  end

  test "reports annotation-only transaction editing for read-write shared accounts" do
    user = users(:family_member)
    account = accounts(:depository)
    account.account_shares.find_by!(user: user).update!(permission: "read_write")

    result = Assistant::Function::GetAccounts.new(user).call

    checking = result[:accounts].find { |item| item[:id] == account.id }
    assert_equal false, checking[:writable]
    assert_equal "read_write", checking[:permission]
    assert_equal({ financial: false, annotations: true }, checking[:transaction_editing])
  end

  test "exposes a loan's borrowing terms" do
    result = @fn.call

    loan = result[:accounts].find { |a| a[:id] == accounts(:loan).id }
    terms = loan[:terms]

    assert_equal "Loan", loan[:type]
    assert_equal 3.5, terms[:interest_rate].to_f
    assert_equal 360, terms[:term_months]
    assert_equal "fixed", terms[:rate_type]
    assert terms[:monthly_payment].present?, "a fixed-rate loan has a computable payment"
    assert terms[:monthly_payment_formatted].present?
    assert_not terms.key?(:base_interest_rate)
  end

  # The loan's Overview tab quotes the rate and repayment in force today. Reading
  # the interest_rate column instead told the assistant the loan still charged
  # the rate it opened at, next to a schedule that no longer used it.
  test "reports the rate and repayment in force for a variable-rate loan with a recorded change" do
    loan = accounts(:loan).loan
    base_payment = loan.monthly_payment.amount
    loan.update!(
      rate_type: "variable",
      start_date: Date.current - 2.years,
      rate_changes: [ { effective_date: (Date.current - 1.year).iso8601, rate: "5.0" } ]
    )

    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }[:terms]

    assert_equal "variable", terms[:rate_type]
    assert_equal 5.0, terms[:interest_rate].to_f
    assert_equal 3.5, terms[:base_interest_rate].to_f
    assert_equal loan.reload.amortization_schedule.payment_in_force(Date.current).amount, terms[:monthly_payment]
    assert_operator terms[:monthly_payment], :>, base_payment, "the repayment is resized at the higher rate"
    assert terms[:monthly_payment_formatted].present?
  end

  test "a variable-rate loan with no recorded change reports its base rate and repayment" do
    loan = accounts(:loan).loan
    base_payment = loan.monthly_payment.amount
    loan.update!(rate_type: "variable")

    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }[:terms]

    assert_equal 3.5, terms[:interest_rate].to_f
    assert_not terms.key?(:base_interest_rate)
    assert_equal base_payment, terms[:monthly_payment]
  end

  test "omits monthly_payment for a variable-rate loan whose schedule has run out rather than reporting zero" do
    accounts(:loan).loan.update!(rate_type: "variable", term_months: 12, start_date: Date.current - 3.years)

    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }[:terms]

    assert_equal "variable", terms[:rate_type]
    assert_equal 12, terms[:term_months]
    assert_not terms.key?(:monthly_payment)
    assert_not terms.key?(:monthly_payment_formatted)
  end

  # Switching a loan back to fixed keeps its recorded changes in the column so a
  # later switch can reveal them. They must not leak into a fixed loan's terms.
  test "a fixed-rate loan ignores rate changes left over from a variable period" do
    accounts(:loan).loan.update!(rate_changes: [ { effective_date: (Date.current - 1.year).iso8601, rate: "5.0" } ])

    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }[:terms]

    assert_equal "fixed", terms[:rate_type]
    assert_equal 3.5, terms[:interest_rate].to_f
    assert_not terms.key?(:base_interest_rate)
  end

  test "exposes a credit card's terms" do
    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:credit_card).id }[:terms]

    assert_equal 18.99, terms[:apr].to_f
    assert_equal 100.0, terms[:minimum_payment].to_f
    assert_equal 95.0, terms[:annual_fee].to_f
    assert_equal 5000.0, terms[:available_credit].to_f
  end

  test "omits terms entirely for an account type that carries none" do
    depository = @family.accounts.visible.find_by(accountable_type: "Depository")

    payload = @fn.call[:accounts].find { |a| a[:id] == depository.id }

    assert_not payload.key?(:terms)
  end

  test "omits a term the user never entered" do
    accounts(:loan).loan.update!(interest_rate: nil, rate_type: nil, term_months: nil)

    terms = @fn.call[:accounts].find { |a| a[:id] == accounts(:loan).id }[:terms]

    assert_not terms.key?(:interest_rate)
    assert_not terms.key?(:term_months)
    assert_not terms.key?(:monthly_payment)
  end
end
