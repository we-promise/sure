require "test_helper"

class BalanceSheet::AccountBalancesChartTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @checking = accounts(:depository)
    @card = accounts(:credit_card)
    @investment = accounts(:investment)
    @period = Period.last_30_days
  end

  test "charts every account with today's recorded balance, liabilities negative" do
    data = chart_for(@admin, [ @checking, @card ]).to_h

    checking = series(data, @checking)
    card = series(data, @card)
    assert_equal balances(:two).end_balance.to_f, checking[:start], "starts from the latest recorded balance on or before today"
    assert_equal(-@card.balance.to_f, card[:start])
    assert card[:liability]
    assert_equal data[:dates].size, checking[:history].size
  end

  test "a future-dated transaction moves its account on its date, not before" do
    create_transaction(account: @checking, date: 10.days.from_now.to_date, amount: 250, name: "Deposit for the plot")

    event = series(chart_for(@admin, [ @checking ]).to_h, @checking)[:events].find { |e| e[:source] == "transaction" }

    assert_equal 10.days.from_now.to_date.iso8601, event[:date]
    assert_equal(-250.0, event[:amount], "an outflow lowers the balance")
    assert_equal balances(:two).end_balance.to_f, series(chart_for(@admin, [ @checking ]).to_h, @checking)[:start],
      "the start does not already include the future transaction"
  end

  test "bills become forecast events with the sign of their direction" do
    rent = bill(name: "Rent", account: @checking, amount: 1200)
    salary = bill(name: "Salary", account: @checking, amount: -3000, bill_type: "income")

    events = series(chart_for(@admin, [ @checking ]).to_h, @checking)[:events]

    assert events.select { |e| e[:name] == rent.name }.all? { |e| e[:amount] == -1200.0 }
    assert events.select { |e| e[:name] == salary.name }.all? { |e| e[:amount] == 3000.0 }
    assert events.count { |e| e[:name] == rent.name } >= 12, "the schedule continues past the materialized occurrences"
  end

  test "a transfer bill moves money from its account to its destination" do
    bill(name: "Card payment", account: @checking, destination_account: @card, amount: 300)

    data = chart_for(@admin, [ @checking, @card ]).to_h

    assert series(data, @checking)[:events].any? { |e| e[:name] == "Card payment" && e[:amount] == -300.0 }
    assert series(data, @card)[:events].any? { |e| e[:name] == "Card payment" && e[:amount] == 300.0 }
  end

  test "bills without an account get their own layer" do
    bill(name: "Land payment", account: nil, amount: 500)

    data = chart_for(@admin, [ @checking ]).to_h
    unassigned = data[:accounts].find { |a| a[:id] == BalanceSheet::AccountBalancesChart::UNASSIGNED_ID }

    assert unassigned
    assert_equal 0, unassigned[:start]
    assert unassigned[:events].all? { |e| e[:name] == "Land payment" && e[:amount] == -500.0 }
  end

  test "bills on accounts the viewer cannot access are left out entirely" do
    bill(name: "Private brokerage fee", account: @investment, amount: 40)
    shared = bill(name: "Shared checking fee", account: @checking, amount: 10)

    chart = chart_for(@member, @member.accessible_accounts.visible)
    names = chart.to_h[:accounts].flat_map { |a| a[:events].map { |e| e[:name] } }

    assert_not_includes @member.accessible_accounts, @investment
    assert_includes names, shared.name
    assert_not_includes names, "Private brokerage fee"
    assert_nil chart.to_h[:accounts].find { |a| a[:id] == BalanceSheet::AccountBalancesChart::UNASSIGNED_ID },
      "an inaccessible account's bill does not resurface as a bill without an account"
    assert_equal chart_for(@member, @member.accessible_accounts.visible).bill_count,
      @family.recurring_transactions.active.count - 1
  end

  test "builds the forecast without a query per bill occurrence" do
    3.times { |i| bill(name: "Bill #{i}", account: @checking, amount: 10 + i) }
    chart_for(@admin, [ @checking ]).to_h # warm-up: first-use lookups are not per bill
    queries = count_queries { chart_for(@admin, [ @checking ]).to_h }

    6.times { |i| bill(name: "More #{i}", account: @checking, amount: 20 + i) }
    assert_equal queries, count_queries { chart_for(@admin, [ @checking ]).to_h },
      "more bills and occurrences do not add queries"
  end

  test "builds the history without a query per account" do
    two = [ @checking, @card ]
    chart_for(@admin, two).to_h # warm-up: first-use lookups are not per account
    queries = count_queries { chart_for(@admin, two).to_h }

    all = @family.accounts.visible.to_a
    assert all.size > two.size + 2
    assert_equal queries, count_queries { chart_for(@admin, all).to_h }, "more accounts do not add queries"
  end

  test "the history is per account and matches the account's own balance series" do
    data = chart_for(@admin, [ @checking, @card ]).to_h
    expected = Balance::ChartSeriesBuilder.new(account_ids: [ @checking.id ], currency: @family.currency, period: @period, favorable_direction: "up")
                                          .balance_series.values.map { |v| v.value.amount.to_f.round(2) }

    assert_equal expected, series(data, @checking)[:history]
  end

  private
    def chart_for(user, accounts)
      BalanceSheet::AccountBalancesChart.new(@family, user: user, accounts: accounts, period: @period)
    end

    def series(data, account)
      data[:accounts].find { |a| a[:id] == account.id }
    end

    def bill(name:, account:, amount:, **attributes)
      @family.recurring_transactions.create!(
        name: name, account: account, amount: amount, currency: "USD",
        expected_day_of_month: 5, last_occurrence_date: Date.current, next_expected_date: 1.month.from_now.to_date,
        status: "active", manual: true, **attributes
      )
    end

    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveRecord::Base.uncached { ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block) }
      count
    end
end
