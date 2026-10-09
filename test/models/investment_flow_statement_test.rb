require "test_helper"

class InvestmentFlowStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = users(:empty)
    @account = @family.accounts.create!(
      owner: @user,
      name: "Investment Cash",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
  end

  test "period totals aggregate contributions and withdrawals in one query" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)

    @account.share_with!(users(:new_email), permission: "read_only", include_in_finances: true)
    @account.share_with!(users(:intro_user), permission: "read_only", include_in_finances: true)

    create_flow(label: "Contribution", amount: -125, date: period.start_date)
    create_flow(label: "Contribution", amount: 25, date: period.start_date + 1.day)
    create_flow(label: "Withdrawal", amount: 45, date: period.start_date + 1.day)
    create_flow(label: "Withdrawal", amount: -5, date: period.start_date + 2.days)
    create_flow(label: "Transfer", amount: 70, date: period.start_date + 2.days)
    create_flow(label: "Contribution", amount: -999, date: period.start_date - 1.day)

    statement = InvestmentFlowStatement.new(@family, user: @user)
    totals = nil
    queries = capture_sql_queries { totals = statement.period_totals(period: period) }

    assert_equal Money.new(100, "USD"), totals.contributions
    assert_equal Money.new(40, "USD"), totals.withdrawals
    assert_equal Money.new(60, "USD"), totals.net_flow

    aggregate_queries = queries.grep(/SUM\(CASE WHEN transactions\.investment_activity_label = 'Contribution'/)
    assert_equal 1, aggregate_queries.size
    assert_includes aggregate_queries.first, "transactions.investment_activity_label = 'Withdrawal'"
    assert_empty queries.grep(/"transactions"\."investment_activity_label" = \$\d/)
    assert_includes aggregate_queries.first, '"entries"."account_id" IN (SELECT DISTINCT "accounts"."id"'
  end

  test "a matched provider contribution still counts once after resync" do
    family = families(:dylan_family)
    brokerage = Account::ProviderImportAdapter.new(accounts(:investment))
    checking = Account::ProviderImportAdapter.new(accounts(:depository))
    period = Period.custom(start_date: Date.current, end_date: Date.current)
    expenses_before = IncomeStatement.new(family).expense_totals(period: period).total

    inflow = brokerage.import_transaction(
      external_id: "plaid_brokerage_contribution", amount: -500, currency: "USD",
      date: Date.current, name: "Contribution", source: "plaid",
      investment_activity_label: "Contribution"
    )
    outflow = checking.import_transaction(
      external_id: "plaid_checking_to_brokerage", amount: 500, currency: "USD",
      date: Date.current, name: "Transfer to brokerage", source: "plaid"
    )
    family.auto_match_transfers!
    assert inflow.transaction.reload.transfer.present?, "expected the two legs to be auto-matched"

    # The next sync replays the brokerage row; the matched inflow keeps funds_movement.
    brokerage.import_transaction(
      external_id: "plaid_brokerage_contribution", amount: -500, currency: "USD",
      date: Date.current, name: "Contribution", source: "plaid",
      investment_activity_label: "Contribution"
    )
    assert_equal "funds_movement", inflow.transaction.reload.kind
    assert_equal "investment_contribution", outflow.transaction.reload.kind

    totals = InvestmentFlowStatement.new(family).period_totals(period: period)
    assert_equal Money.new(500, "USD"), totals.contributions

    expenses_after = IncomeStatement.new(family).expense_totals(period: period).total
    assert_equal 500, expenses_after - expenses_before, "the contribution is budgeted once, on the cash leg"
  end

  test "a matched provider withdrawal still counts once" do
    family = families(:dylan_family)
    period = Period.custom(start_date: Date.current, end_date: Date.current)

    outflow = accounts(:investment).entries.create!(
      name: "Withdrawal", amount: 300, date: Date.current, currency: "USD",
      entryable: Transaction.new(kind: "standard", investment_activity_label: "Withdrawal")
    )
    accounts(:depository).entries.create!(
      name: "From brokerage", amount: -300, date: Date.current, currency: "USD",
      entryable: Transaction.new(kind: "standard")
    )
    family.auto_match_transfers!
    assert outflow.transaction.reload.transfer.present?, "expected the two legs to be auto-matched"
    assert_equal "funds_movement", outflow.transaction.kind

    totals = InvestmentFlowStatement.new(family).period_totals(period: period)
    assert_equal Money.new(300, "USD"), totals.withdrawals
    assert_equal Money.new(0, "USD"), totals.contributions
  end

  test "movements between investment and crypto accounts are not contributions" do
    family = families(:dylan_family)
    period = Period.custom(start_date: Date.current, end_date: Date.current)

    inflow = create_matched_contribution(family, from: accounts(:crypto), to: accounts(:investment))
    assert_equal "funds_movement", inflow.transaction.kind

    totals = InvestmentFlowStatement.new(family).period_totals(period: period)
    assert_equal Money.new(0, "USD"), totals.contributions
  end

  test "a matched contribution respects the viewer's account visibility" do
    family = families(:dylan_family)
    period = Period.custom(start_date: Date.current, end_date: Date.current)
    create_matched_contribution(family, from: accounts(:depository), to: accounts(:investment))

    member = users(:family_member)
    assert_not family.accounts.included_in_finances_for(member).include?(accounts(:investment))

    assert_equal Money.new(250, "USD"), InvestmentFlowStatement.new(family).period_totals(period: period).contributions
    assert_equal Money.new(0, "USD"), InvestmentFlowStatement.new(family, user: member).period_totals(period: period).contributions
  end

  private
    def create_matched_contribution(family, from:, to:)
      inflow = to.entries.create!(
        name: "Contribution", amount: -250, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: "investment_contribution", investment_activity_label: "Contribution")
      )
      outflow = from.entries.create!(
        name: "Transfer out", amount: 250, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: "standard")
      )
      family.auto_match_transfers!
      assert inflow.transaction.reload.transfer.present?, "expected the two legs to be auto-matched"
      assert_equal outflow.transaction.id, inflow.transaction.transfer.outflow_transaction_id
      inflow
    end

    def create_flow(label:, amount:, date:)
      @account.entries.create!(
        name: label,
        amount: amount,
        date: date,
        currency: "USD",
        entryable: Transaction.new(
          kind: "standard",
          investment_activity_label: label
        )
      )
    end

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
end
