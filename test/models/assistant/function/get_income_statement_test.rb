require "test_helper"

class Assistant::Function::GetIncomeStatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetIncomeStatement.new(@user)
    @params = {
      "start_date" => 1.year.ago.to_date.to_s,
      "end_date" => Date.current.to_s
    }
  end

  test "has correct name" do
    assert_equal "get_income_statement", @fn.name
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "happy path shape is unchanged" do
    result = @fn.call(@params)

    assert result[:income][:total].present?
    assert result[:expense][:total].present?
    assert result[:income].key?(:by_category)
    assert result[:insights][:net_income].present?
    assert_not result.key?(:monthly_series)
    assert_not result.key?(:previous_period)
  end

  test "group_by month returns one bucket per calendar month" do
    result = @fn.call(@params.merge(
      "start_date" => "2025-01-15",
      "end_date" => "2025-03-10",
      "group_by" => "month"
    ))

    series = result[:monthly_series]

    assert_equal 3, series.size
    assert_equal Date.parse("2025-01-15"), series.first[:start_date]
    assert_equal Date.parse("2025-01-31"), series.first[:end_date]
    assert_equal Date.parse("2025-03-10"), series.last[:end_date]
    series.each do |bucket|
      assert bucket[:income].present?
      assert bucket[:expenses].present?
      assert bucket[:net].present?
    end
  end

  test "group_by month caps the bucket count" do
    result = @fn.call(
      "start_date" => "2020-01-01",
      "end_date" => "2025-12-31",
      "group_by" => "month"
    )

    assert_equal "too_many_periods", result[:error]
  end

  test "compare_previous_period returns an equal-length prior window with deltas" do
    result = @fn.call(@params.merge(
      "start_date" => "2025-06-01",
      "end_date" => "2025-06-30",
      "compare_previous_period" => true
    ))

    previous = result[:previous_period]

    assert_equal Date.parse("2025-05-02"), previous[:start_date]
    assert_equal Date.parse("2025-05-31"), previous[:end_date]
    assert previous[:income_change].key?(:amount)
    assert previous[:expenses_change].key?(:percent)
  end

  test "account_ids scopes totals and omits the category breakdown" do
    account = @family.accounts.visible.first

    result = @fn.call(@params.merge("account_ids" => [ account.id ]))

    assert_nil result[:income][:by_category]
    assert result[:breakdown_omitted_reason].present?
    assert result[:net].present?
  end

  test "unknown account ids return a soft failure naming them" do
    bogus = SecureRandom.uuid

    result = @fn.call(@params.merge("account_ids" => [ bogus ]))

    assert_equal "unknown_account_ids", result[:error]
    assert_equal [ bogus ], result[:unknown_ids]
  end

  test "inaccessible account ids are treated as unknown" do
    result = Assistant::Function::GetIncomeStatement.new(users(:family_member)).call(
      @params.merge("account_ids" => [ accounts(:investment).id ])
    )

    assert_equal "unknown_account_ids", result[:error]
  end

  test "accounts excluded from reports are rejected instead of returning silent zeros" do
    excluded = @family.accounts.visible.first
    excluded.update!(exclude_from_reports: true)

    result = @fn.call(@params.merge("account_ids" => [ excluded.id ]))

    assert_equal "unknown_account_ids", result[:error]
    assert_includes result[:unknown_ids], excluded.id
  end

  test "invalid dates return an invalid_date error" do
    result = @fn.call("start_date" => "bogus", "end_date" => "2024-01-01")

    assert_equal "invalid_date", result[:error]
  end

  # The assistant and MCP paths run without a session, so Current.user is nil
  # and an unscoped IncomeStatement reports family-wide totals. Every read in
  # this tool must resolve through the user-scoped statement, or the numbers it
  # reports disagree with the account ids it validates against.
  test "totals stay scoped to the requesting user when there is no session" do
    Current.session = nil
    other = users(:family_member)

    foreign = Account.create!(
      family: @family,
      name: "Another members checking",
      currency: "USD",
      balance: 0,
      owner: other,
      accountable: Depository.new
    )
    foreign.entries.create!(
      name: "Spend outside this users finances",
      date: Date.current,
      amount: 1234.56,
      currency: "USD",
      entryable: Transaction.new(category: categories(:food_and_drink))
    )
    @family.reload

    assert_not_includes @user.finance_accounts.pluck(:id), foreign.id,
      "precondition: the foreign account must sit outside the requesting users finances"

    period = Period.custom(
      start_date: Date.parse(@params["start_date"]),
      end_date: Date.parse(@params["end_date"])
    )
    scoped = @family.income_statement(user: @user).expense_totals(period: period).total
    unscoped = @family.income_statement(user: nil).expense_totals(period: period).total

    assert_operator unscoped, :>, scoped,
      "precondition: the unscoped statement must actually differ, or this test proves nothing"

    result = @fn.call(@params)

    assert_equal scoped.to_f.round(2),
      result[:expense][:total].gsub(/[^\d.-]/, "").to_f.round(2)
  end

  test "eligible account validation and reported totals agree on scope" do
    Current.session = nil
    other = users(:family_member)

    foreign = Account.create!(
      family: @family,
      name: "Another members savings",
      currency: "USD",
      balance: 0,
      owner: other,
      accountable: Depository.new
    )

    # Rejected as ineligible, so its money must not reach the totals either.
    result = @fn.call(@params.merge("account_ids" => [ foreign.id ]))

    assert_equal "unknown_account_ids", result[:error]
    assert_includes result[:unknown_ids], foreign.id
  end
end
