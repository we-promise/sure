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

  private
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
