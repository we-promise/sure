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

  test "recurring transfers between own depository accounts are not bills; debt transfers are" do
    create_series(name: "Paycheck", amount: -2000, due: Date.current + 3, income: true)
    expense = create_series(name: "Rent", amount: 500, due: Date.current + 5)
    to_loan = create_series(name: "Mortgage payment", amount: 300, due: Date.current + 6)
    to_loan.update!(destination_account: accounts(:loan))
    to_savings = create_series(name: "To savings", amount: 700, due: Date.current + 7)
    to_savings.update!(destination_account: accounts(:connected))

    plan = Planner.new(@family, user: @user).plan(periods_limit: 2)
    series_ids = plan.flat_map(&:items).map { |item| item.occurrence.recurring_transaction_id }.uniq

    assert_includes series_ids, expense.id
    assert_includes series_ids, to_loan.id
    assert_not_includes series_ids, to_savings.id
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

  # Snoozing moves the day a bill falls due, and the overview's pay-period
  # markers already file a snoozed bill under the paycheck its new date lands
  # in. The plan kept the old date, so a bill snoozed past payday stayed owed
  # before it and the cash in hand read as short.
  test "a bill snoozed past payday is due in that payday's window" do
    set_cash(100)
    payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: payday, preset: "weekly", income: true)
    create_series(name: "Internet", amount: 90, due: payday + 2)
    power = create_series(name: "Power", amount: 120, due: Date.current - 6).recurring_occurrences.open_status.order(:due_on).first
    water = create_series(name: "Water", amount: 120, due: Date.current + 1).recurring_occurrences.open_status.order(:due_on).first
    power.snooze!(payday + 4)
    water.snooze!(payday + 5)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert_equal 0, plan.first.due_total, "nothing snoozed past payday is owed before it"
    assert_not plan.first.short?, "so $100 in the bank is not short"
    assert_equal %w[Internet Power Water], plan[1].items_due.map { |item| item.occurrence.recurring_transaction.name },
      "payday's window carries both, in the order of the dates they were snoozed to"
  end

  # Bills claim paychecks in date order, so a window's own bills are funded
  # before a later bill's overflow reaches back for the spare. A snoozed bill
  # takes its turn at its new date, or its overflow empties the paycheck of a
  # bill that now falls due before it.
  test "a snoozed bill claims paychecks in the order of its new date" do
    payday = Date.current + 3
    create_series(name: "Paycheck", amount: -100, due: payday, preset: "weekly", income: true)
    create_series(name: "Phone", amount: 150, due: payday + 8)
    insurance = create_series(name: "Insurance", amount: 150, due: payday + 1)
    insurance.recurring_occurrences.open_status.order(:due_on).first.snooze!(payday + 15)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert_equal 100, plan[3].due_total, "premise: the insurance is due in the week it was snoozed to"
    assert_equal 100, plan[2].due_total, "the phone bill takes its own paycheck before the insurance can"
    assert_equal 0, plan[2].reserved_total
    assert_equal %w[Phone Insurance], plan[1].items_reserved.map { |item| item.occurrence.recurring_transaction.name },
      "the first paycheck holds both overflows, listed in the order they fall due"
  end

  # A snooze can carry a bill out of the plan altogether. It is no longer one
  # of the plan's bills then, so it is in no period, and not among the bills
  # the page says it could not convert either.
  test "a bill snoozed past the last period leaves the plan" do
    payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: payday, preset: "weekly", income: true)
    bills = [
      create_series(name: "Insurance", amount: 300, due: payday + 2),
      create_series(name: "Tokyo storage", amount: 50_000, due: payday + 2, currency: "JPY")
    ]
    planner = Planner.new(@family, user: @user)
    last_day = planner.plan(periods_limit: 2).last.ends_on
    assert_equal 1, planner.unconvertible_count, "premise: inside the plan, the yen bill has no rate"

    bills.each { |bill| bill.recurring_occurrences.open_status.order(:due_on).first.snooze!(last_day + 1) }
    planner = Planner.new(@family, user: @user)
    plan = planner.plan(periods_limit: 2)

    assert plan.flat_map(&:items).none? { |item| bills.include?(item.occurrence.recurring_transaction) }
    assert_equal 0, planner.unconvertible_count
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

  # The Bills overview reads a window per payday from the plan, so each of
  # these pins one rule that used to live in the controller.
  test "through plans every payday up to the date and closes the last at the payday after it" do
    first = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: first, preset: "weekly", income: true)

    plan = Planner.new(@family, user: @user).plan(through: first + 7, cash: false)

    assert_equal [ Date.current, first, first + 7 ], plan.map(&:starts_on)
    assert_equal first + 13, plan.last.ends_on, "the last window runs to the day before the next payday"
  end

  test "the last window is closed by a payday derived from the schedule when none is stored" do
    series = create_series(name: "Paycheck", amount: -3000, due: Date.current + 3, income: true)
    last = series.recurring_occurrences.maximum(:due_on)
    successor = series.schedule.next_occurrence_after(last)
    assert series.recurring_occurrences.where(due_on: successor).none?, "precondition: the successor is not stored yet"

    plan = Planner.new(@family, user: @user).plan(through: last, cash: false)

    assert_equal last, plan.last.starts_on
    assert_equal successor - 1, plan.last.ends_on
  end

  # A schedule repeats before the income it describes starts, so projecting it
  # forward can land on a date that is not a payday yet.
  test "a derived payday cannot fall before the income starts" do
    existing = create_series(name: "Paycheck", amount: -3000, due: Date.current + 3, income: true)
    last = existing.recurring_occurrences.maximum(:due_on)
    later = create_series(name: "New job", amount: -2000, due: Date.current + 120, preset: "weekly", income: true)
    assert later.recurring_occurrences.where(due_on: ..(Date.current + 90)).none?, "precondition: the new income has nothing stored yet"
    assert_operator later.schedule.next_occurrence_after(last), :<, existing.schedule.next_occurrence_after(last),
      "precondition: unanchored, the new income's schedule would end the window early"

    plan = Planner.new(@family, user: @user).plan(through: last, cash: false)

    assert_equal existing.schedule.next_occurrence_after(last) - 1, plan.last.ends_on
  end

  test "a payday that was skipped does not end a window" do
    first = Date.current + 3
    paycheck = create_series(name: "Paycheck", amount: -1840, due: first, preset: "weekly", income: true)
    paycheck.recurring_occurrences.open_status.order(:due_on).second.skip!

    plan = Planner.new(@family, user: @user).plan(through: first, cash: false)

    assert_equal first + 13, plan.last.ends_on, "the window runs to the next payday that is still coming"
  end

  test "a payday that is already settled does not end a window, as in the default plan" do
    first = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: first, preset: "weekly", income: true)
    bonus = create_series(name: "Bonus", amount: -500, due: first + 3, income: true)
    bonus.recurring_occurrences.open_status.order(:due_on).first.close!("paid", source: "user")
    create_series(name: "Gym", amount: 100, due: first + 4)

    through = Planner.new(@family, user: @user).plan(through: first, cash: false)
    default = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert_equal [ Date.current, first ], through.map(&:starts_on)
    assert_equal first + 6, through.last.ends_on, "money that already arrived does not close the window"
    assert_equal default[1].ends_on, through.last.ends_on
    assert_equal default[1].bills_total, through.last.bills_total, "both views total the same bills"
    assert_equal 100, through.last.bills_total, "the bill after the settled payday still sits in a window"
  end

  test "a snoozed payday opens its window on the date it was snoozed to" do
    first = Date.current + 3
    paycheck = create_series(name: "Paycheck", amount: -1840, due: first, preset: "weekly", income: true)
    paycheck.recurring_occurrences.open_status.order(:due_on).first.snooze!(first + 2)

    default = Planner.new(@family, user: @user).plan(periods_limit: 3)
    through = Planner.new(@family, user: @user).plan(through: first + 7, cash: false)

    assert_equal first + 2, default[1].starts_on
    assert_equal first + 1, default.first.ends_on
    assert_equal 1840, default[1].income
    assert_equal first + 2, through[1].starts_on, "every view opens the window on the same date"
  end

  test "bills_total counts a bill in full where it falls due, even when its paycheck cannot fund it" do
    first = Date.current + 3
    create_series(name: "Paycheck", amount: -1000, due: first, preset: "weekly", income: true)
    create_series(name: "Rent", amount: 2150, due: first + 9)

    window = Planner.new(@family, user: @user).plan(through: first + 7, cash: false).last

    assert_equal first + 7, window.starts_on
    assert_equal 2150, window.bills_total
    assert_equal 1000, window.due_total, "due_total is only the share this paycheck funds"
    assert window.bills_total_known?
  end

  test "a window that reaches past the bill horizon is flagged" do
    create_series(name: "Paycheck", amount: -4000, due: Date.current + 3, preset: "quarterly", income: true)

    window = Planner.new(@family, user: @user).plan(through: Date.current + 3, cash: false).last

    assert_equal Date.current + 3, window.starts_on
    assert window.beyond_horizon, "the bills due after the horizon are not stored yet"
    assert_not window.bills_total_known?
  end

  test "a window inside the horizon is not flagged" do
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 3, preset: "weekly", income: true)

    plan = Planner.new(@family, user: @user).plan(through: Date.current + 10, cash: false)

    assert plan.none?(&:beyond_horizon)
    assert plan.all?(&:bills_total_known?)
  end

  test "a window holding a bill with no exchange rate cannot state a total" do
    first = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: first, preset: "weekly", income: true)
    @family.recurring_transactions.create!(
      name: "Tokyo storage", account: @account, amount: 50_000, currency: "JPY",
      bill_type: "bill", expected_day_of_month: (first + 2).day,
      anchor_date: first + 2, last_occurrence_date: first + 2,
      next_expected_date: first + 2, status: "active", manual: true
    )
    assert_equal 0, ExchangeRate.where(from_currency: "JPY", to_currency: "USD").count

    plan = Planner.new(@family, user: @user).plan(through: first, cash: false)

    assert plan.last.unconvertible
    assert_not plan.last.bills_total_known?
    assert plan.first.bills_total_known?, "only the window holding the bill is affected"
  end

  test "cash: false leaves the balance out" do
    create_series(name: "Paycheck", amount: -1840, due: Date.current + 3, preset: "weekly", income: true)

    assert_nil Planner.new(@family, user: @user).plan(through: Date.current + 3, cash: false).first.cash_on_hand
  end

  private
    # The family fixture carries more than one deposit account, and the plan
    # sums all of them, so a test that means to pin the cash has to set them all.
    def set_cash(amount)
      @family.accounts.where(accountable_type: %q(Depository)).update_all(balance: amount / @family.accounts.where(accountable_type: %q(Depository)).count.to_d)
    end

    def create_series(name:, amount:, due:, preset: "monthly", income: false, currency: "USD")
      series = @family.recurring_transactions.create!(
        name: name,
        account: @account,
        amount: amount,
        currency: currency,
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
