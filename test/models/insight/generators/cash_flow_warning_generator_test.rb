require "test_helper"

class Insight::Generators::CashFlowWarningGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @series = @family.recurring_transactions.create!(
      name: "Horizon Power", account: accounts(:depository), amount: 100, currency: "USD",
      expected_day_of_month: 15, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true
    )
    # The series generates its own horizon on create; clear it so the test
    # owns exactly three known occurrences.
    @series.recurring_occurrences.delete_all
    @occurrences = 3.times.map do |i|
      @series.recurring_occurrences.create!(
        family: @family,
        original_due_on: Date.current + i + 1,
        due_on: Date.current + i + 1,
        currency: "USD"
      )
    end
    RecurringAllocation.create!(
      recurring_occurrence: @occurrences.first, state: :confirmed, source: :user_confirmed,
      allocated_amount: 40, currency: "USD", paid_on: Date.current
    )
  end

  test "remaining amounts come from one grouped sum, not one query per occurrence" do
    generator = Insight::Generators::CashFlowWarningGenerator.new(@family)

    sum_queries = 0
    counter = ->(*, payload) do
      sum_queries += 1 if payload[:sql].to_s.match?(/SUM.*recurring_allocations/i)
    end

    entries = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      generator.send(:upcoming_recurring_entries)
    end

    assert_equal 1, sum_queries, "the confirmed-allocation sums must batch into one grouped query"
    assert_equal [ 60, 100, 100 ], entries.sort_by(&:date).map(&:amount).map(&:to_i),
      "the partially paid occurrence contributes only its remainder"
  end

  test "the projection starts from money reachable today, not from every deposit account" do
    cd = @family.accounts.create!(
      name: "Term deposit", balance: 10_000, currency: "USD", accountable: Depository.new(subtype: "cd"),
      available_on: Date.current + 90
    )
    brokerage = @family.accounts.create!(
      name: "Brokerage", balance: 10_000, currency: "USD", accountable: Investment.new(subtype: "brokerage")
    )

    cash_accounts = Insight::Generators::CashFlowWarningGenerator.new(@family).send(:cash_accounts)

    assert_includes cash_accounts, accounts(:depository)
    assert_not_includes cash_accounts, cd
    assert_not_includes cash_accounts, brokerage

    cd.update!(available_on: Date.current)

    assert_includes Insight::Generators::CashFlowWarningGenerator.new(@family).send(:cash_accounts), cd
  end
end
