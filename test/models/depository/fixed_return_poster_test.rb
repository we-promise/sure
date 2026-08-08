require "test_helper"

class Depository::FixedReturnPosterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "does nothing when the account has no fixed return configured" do
    account = fixed_return_account(rate: nil, frequency: nil, start_date: nil)

    assert_no_difference -> { account.entries.count } do
      assert_empty Depository::FixedReturnPoster.new(account).post_due_interest!
    end
  end

  test "does nothing for a non-depository account" do
    account = @family.accounts.create!(
      name: "Brokerage", balance: 1000, currency: "USD", accountable: Investment.new
    )

    assert_empty Depository::FixedReturnPoster.new(account).post_due_interest!
  end

  test "credits interest on the average daily balance at actual/365" do
    period_start = Date.new(2026, 1, 31)
    posting_date = Date.new(2026, 2, 28)
    account = fixed_return_account(rate: 3.65, frequency: "monthly", start_date: period_start)
    materialize_balances(account, (period_start + 1)..posting_date, 10_000)

    entry = travel_to(posting_date) { Depository::FixedReturnPoster.new(account).post_due_interest! }.sole

    # 10,000 at 3.65% accrues exactly 1.00 a day, over 28 accrual days.
    assert_equal posting_date, entry.date
    assert_equal BigDecimal("-28"), entry.amount
    assert_equal "Interest", entry.name
    assert entry.transaction?
  end

  test "credits interest as income" do
    account, entry = post_single_period

    assert entry.amount.negative?, "interest should be an inflow"
    assert_equal account, entry.account
  end

  test "is idempotent across repeated syncs" do
    account, entry = post_single_period

    assert_no_difference -> { account.entries.count } do
      travel_to(entry.date) { Depository::FixedReturnPoster.new(account).post_due_interest! }
    end
  end

  test "does not post a period that has not fully elapsed" do
    account = fixed_return_account(rate: 5, frequency: "monthly", start_date: 10.days.ago.to_date)
    materialize_balances(account, 10.days.ago.to_date..Date.current, 10_000)

    assert_empty Depository::FixedReturnPoster.new(account).post_due_interest!
  end

  test "backfills every elapsed period at once" do
    start_date = Date.new(2026, 1, 31)
    account = fixed_return_account(rate: 6, frequency: "monthly", start_date: start_date)
    materialize_balances(account, start_date..Date.new(2026, 5, 31), 10_000)

    entries = travel_to(Date.new(2026, 5, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }

    assert_equal [ Date.new(2026, 2, 28), Date.new(2026, 3, 31), Date.new(2026, 4, 30) ], entries.map(&:date)
  end

  test "quarterly accounts post every three months" do
    start_date = Date.new(2026, 1, 1)
    account = fixed_return_account(rate: 4, frequency: "quarterly", start_date: start_date)
    materialize_balances(account, start_date..Date.new(2026, 8, 1), 10_000)

    entries = travel_to(Date.new(2026, 8, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }

    assert_equal [ Date.new(2026, 4, 1), Date.new(2026, 7, 1) ], entries.map(&:date)
  end

  test "catch-up periods compound on the interest posted for earlier ones" do
    start_date = Date.new(2026, 1, 31)
    account = fixed_return_account(rate: 12, frequency: "monthly", start_date: start_date)
    materialize_balances(account, start_date..Date.new(2026, 3, 31), 100_000)

    entries = travel_to(Date.new(2026, 3, 31)) { Depository::FixedReturnPoster.new(account).post_due_interest! }

    # March accrues on 100,000 plus the 920.55 credited for February, not on
    # the stale materialized balance alone.
    assert_equal BigDecimal("-920.55"), entries.first.amount
    assert_equal BigDecimal("-1028.56"), entries.second.amount
  end

  test "skips a period whose balance history is only partly materialized" do
    start_date = Date.new(2026, 1, 1)
    account = fixed_return_account(rate: 4, frequency: "monthly", start_date: start_date)
    materialize_balances(account, Date.new(2026, 1, 20)..Date.new(2026, 2, 1), 10_000)

    assert_empty travel_to(Date.new(2026, 2, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }
  end

  test "posts a skipped period once its balances are materialized" do
    start_date = Date.new(2026, 1, 1)
    account = fixed_return_account(rate: 4, frequency: "monthly", start_date: start_date)

    assert_empty travel_to(Date.new(2026, 2, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }

    materialize_balances(account, start_date..Date.new(2026, 2, 1), 10_000)

    assert_equal 1, travel_to(Date.new(2026, 2, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }.size
  end

  test "skips periods with no balance history" do
    start_date = Date.new(2026, 1, 1)
    account = fixed_return_account(rate: 4, frequency: "monthly", start_date: start_date)

    assert_empty travel_to(Date.new(2026, 4, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }
  end

  test "skips a period where the balance is zero or negative" do
    start_date = Date.new(2026, 1, 1)
    account = fixed_return_account(rate: 4, frequency: "monthly", start_date: start_date)
    materialize_balances(account, start_date..Date.new(2026, 3, 1), 0)

    assert_empty travel_to(Date.new(2026, 3, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }
  end

  private
    def fixed_return_account(rate:, frequency:, start_date:)
      @family.accounts.create!(
        name: "Tagesgeld",
        balance: 10_000,
        currency: "USD",
        accountable: Depository.new(
          subtype: "savings",
          fixed_return_rate: rate,
          fixed_return_frequency: frequency,
          fixed_return_start_date: start_date
        )
      )
    end

    def materialize_balances(account, dates, balance)
      dates.each do |date|
        account.balances.create!(date: date, balance: balance, currency: account.currency)
      end
    end

    def post_single_period
      start_date = Date.new(2026, 1, 1)
      account = fixed_return_account(rate: 3.65, frequency: "monthly", start_date: start_date)
      materialize_balances(account, start_date..Date.new(2026, 2, 1), 10_000)

      entry = travel_to(Date.new(2026, 2, 1)) { Depository::FixedReturnPoster.new(account).post_due_interest! }.sole

      [ account, entry ]
    end
end
