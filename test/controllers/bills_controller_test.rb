require "test_helper"

class BillsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    ensure_tailwind_build
  end

  # Bills was the only top-level destination with no heading, so screen readers
  # got no outline and it broke the page-header pattern every other page follows.
  test "every bills view has a page heading" do
    create_bill(name: "Rent", amount: 1200)

    %w[overview calendar paycheck subscriptions all].each do |view|
      get view == "overview" ? bills_url : bills_url(view: view)

      assert_response :success
      assert_select "main h1", text: I18n.t("bills.index.title"),
        message: "the #{view} view is missing its page heading"
    end
  end

  test "index lists a bill" do
    bill = create_bill(name: "Rent", amount: 1200)

    get bills_url

    assert_response :success
    assert_match "Rent", response.body
  end

  # A bill is something you owe. Income is not owed, an internal transfer is not owed,
  # and a paused row was explicitly set aside, so none of them belong on the list.
  test "index excludes income and inactive rows but shows debt payments" do
    create_bill(name: "Real bill", amount: 50)
    create_bill(name: "Salary deposit", amount: -2000)
    create_bill(name: "Paused bill", amount: 30, status: "inactive")
    # A recurring transfer into a credit card is a real obligation with a
    # real due date -- it belongs on the pay-run page, marked as what it is.
    create_bill(name: "Card payment", amount: 100,
                destination_account_id: accounts(:credit_card).id)
    # A transfer into an asset account is just moving money; not a bill.
    create_bill(name: "Moved to savings", amount: 100,
                destination_account_id: accounts(:investment).id)

    get bills_url

    assert_response :success
    assert_match "Real bill", response.body
    assert_match "Card payment", response.body
    assert_match I18n.t("bills.debt_payment"), response.body
    assert_no_match "Salary deposit", response.body
    assert_no_match "Paused bill", response.body
    assert_no_match "Moved to savings", response.body
  end

  test "index shows an overdue occurrence in the overdue section" do
    overdue_day = 10.days.ago.to_date
    create_bill(name: "Late bill", amount: 75,
                expected_day_of_month: overdue_day.day,
                last_occurrence_date: 2.months.ago.to_date,
                next_expected_date: overdue_day)

    get bills_url

    assert_response :success
    assert_match "Late bill", response.body
    assert_match I18n.t("bills.row_overdue"), response.body
    assert_match "past due", response.body
  end

  # Overdue rows used to sit inside the chronological month list, marked only by
  # a word where their date would be, which made the most urgent rows the
  # easiest to scroll past.
  test "overdue bills are lifted out of the month list into their own section" do
    overdue_day = 10.days.ago.to_date
    create_bill(name: "Late bill", amount: 75,
                expected_day_of_month: overdue_day.day,
                last_occurrence_date: 2.months.ago.to_date,
                next_expected_date: overdue_day)

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.needs_attention"), response.body

    body = response.body
    attention_at = body.index(I18n.t("bills.index.needs_attention"))
    month_at = body.index(I18n.t("bills.index.this_month"))
    late_at = body.index("Late bill")

    assert_not_nil attention_at
    assert_operator attention_at, :<, late_at, "the late bill belongs under Needs attention"
    assert_operator late_at, :<, month_at, "and above This month, not inside it" if month_at
  end

  # "Status" used to mean the series lifecycle, so the one question people
  # actually bring to this table -- what is late -- could not be asked.
  test "the all view filters by payment state, not just lifecycle" do
    overdue_day = 10.days.ago.to_date
    late = create_bill(name: "Late Co", amount: 75,
                       expected_day_of_month: overdue_day.day,
                       last_occurrence_date: 2.months.ago.to_date,
                       next_expected_date: overdue_day)
    upcoming = create_bill(name: "Future Co", amount: 40, manual: true,
                           anchor_date: 20.days.from_now.to_date,
                           expected_day_of_month: 20.days.from_now.to_date.day,
                           last_occurrence_date: Date.current,
                           next_expected_date: 20.days.from_now.to_date)

    # The filter is only meaningful if the fixtures are in the states it sorts by.
    assert late.current_occurrence.overdue?, "Late Co must actually be overdue"
    assert_not upcoming.current_occurrence.overdue?, "Future Co must not be"

    get bills_url(view: "all", q: { status: "overdue" })

    assert_response :success
    assert_match "Late Co", response.body
    assert_no_match "Future Co", response.body

    get bills_url(view: "all", q: { status: "paused" })
    assert_response :success
    assert_no_match "Late Co", response.body, "lifecycle filtering still works"
  end

  test "index cannot see another family's bills" do
    families(:empty).recurring_transactions.create!(
      name: "Someone else's rent",
      amount: 999,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active"
    )

    get bills_url

    assert_response :success
    assert_no_match "Someone else's rent", response.body
  end

  test "index redirects when the family has turned recurring transactions off" do
    @family.update!(recurring_transactions_disabled: true)

    get bills_url

    assert_redirected_to root_path
  end

  # The headline answers "how much do I owe", which is one number, so foreign-currency
  # bills are converted rather than suppressing the total the way this first did.
  test "index totals bills in the family currency" do
    create_bill(name: "Domestic bill", amount: 100)
    create_bill(name: "Foreign bill", amount: 50, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 2)

    get bills_url

    assert_response :success
    assert_match "200", response.body
  end

  test "index still totals what it can when a rate is missing" do
    create_bill(name: "Domestic bill", amount: 100)
    create_bill(name: "Unconvertible bill", amount: 50, currency: "JPY")

    get bills_url

    assert_response :success
    assert_match "Unconvertible bill", response.body
    assert_match I18n.t("bills.index.unconvertible", count: 1), response.body
  end

  # Autopay is information, not a task. The bill stays listed and still counts toward
  # the total, but it must not read as something demanding to be clicked.
  test "index shows an autopaying bill without a pay call to action" do
    create_bill(name: "Handled bill", amount: 30, autopay: true,
                payment_url: "https://pay.example.com")

    get bills_url

    assert_response :success
    assert_match "Handled bill", response.body
    assert_match I18n.t("recurring_transactions.pay_action.autopay"), response.body
    assert_no_match(/>\s*#{I18n.t("recurring_transactions.pay_action.pay")}\s*</, response.body)
  end

  test "index shows the account a bill is paid from and its notes" do
    create_bill(name: "Annotated bill", amount: 60, notes: "Account 4821, on the Amex")

    get bills_url

    assert_response :success
    assert_match "Account 4821, on the Amex", response.body
    assert_match I18n.t("bills.paid_from", account: accounts(:depository).name), response.body
  end

  # Three concurrent subscriptions to one merchant, at different prices on
  # different days, are three real bills and render as three rows.
  test "index shows separate subscription tiers as separate rows" do
    create_bill(name: "TWITCH", amount: 5.99, expected_day_of_month: 8)
    create_bill(name: "TWITCH", amount: 11.99, expected_day_of_month: 2)
    create_bill(name: "TWITCH", amount: 24.99, expected_day_of_month: 21)

    get bills_url

    assert_response :success
    assert_operator response.body.scan("TWITCH").size, :>=, 3
  end

  test "index sums the remaining KPI from open occurrences" do
    create_bill(name: "One", amount: 100)
    create_bill(name: "Two", amount: 50)

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.left_to_pay"), response.body
    assert_match "$150", response.body
  end

  test "partial payment moves the remaining KPI and shows progress" do
    bill = create_bill(name: "Rent", amount: 2000)
    occurrence = bill.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: "750")

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.partial_progress", paid: "$750.00", expected: "$2,000.00"), response.body
    assert_match "$1,250", response.body
  end

  # The row expansion described the SERIES definition while the drawer described
  # the current occurrence, so an overdue bill greeted you with "Next payment"
  # in one surface and "Overdue" in the other, at the same moment.
  test "the row expansion and the drawer tell the same story about an overdue bill" do
    overdue_day = 6.days.ago.to_date
    bill = create_bill(name: "Late Co", amount: 5.99,
                       expected_day_of_month: overdue_day.day,
                       last_occurrence_date: 2.months.ago.to_date,
                       next_expected_date: overdue_day)
    occurrence = bill.recurring_occurrences.order(:due_on).detect(&:overdue?)
    assert occurrence, "the fixture must actually be overdue"

    days = (Date.current - occurrence.effective_due_on).to_i
    overdue_phrase = I18n.t("bills.due_label.overdue", count: days,
                            date: I18n.l(occurrence.effective_due_on, format: :short))

    get bill_url(bill), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_match overdue_phrase, response.body, "the drawer states the status"

    get bill_url(bill, display: "pane", frame: "x"), headers: { "Turbo-Frame" => "x" }
    assert_response :success
    assert_match overdue_phrase, response.body, "and the expansion must state the same one"
    assert_no_match I18n.t("bills.pane.next_payment"), response.body,
      "an overdue bill is not a next payment"
  end

  test "show renders the bill drawer with history and analytics" do
    bill = create_bill(name: "Power Co", amount: 80)
    past = bill.recurring_occurrences.create!(
      family: @family, original_due_on: 2.months.ago.to_date, due_on: 2.months.ago.to_date,
      currency: "USD"
    )
    RecurringTransaction::Allocator.new(past).allocate!(amount: "78.50")
    past.reload

    get bill_url(bill), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_equal 1, response.body.scan(/<turbo-frame[^>]*id="drawer"/).size
    assert_match I18n.t("bills.show.history"), response.body
    assert_match I18n.t("bills.show.ytd"), response.body
    assert_match "$78.50", response.body
  end

  # The average sat beside per-year totals that are sums of real payments, so
  # reading estimates here put two disagreeing numbers about the same money in
  # one panel. Expected $80 twice, really charged $76 and $78: the average is
  # $77, a figure that appears nowhere if the estimates are averaged instead.
  test "drawer analytics average what was charged, not what was expected" do
    bill = create_bill(name: "Power Co", amount: 80)

    [ [ 3, 76 ], [ 2, 78 ] ].each do |months_ago, charged|
      due = months_ago.months.ago.to_date
      occurrence = bill.recurring_occurrences.create!(
        family: @family, original_due_on: due, due_on: due, currency: "USD")
      RecurringTransaction::Allocator.new(occurrence).allocate!(amount: charged.to_s)
      assert occurrence.reload.paid?, "each charge is inside tolerance and should settle the cycle"
    end

    get bill_url(bill), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match "$77.00", response.body
  end

  test "the all view lists every series and filters compose" do
    create_bill(name: "Alpha bill", amount: 10)
    create_bill(name: "Beta paused", amount: 20, status: "paused")
    create_bill(name: "Gamma income", amount: -500)

    get bills_url(view: "all")
    assert_response :success
    assert_match "Alpha bill", response.body
    assert_match "Beta paused", response.body
    assert_match "Gamma income", response.body

    get bills_url(view: "all", q: { status: "paused" })
    assert_match "Beta paused", response.body
    assert_no_match "Alpha bill", response.body

    get bills_url(view: "all", q: { search: "gamma" })
    assert_match "Gamma income", response.body
    assert_no_match "Beta paused", response.body
  end

  test "the calendar renders the month grid with paid and overdue states" do
    paid_bill = create_bill(name: "Paid on time", amount: 40, expected_day_of_month: 5)
    paid_occurrence = paid_bill.recurring_occurrences.find_by!(due_on: Date.current.beginning_of_month + 4)
    RecurringTransaction::Allocator.new(paid_occurrence).allocate!(amount: "40")

    overdue_day = [ Date.current - 6, Date.current.beginning_of_month ].max
    create_bill(name: "Still owed", amount: 60,
                expected_day_of_month: overdue_day.day,
                last_occurrence_date: 2.months.ago.to_date,
                next_expected_date: overdue_day)

    get bills_url(view: "calendar")

    assert_response :success
    assert_match "Paid on time", response.body
    assert_match "Still owed", response.body
    assert_match Date.current.strftime("%B %Y"), response.body
  end

  test "the calendar materializes a far-future month on demand" do
    create_bill(name: "Forward bill", amount: 25)
    target = (Date.current + 6.months).beginning_of_month

    get bills_url(view: "calendar", month: target.strftime("%Y-%m"))

    assert_response :success
    assert_match "Forward bill", response.body
  end

  test "the calendar caps forward navigation" do
    create_bill(name: "Some bill", amount: 25)
    beyond = (Date.current + 30.months).strftime("%Y-%m")

    get bills_url(view: "calendar", month: beyond)

    assert_response :success
    limit_month = (Date.current + 13.months).beginning_of_month
    assert_match limit_month.strftime("%B %Y"), response.body
  end

  test "the paycheck view prompts for income, then plans around it" do
    create_bill(name: "Rent", amount: 2150)

    get bills_url(view: "paycheck")
    assert_response :success
    assert_match I18n.t("bills.paycheck.empty.title"), response.body

    payday = Date.current + 3
    @family.recurring_transactions.create!(
      name: "Paycheck", account: accounts(:depository), amount: -1840, currency: "USD",
      bill_type: "income", expected_day_of_month: payday.day, anchor_date: payday,
      last_occurrence_date: payday, next_expected_date: payday, status: "active", manual: true
    )

    get bills_url(view: "paycheck")
    assert_response :success
    assert_match I18n.t("bills.paycheck.paycheck_of", date: I18n.l(payday, format: :long)), response.body
    assert_match "Rent", response.body
    assert_match I18n.t("bills.paycheck.remaining_after_bills"), response.body
  end

  test "every overview row carries its own empty expansion frame" do
    create_bill(name: "Rent", amount: 2150)

    get bills_url

    assert_response :success
    assert_match(/<turbo-frame[^>]*id="pane_recurring_occurrence_/, response.body)
    assert_match(/data-turbo-frame="pane_recurring_occurrence_/, response.body)
  end

  test "the expansion renders into the requesting row frame and can collapse" do
    bill = create_bill(name: "Rent", amount: 2150)

    get bill_url(bill, display: "pane", frame: "pane_recurring_occurrence_abc123")
    assert_response :success
    assert_match(/<turbo-frame[^>]*id="pane_recurring_occurrence_abc123"/, response.body)

    get bill_url(bill, display: "pane", frame: "pane_recurring_occurrence_abc123", close: 1)
    assert_response :success
    assert_match(/<turbo-frame[^>]*id="pane_recurring_occurrence_abc123"><\/turbo-frame>/, response.body)
    assert_no_match I18n.t("bills.pane.rules"), response.body
  end

  test "the detail pane tells the bill's story inside its frame" do
    bill = create_bill(name: "Rent", amount: 2150)
    occurrence = bill.recurring_occurrences.order(:due_on).first
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 2150, currency: "USD", name: "WATSON PROPERTY",
      entryable: Transaction.new
    )
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: "2150", entry: entry)

    get bill_url(bill, display: "pane")

    assert_response :success
    assert_match(/<turbo-frame[^>]*id="bill_detail"/, response.body, "no frame param falls back to a stable id")
    assert_match I18n.t("bills.pane.rules"), response.body
    assert_match I18n.t("bills.pane.key_metrics"), response.body
    assert_match I18n.t("bills.pane.recent_payments"), response.body
    assert_match "WATSON PROPERTY", response.body
    assert_no_match(/<html/, response.body, "the pane renders frame-only, no layout")
  end

  test "the paycheck view lists declared income with an edit affordance" do
    payday = Date.current + 3
    income = @family.recurring_transactions.create!(
      name: "Paycheck", account: accounts(:depository), amount: -1840, currency: "USD",
      bill_type: "income", expected_day_of_month: payday.day, anchor_date: payday,
      last_occurrence_date: payday, next_expected_date: payday, status: "active", manual: true
    )

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.income_section_title"), response.body
    assert_match edit_recurring_transaction_path(income), response.body
    assert_match bill_path(income), response.body, "income opens the same drawer as bills for pause and delete"
  end

  test "the subscriptions view rolls up cost and surfaces price changes" do
    sub = create_bill(name: "STREAMFLIX", amount: 24.99)
    sub.update!(bill_type: "subscription", trial_ends_on: Date.current + 5)
    sub.recurring_price_changes.create!(
      effective_on: 2.months.ago.to_date, previous_amount: 19.99, new_amount: 24.99,
      currency: "USD", source: "detected"
    )

    get bills_url(view: "subscriptions")

    assert_response :success
    assert_match "STREAMFLIX", response.body
    assert_match I18n.t("bills.subscriptions.monthly_cost"), response.body
    assert_match I18n.t("bills.subscriptions.trial_chip", date: I18n.l(Date.current + 5, format: :short)), response.body
    assert_match I18n.t("bills.subscriptions.price_changes"), response.body
  end

  test "notices surface trials, renewals and price changes" do
    sub = create_bill(name: "STREAMFLIX", amount: 24.99)
    sub.update!(bill_type: "subscription", trial_ends_on: Date.current + 3)
    sub.recurring_price_changes.create!(
      effective_on: Date.current - 5, previous_amount: 19.99, new_amount: 24.99,
      currency: "USD", source: "detected"
    )

    get bills_url

    assert_response :success
    assert_match "trial ends #{I18n.l(Date.current + 3, format: :long)}", response.body
    assert_match "changed price", response.body
  end

  test "the ical feed serves upcoming occurrences with a signed token and rejects garbage" do
    create_bill(name: "Rent", amount: 2150)

    get bills_feed_url(token: BillsFeedsController.token_for(@family))
    assert_response :success
    assert_match "BEGIN:VCALENDAR", response.body
    assert_match "Rent", response.body

    get bills_feed_url(token: "tampered")
    assert_response :not_found
  end

  test "index renders an empty state with no bills" do
    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.empty.title"), response.body
  end

  # A cancellation date does not stop the schedule, so the same bill can read
  # "Cancelled" on one surface and "Overdue" on another. The detail surfaces
  # have to admit that rather than let the two claims sit apart.
  test "a cancelled but still-scheduled bill says so, with the action that stops it" do
    bill = create_bill(name: "Streamly", amount: 15, bill_type: "subscription",
                       cancelled_on: 3.days.ago.to_date)
    assert bill.cancelled_on.present? && bill.active?, "premise: cancelled yet still running"

    get bill_url(bill)
    assert_response :success
    assert_includes response.body,
      I18n.t("bills.cancelled_still_scheduled", date: I18n.l(bill.cancelled_on, format: :short))
    assert_includes response.body, toggle_status_recurring_transaction_path(bill)
  end

  test "a paused bill does not repeat the cancellation notice" do
    bill = create_bill(name: "Streamly", amount: 15, bill_type: "subscription",
                       cancelled_on: 3.days.ago.to_date, status: "paused")
    get bill_url(bill)
    assert_response :success
    refute_includes response.body,
      I18n.t("bills.cancelled_still_scheduled", date: I18n.l(bill.cancelled_on, format: :short))
  end

  private

    def create_bill(name:, amount:, **overrides)
      @family.recurring_transactions.create!({
        account: accounts(:depository),
        name: name,
        amount: amount,
        # Defaults to the amount so same-name test bills (separate
        # subscription tiers) coexist under the amount-free identity indexes,
        # the same way the detector stamps a second series for one identifier.
        dedup_scope: amount.to_s,
        currency: "USD",
        expected_day_of_month: Date.current.day,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active"
      }.merge(overrides))
    end
end
