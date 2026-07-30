require "test_helper"

class Loan::InterestAccrualTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  # Opened 2026-01-01 at $200,000, 6% annual (0.5%/month), so accruals land on
  # the 1st of each month and the arithmetic stays exact:
  #
  #   2026-02-01  interest 200,000.00 * 0.005 = 1,000.00 -> 201,000.00
  #               payment                      -1,200.00 -> 199,800.00
  #   2026-03-01  interest 199,800.00 * 0.005 =   999.00 -> 200,799.00
  #               payment                      -1,200.00 -> 199,599.00
  #
  # Two $1,200 payments therefore reduce the principal by $401, not $2,400.
  OPENING_DATE = Date.new(2026, 1, 1)
  OPENING_BALANCE = 200_000
  TODAY = Date.new(2026, 3, 15)

  test "charges interest on the outstanding balance so payments pay down principal only" do
    travel_to TODAY do
      account = mortgage_with_payments

      assert Loan::InterestAccrual.new(account.loan).sync!

      assert_equal [
        [ Date.new(2026, 2, 1), 1_000.00 ],
        [ Date.new(2026, 3, 1), 999.00 ]
      ], accruals_for(account)
    end
  end

  # The behavior, not the flag: the payment is already booked as a loan_payment
  # expense on the funding account, so the interest charge must not add to it.
  test "accrued interest does not register as an expense" do
    travel_to TODAY do
      account = mortgage_with_payments
      family = account.family
      period = Period.custom(start_date: OPENING_DATE, end_date: TODAY)

      before = IncomeStatement.new(family).expense_totals(period: period).total

      assert Loan::InterestAccrual.new(account.loan).sync!
      assert account.entries.where(source: Loan::InterestAccrual::SOURCE).any?

      after = IncomeStatement.new(family).expense_totals(period: period).total

      assert_equal before, after, "accrued interest leaked into the expense total"
    end
  end

  test "generated entries are kept out of the family-wide transactions page" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!

      found = Transaction::Search.new(account.family).transactions_scope
                                 .joins(:entry)
                                 .where(entries: { source: Loan::InterestAccrual::SOURCE })

      assert_empty found, "accruals appeared in the transactions list and its totals"
    end
  end

  test "balance calculator applies accruals so the loan is reduced by principal only" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!

      calculated = Balance::ForwardCalculator.new(account).calculate

      # Without accrual the two $1,200 payments would leave $197,600.
      assert_equal 199_599, calculated.last.balance
    end
  end

  # Identity is the accrual period, so this must hold — two charges in one month
  # would collide on external_id and one would silently overwrite the other.
  test "posts at most one accrual per calendar month" do
    travel_to Date.new(2027, 6, 15) do
      account = mortgage_with_payments(
        interest_accrual_day: 31,
        entries: [ { type: "opening_anchor", date: OPENING_DATE, balance: OPENING_BALANCE } ]
      )
      Loan::InterestAccrual.new(account.loan).sync!

      periods = accruals_for(account).map { |date, _| date.strftime("%Y-%m") }

      assert_equal periods.uniq, periods
      assert_operator periods.length, :>, 12, "expected a multi-year run to exercise this"
    end
  end

  # Re-dating in place rather than purge-and-recreate is the whole point of
  # keying on the period: the destroy path cascades through Entry's
  # dependent: :destroy fan-out for every row.
  test "moving the statement day re-dates existing accruals in place" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!

      ids = account.entries.where(source: Loan::InterestAccrual::SOURCE).order(:date).pluck(:id)
      assert_equal 2, ids.length

      account.loan.update!(interest_accrual_day: 15)

      assert_no_difference "Entry.count" do
        assert Loan::InterestAccrual.new(account.loan).sync!
      end

      reused = account.entries.where(source: Loan::InterestAccrual::SOURCE).order(:date)
      assert_equal ids, reused.pluck(:id), "accruals were recreated instead of re-dated"
      assert_equal [ Date.new(2026, 2, 15), Date.new(2026, 3, 15) ], reused.pluck(:date)
    end
  end

  test "is idempotent" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!

      assert_no_difference "Entry.count" do
        assert_not Loan::InterestAccrual.new(account.loan).sync!
      end
    end
  end

  # Documented limitation: the rate is not effective-dated, so a change reprices
  # the whole history rather than taking effect only from the change date forward
  # (see Loan#accrues_interest?). This pins that whole-history-correction contract.
  test "re-prices existing accruals when the interest rate changes" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!

      account.loan.update!(interest_rate: 12) # 1%/month

      assert_no_difference "Entry.count" do
        assert Loan::InterestAccrual.new(account.loan).sync!
      end

      # 200,000 * 0.01 = 2,000 -> 202,000 -> 200,800 after the payment
      # 200,800 * 0.01 = 2,008
      assert_equal [
        [ Date.new(2026, 2, 1), 2_000.00 ],
        [ Date.new(2026, 3, 1), 2_008.00 ]
      ], accruals_for(account)
    end
  end

  test "removes every accrual when the loan is opted back out" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!
      assert account.entries.where(source: Loan::InterestAccrual::SOURCE).any?

      account.loan.update!(accrue_interest: false)

      assert Loan::InterestAccrual.new(account.loan).sync!
      assert_empty account.entries.where(source: Loan::InterestAccrual::SOURCE)
    end
  end

  test "does nothing when the loan has not opted in" do
    travel_to TODAY do
      opted_out = mortgage_with_payments(accrue_interest: false)
      assert_not Loan::InterestAccrual.new(opted_out.loan).sync!
      assert_empty opted_out.entries.where(source: Loan::InterestAccrual::SOURCE)
    end
  end

  # Regression: the opening anchor is where a balance is first *recorded*, not
  # where the loan started — AccountableResource#create backdates it two years
  # when the user gives no date. Charging from the anchor invented ~$25k of debt
  # on a brand new mortgage.
  test "charges only from the configured start date, not the opening anchor" do
    travel_to TODAY do
      account = mortgage_with_payments(
        interest_accrual_start_date: Date.new(2026, 2, 1),
        entries: [ { type: "opening_anchor", date: OPENING_DATE, balance: OPENING_BALANCE } ]
      )

      Loan::InterestAccrual.new(account.loan).sync!

      # Anchor is 1 Jan but accrual starts 1 Feb, so the first charge is 1 Mar
      # (one whole month later), not 1 Feb and certainly not 1 Jan.
      assert_equal [ Date.new(2026, 3, 1) ], accruals_for(account).map(&:first)
    end
  end

  # The reported defect, numerically: a mortgage created today with the toggle on
  # got its opening anchor backdated two years by AccountableResource#create,
  # and the replay charged from there — inventing ~$25k of debt and a matching
  # net-worth drop before the borrower had made a single payment.
  test "a loan opened today accrues nothing against a backdated opening anchor" do
    travel_to TODAY do
      account = mortgage_with_payments(
        interest_accrual_start_date: TODAY,
        entries: [ { type: "opening_anchor", date: TODAY - 2.years, balance: OPENING_BALANCE } ]
      )

      assert_not Loan::InterestAccrual.new(account.loan).sync!

      assert_empty accruals_for(account)
      assert_equal 0, account.loan.accrued_interest_total.amount
    end
  end

  test "does not charge a full month for a partial first period" do
    travel_to TODAY do
      account = mortgage_with_payments(
        interest_accrual_start_date: Date.new(2026, 1, 1),
        interest_accrual_day: 10,
        entries: [ { type: "opening_anchor", date: OPENING_DATE, balance: OPENING_BALANCE } ]
      )

      Loan::InterestAccrual.new(account.loan).sync!

      # 10 Jan is only 9 days in — the first charge belongs on 10 Feb.
      assert_equal [ Date.new(2026, 2, 10), Date.new(2026, 3, 10) ],
                   accruals_for(account).map(&:first)
    end
  end

  # Regression: the balance calculators discard same-day transactions on a
  # valuation date, so an accrual there moved nothing but still inflated the
  # reported interest total. Manual balance edits create a reconciliation dated
  # today, so this fired every month for anyone who reconciles.
  test "skips accrual dates that carry a valuation" do
    travel_to TODAY do
      account = mortgage_with_payments(
        entries: [
          { type: "opening_anchor", date: OPENING_DATE, balance: OPENING_BALANCE },
          { type: "reconciliation", date: Date.new(2026, 3, 1), balance: 150_000 }
        ]
      )

      Loan::InterestAccrual.new(account.loan).sync!

      assert_equal [ Date.new(2026, 2, 1) ], accruals_for(account).map(&:first)
      assert_equal 1_000.00, account.loan.accrued_interest_total.amount.to_f
    end
  end

  # Regression: every generated attribute must be re-asserted. `excluded` is
  # load-bearing — the transaction detail page offers users a toggle for it, and
  # un-excluding one permanently double-counted the interest.
  test "repairs a user-edited accrual on the next sync" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!

      entry = account.entries.where(source: Loan::InterestAccrual::SOURCE).order(:date).first
      entry.update!(date: Date.new(2026, 2, 20), amount: 5_000, excluded: false, name: "Renamed by a rule")

      assert Loan::InterestAccrual.new(account.loan).sync!

      entry.reload
      assert_equal Date.new(2026, 2, 1), entry.date
      assert_equal 1_000.00, entry.amount.to_f
      assert entry.excluded?
      assert_equal "Interest charged", entry.name
    end
  end

  test "honours a payment's custom exchange rate when replaying the balance" do
    travel_to TODAY do
      account = mortgage_with_payments(
        entries: [ { type: "opening_anchor", date: OPENING_DATE, balance: OPENING_BALANCE } ]
      )

      ExchangeRate.create!(date: Date.new(2026, 2, 1), from_currency: "EUR", to_currency: "USD", rate: 1.1)
      account.entries.create!(
        name: "Payment", date: Date.new(2026, 2, 1), amount: -1_000, currency: "EUR",
        entryable: Transaction.new(exchange_rate: 2.0)
      )

      Loan::InterestAccrual.new(account.loan).sync!

      # The user's 2.0 rate means $2,000 came off, not the market rate's $1,100.
      # 200,000 + 1,000 interest - 2,000 = 199,000 -> 1 Mar charge of $995.00
      assert_equal 995.00, accruals_for(account).last.last
    end
  end

  test "skips linked accounts, whose balance is anchored to the provider" do
    travel_to TODAY do
      account = mortgage_with_payments
      Loan::InterestAccrual.new(account.loan).sync!
      assert account.entries.where(source: Loan::InterestAccrual::SOURCE).any?

      Account.any_instance.stubs(:unlinked?).returns(false)

      # Linking purges what accrual had built up, rather than leaving entries
      # that the provider balance would double-count.
      assert Loan::InterestAccrual.new(account.loan).sync!
      assert_empty account.entries.where(source: Loan::InterestAccrual::SOURCE)
    end
  end

  test "charges on the configured statement day, clamped to the end of short months" do
    travel_to TODAY do
      account = mortgage_with_payments(interest_accrual_day: 31)
      Loan::InterestAccrual.new(account.loan).sync!

      # 31 Jan is a stub period (accrual starts 1 Jan), so the first charge is
      # 28 Feb — day 31 clamped to the end of a short month. 31 Mar is still
      # in the future as of TODAY.
      assert_equal [ Date.new(2026, 2, 28) ], accruals_for(account).map(&:first)
    end
  end

  test "stops accruing once the loan is paid off" do
    travel_to TODAY do
      account = mortgage_with_payments
      account.entries.create!(
        name: "Payoff",
        date: Date.new(2026, 2, 2),
        amount: -300_000,
        currency: "USD",
        entryable: Transaction.new
      )

      Loan::InterestAccrual.new(account.loan).sync!

      # Only the 1 Feb charge — by 1 Mar the balance is negative.
      assert_equal [ Date.new(2026, 2, 1) ], accruals_for(account).map(&:first)
    end
  end

  private
    def mortgage_with_payments(accrue_interest: true, interest_rate: 6, interest_accrual_day: nil,
                               interest_accrual_start_date: OPENING_DATE, entries: nil)
      account = create_account_with_ledger(
        account: { type: Loan, currency: "USD" },
        entries: entries || [
          { type: "opening_anchor", date: OPENING_DATE, balance: OPENING_BALANCE },
          { type: "transaction", date: Date.new(2026, 2, 1), amount: -1_200 },
          { type: "transaction", date: Date.new(2026, 3, 1), amount: -1_200 }
        ]
      )

      account.loan.update!(
        subtype: "mortgage",
        rate_type: "fixed",
        interest_rate: interest_rate,
        accrue_interest: accrue_interest,
        interest_accrual_day: interest_accrual_day,
        interest_accrual_start_date: interest_accrual_start_date
      )

      account
    end

    def accruals_for(account)
      account.entries
             .where(source: Loan::InterestAccrual::SOURCE)
             .order(:date)
             .map { |e| [ e.date, e.amount.to_f ] }
    end
end
