require "test_helper"

class RecurringTransaction::PaycheckPlannerTest < ActiveSupport::TestCase
  Planner = RecurringTransaction::PaycheckPlanner

  def setup
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
  end

  test "no declared income means no plan" do
    create_series(name: "Rent", amount: 2150, due: Date.current + 10)

    assert_nil Planner.new(@family, user: @user).plan
  end

  test "auto-detected inflows never define paydays" do
    penny = create_series(name: "To Car Vault", amount: -0.01, due: Date.current + 2, income: true)
    penny.update!(manual: false)
    create_series(name: "Rent", amount: 2150, due: Date.current + 10)

    assert_nil Planner.new(@family, user: @user).plan,
               "a recurring one-cent transfer is income by sign and a paycheck by nothing"
  end

  test "periods slice by paycheck and apportion bills to their due dates" do
    first_payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: first_payday, preset: "weekly", income: true)
    rent_due = Date.current + 17
    rent = create_series(name: "Rent", amount: 2150, due: rent_due)
    create_series(name: "Internet", amount: 90, due: Date.current + 5)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert_equal 4, plan.size, "today-to-first-paycheck plus three paychecks"
    assert_equal Date.current, plan.first.starts_on
    assert_equal 0, plan.first.income
    assert_equal 1840, plan[1].income

    rent_shares = plan.flat_map(&:items).select { |item| item.occurrence.recurring_transaction_id == rent.id }
    # Rent's own paycheck funds what it can; only the overflow it cannot cover
    # is reserved, out of the paycheck nearest before it.
    assert_equal 2, rent_shares.size, "one due share plus one reserve for the overflow"
    assert_equal 2150, rent_shares.sum(&:share), "shares reassemble the full obligation exactly"
    assert_equal 1, rent_shares.count(&:due_in_period)
    assert_equal 1840, rent_shares.find(&:due_in_period).share, "the due share is what its paycheck can fund"
    assert_equal 310, plan[2].reserved_total, "the paycheck just before rent holds the overflow"

    plan.each do |period|
      assert_equal period.income - period.obligation_total, period.remaining
    end
  end

  # The page states due and reserved separately and never their sum, so the
  # planner has to hand over both. Adding them back together must reproduce
  # obligation_total exactly, or the card's arithmetic stops reconciling.
  test "every period splits its obligations into due here and reserved for later" do
    first_payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: first_payday, preset: "weekly", income: true)
    create_series(name: "Internet", amount: 90, due: first_payday + 2)
    create_series(name: "Rent", amount: 2150, due: Date.current + 17)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    plan.each do |period|
      assert_equal period.items_due.sum(&:share), period.due_total
      assert_equal period.items_reserved.sum(&:share), period.reserved_total
      assert_equal period.due_total + period.reserved_total, period.obligation_total
      assert_equal period.income - period.due_total - period.reserved_total, period.remaining
    end

    internet_shares = plan.flat_map(&:items).select { |item| item.occurrence.recurring_transaction.name == "Internet" }
    assert_equal 90, internet_shares.sum(&:share), "the shares reassemble the bill"
    assert_equal 1, internet_shares.count(&:due_in_period),
      "a bill counts as due in exactly one window, and reserves earlier only what that window cannot fund"
    assert plan.any? { |period| period.due_total.positive? }
    assert plan.any? { |period| period.reserved_total.positive? }

    # Both lists render as a ledger with the date in a fixed left column, so
    # they have to descend in date order.
    plan.each do |period|
      [ period.items_due, period.items_reserved ].each do |list|
        dates = list.map { |item| item.occurrence.due_on }
        assert_equal dates.sort, dates
      end
    end
  end

  # The leading window is funded by cash already in hand, not by a paycheck,
  # and the page has to be able to say so instead of reporting "remaining".
  test "the window before the first paycheck is a bridge, not a paycheck" do
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 3, preset: "weekly", income: true)
    create_series(name: "Streaming", amount: 20, due: Date.current + 1)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert plan.first.bridge?
    assert_not plan.first.short?,
      "a $20 bill against $5,000 in the bank is not a shortfall, whatever the window earns"
    assert plan.drop(1).none?(&:bridge?), "a window that pays is never a bridge"
  end

  # A reserve has to come out of a paycheck. The leading window has no income by
  # definition, so charging it a share of a bill due after the next payday
  # reported it short by money it was never going to see, while telling the user
  # nothing was due in that window. Both figures were right; the model was not.
  test "the window before the first payday reserves nothing for later bills" do
    payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: payday, preset: "weekly", income: true)
    create_series(name: "Rent", amount: 1450, due: payday + 3)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)
    bridge = plan.first

    assert bridge.bridge?
    assert_equal 0, bridge.reserved_total,
      "nothing is reserved out of a window that receives no income"
    assert_equal 0, bridge.due_total, "and nothing falls due in it either"
    assert_not bridge.short?,
      "so it cannot be short: a window owing nothing is not a shortfall"
  end

  # The flip side: a bill that really does fall due before the first payday is
  # still the leading window's problem, because it is paid from cash in hand.
  test "the window before the first payday still carries what is due inside it" do
    payday = Date.current + 5
    create_series(name: "Paycheck", amount: -1840, due: payday, preset: "weekly", income: true)
    create_series(name: "Water", amount: 64, due: Date.current + 2)

    bridge = Planner.new(@family, user: @user).plan(periods_limit: 3).first

    assert_equal 64, bridge.due_total
    assert_equal 0, bridge.reserved_total
    assert_not bridge.short?, "the cash on hand covers it, so nothing is short"
    assert_equal 0, bridge.shortfall
  end

  # The reserve does not vanish, it moves to the paychecks that precede the bill.
  test "reserves land on the paychecks before the bill, and still reassemble it" do
    payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: payday, preset: "weekly", income: true)
    rent = create_series(name: "Rent", amount: 2150, due: payday + 10)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)
    shares = plan.flat_map(&:items).select { |item| item.occurrence.recurring_transaction_id == rent.id }

    assert_equal 2150, shares.sum(&:share), "the shares still reassemble the bill"
    assert plan.first.items.none? { |item| item.occurrence.recurring_transaction_id == rent.id },
      "and none of it is charged to the window before the first payday"
    assert_equal 310, plan[1].reserved_total, "the first paycheck holds what rent's own cannot fund"
  end

  # The user's own case: paid weekly with weekly bills, every bill inside its
  # own paycheck. The old even spread parked half of next week's bill in this
  # week's check anyway, so no week ever read as clean.
  test "bills covered by their own paycheck reserve nothing from earlier ones" do
    create_series(name: "Paycheck", amount: -1600, due: Date.current + 3, preset: "weekly", income: true)
    create_series(name: "Groceries", amount: 200, due: Date.current + 5, preset: "weekly")

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)
    paychecks = plan.reject(&:bridge?)

    assert_equal 3, paychecks.size
    paychecks.each do |period|
      assert_equal 200, period.due_total, "each week's bill lands in its own week"
      assert_equal 0, period.reserved_total,
        "a bill its own paycheck covers reserves nothing; the even spread would have parked next week's bill here"
      assert_equal 1400, period.remaining, "safe is simply income minus what is due"
    end
  end

  # A bill bigger than one paycheck is the one genuine reason to reserve, and
  # the reserve fills backward from the paycheck nearest the bill.
  test "a bill that outgrows its paycheck reserves the overflow from the nearest earlier one" do
    payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1600, due: payday, preset: "weekly", income: true)
    rent = create_series(name: "Rent", amount: 2150, due: Date.current + 17)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    rent_period = plan[3]
    assert_equal 1600, rent_period.due_total, "rent takes its whole paycheck"
    assert_equal 0, rent_period.remaining
    assert_not rent_period.short?, "the reserve upstream is what keeps it whole"

    assert_equal 550, plan[2].reserved_total, "the nearest earlier paycheck holds the overflow"
    assert_equal 0, plan[1].reserved_total, "the farther one is untouched: nearest fills first"

    shares = plan.flat_map(&:items).select { |item| item.occurrence.recurring_transaction_id == rent.id }
    assert_equal 2150, shares.sum(&:share), "the shares reassemble the bill"
    reserve = shares.find { |item| !item.due_in_period }
    assert_equal 2150, reserve.remaining_total, "the reserve names the whole bill it is a slice of"
  end

  # When even every earlier paycheck cannot absorb the overflow, the earliest
  # one takes the rest and goes short, so the plan is short today rather than
  # the week the bill arrives.
  test "overflow no paycheck can absorb lands on the earliest paycheck as its shortfall" do
    create_series(name: "Paycheck", amount: -400, due: Date.current + 3, preset: "weekly", income: true)
    create_series(name: "Rent", amount: 2150, due: Date.current + 17)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert_equal 400, plan[3].due_total, "rent's own paycheck goes in whole"
    assert_equal 0, plan[3].remaining
    assert_equal 400, plan[2].reserved_total, "the nearer paycheck fills to its income and no further"
    assert_equal 0, plan[2].remaining
    assert_equal 1350, plan[1].reserved_total, "the earliest takes everything the others could not"
    assert plan[1].short?
    assert_equal 950, plan[1].shortfall, "short by exactly what three paychecks cannot cover"
    assert_equal 0, plan.first.reserved_total, "and the bridge window still never reserves"
  end

  # A paycheck arriving today makes the leading window a real pay period, so
  # bridge? has to read income rather than position.
  test "income landing today makes the leading window a paycheck" do
    create_series(name: "Paycheck", amount: -1840, due: Date.current, preset: "weekly", income: true)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert_not plan.first.bridge?
    assert_equal 1840, plan.first.income
  end

  # "Which bill is making me short" has to answer with the obligation. The
  # slice a period carries is an artifact of how many paychecks the plan had
  # to spread it over.
  test "the largest obligation is named by what it costs, not by its slice" do
    create_series(name: "Paycheck", amount: -400, due: Date.current + 2, preset: "weekly", income: true)
    create_series(name: "Rent", amount: 2150, due: Date.current + 20)
    create_series(name: "Insurance", amount: 300, due: Date.current + 3)

    # The first paycheck, not the leading window: that one reserves nothing.
    period = Planner.new(@family, user: @user).plan(periods_limit: 3)[1]
    largest = period.largest_obligation

    assert_equal "Rent", largest.occurrence.recurring_transaction.name
    assert_equal 2150, largest.remaining_total
    assert largest.share < largest.remaining_total, "the slice is smaller than the bill it belongs to"
  end

  # The period is named by the income that opens it, because calling a pension
  # or an invoice a "paycheck" contradicts the user's own setup.
  test "a period carries the names of the income that opens it" do
    payday = Date.current + 2
    create_series(name: "Frito Lay", amount: -1200, due: payday, preset: "weekly", income: true)
    create_series(name: "Side work", amount: -300, due: payday, preset: "weekly", income: true)

    period = Planner.new(@family, user: @user).plan(periods_limit: 3)[1]

    assert_equal 1500, period.income
    assert_equal [ "Frito Lay", "Side work" ], period.income_sources.sort
  end

  # The income list and the plan used to read different sources for one fact,
  # so a series could name two different next paydays on one screen.
  test "next income per series comes from occurrences, not the stored column" do
    payday = Date.current + 5
    series = create_series(name: "Paycheck", amount: -1840, due: payday, preset: "weekly", income: true)
    series.update_columns(next_expected_date: Date.current - 1)

    planner = Planner.new(@family, user: @user)
    next_income = planner.next_income_by_series[series.id]

    assert_equal payday, next_income.due_on
    assert_equal planner.plan.find { |period| period.income.positive? }.starts_on, next_income.due_on,
      "the strip and the plan have to name the same day"
  end

  test "partial payments shrink the apportioned obligation" do
    create_series(name: "Paycheck", amount: -2000, due: Date.current + 2, preset: "weekly", income: true)
    rent = create_series(name: "Rent", amount: 2150, due: Date.current + 9)
    occurrence = rent.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: "1075")

    plan = Planner.new(@family, user: @user).plan
    rent_total = plan.flat_map(&:items)
                     .select { |item| item.occurrence.recurring_transaction_id == rent.id }
                     .sum(&:share)

    assert_equal 1075, rent_total, "only the remaining balance needs setting aside"
  end

  # Folding an unconvertible obligation in as zero inflates what the plan says
  # is safe to spend by exactly the amount the user cannot see.
  test "an obligation with no exchange rate is counted, not dropped" do
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 3, preset: "weekly", income: true)
    foreign = @family.recurring_transactions.create!(
      name: "Tokyo storage", account: @account, amount: 50_000, currency: "JPY",
      bill_type: "bill", expected_day_of_month: (Date.current + 5).day,
      anchor_date: Date.current + 5, last_occurrence_date: Date.current + 5,
      next_expected_date: Date.current + 5, status: "active", manual: true
    )
    assert_equal 0, ExchangeRate.where(from_currency: "JPY", to_currency: "USD").count,
      "the scenario depends on there being no rate to find"

    planner = Planner.new(@family, user: @user)
    plan = planner.plan(periods_limit: 3)

    assert plan.present?
    assert foreign.recurring_occurrences.any?, "the obligation really was inside the window"
    assert planner.unconvertible_count.positive?,
      "the JPY obligation must be reported, not silently valued at zero"
  end

  # Generation lag can leave a lone materialized paycheck landing today; the
  # boundary list collapses to one date and there is no period to build.
  test "income due today with no later occurrences yields an empty plan rather than raising" do
    series = create_series(name: "Final paycheck", amount: -1840, due: Date.current, income: true)
    series.recurring_occurrences.where("due_on > ?", Date.current).delete_all

    assert_equal [], Planner.new(@family, user: @user).plan
  end

  test "a past-due open bill lands whole in the leading window" do
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 7, preset: "weekly", income: true)
    overdue_due = Date.current - 3
    create_series(name: "Power", amount: 120, due: overdue_due)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 2)

    shares = plan.flat_map(&:items).select { |item| item.occurrence.due_on == overdue_due }
    assert_equal 1, shares.size, "the overdue bill must appear exactly once"
    assert_equal 120, shares.sum(&:share), "its whole remaining amount is owed now"
    assert shares.first.due_in_period, "it is due money, not a reserve"
    assert_includes plan.first.items, shares.first, "and it belongs to the leading window"
  end


  # The bridge window earns nothing by construction, so judging it the way every
  # other window is judged made "short before your next payday" fire for anyone
  # who simply had a bill before payday. What decides it is the cash in hand,
  # which the code claimed to compare and never did.
  test "a bridge window is short only when the cash cannot cover it" do
    set_cash(40)
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 5, preset: "weekly", income: true)
    create_series(name: "Water", amount: 64, due: Date.current + 2)

    bridge = Planner.new(@family, user: @user).plan(periods_limit: 3).first

    assert bridge.short?, "$64 due against $40 in the bank is a real shortfall"
    assert_equal 24, bridge.shortfall, "short by the gap, not by the whole bill"
  end

  test "a bridge window covered by cash reports what is left, not a shortfall" do
    set_cash(500)
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 5, preset: "weekly", income: true)
    create_series(name: "Water", amount: 64, due: Date.current + 2)

    bridge = Planner.new(@family, user: @user).plan(periods_limit: 3).first

    assert_not bridge.short?
    assert_equal 436, bridge.cash_after_obligations
  end

  test "an unknown balance is not evidence of a shortfall" do
    @family.accounts.update_all(status: "disabled")
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 5, preset: "weekly", income: true)
    create_series(name: "Water", amount: 64, due: Date.current + 2)

    bridge = Planner.new(@family, user: @user).plan(periods_limit: 3).first

    assert_nil bridge.cash_on_hand
    assert_not bridge.short?, "with no readable balance the window goes unjudged rather than flagged"
    assert_nil bridge.cash_after_obligations
  end

  # A paycheck window is still measured against its own paycheck: cash on hand
  # belongs to the gap before payday, not to the money that arrives on it.
  test "a paycheck window stays measured against its income" do
    set_cash(100_000)
    create_series(name: "Paycheck", amount: -100, due: Date.current + 1, preset: "weekly", income: true)
    create_series(name: "Rent", amount: 4_000, due: Date.current + 2)

    paying = Planner.new(@family, user: @user).plan(periods_limit: 3).reject(&:bridge?).first

    assert paying.short?, "a bill that outgrows its paycheck is short however much cash exists"
  end


  # One unconvertible account used to fold to zero inside the sum, so the cash
  # figure quietly shrank and the bridge cried short against a partial balance.
  test "one unconvertible account makes the cash balance unknown, not smaller" do
    ExchangeRate.delete_all
    set_cash(5_000)
    @family.accounts.create!(name: "EUR pocket", balance: 100, currency: "EUR",
                             accountable: Depository.new)
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 5, preset: "weekly", income: true)
    create_series(name: "Water", amount: 64, due: Date.current + 2)

    bridge = Planner.new(@family, user: @user).plan(periods_limit: 3).first

    assert_nil bridge.cash_on_hand, "a partial balance is not a balance"
    assert_not bridge.short?, "an unknown balance is not evidence of a shortfall"
  end

  private
    # The family fixture carries more than one deposit account, and the plan
    # sums all of them, so a test that means to pin the cash has to set them all.
    def set_cash(amount)
      @family.accounts.where(accountable_type: %q(Depository)).update_all(balance: amount / @family.accounts.where(accountable_type: %q(Depository)).count.to_d)
    end

    def create_series(name:, amount:, due:, preset: "monthly", income: false)
      series = @family.recurring_transactions.create!(
        name: name,
        account: @account,
        amount: amount,
        currency: "USD",
        bill_type: income ? "income" : "bill",
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: true
      )

      if preset != "monthly"
        RecurringTransaction::FrequencyPreset.apply(series, preset: preset, weekday: due.wday)
        series.save!
      end

      series
    end
end
