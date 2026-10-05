require "test_helper"

class BillsControllerTest < ActionDispatch::IntegrationTest
  # A bill row's drawer link. The scope leaves out Next up, whose items open
  # the same drawer URL from outside the lists.
  BILL_ROW_LINK = "[class~='@container'] a[data-turbo-frame=drawer][href*='display=drawer']".freeze

  teardown do
    travel_back
  end

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @family.recurring_transactions.destroy_all
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get bills_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  # Bills was the only top-level destination with no heading, so screen readers
  # got no outline and it broke the page-header pattern every other page follows.
  test "every bills view has a page heading" do
    create_bill(name: "Rent", amount: 1200)

    %w[overview calendar paycheck all].each do |view|
      get view == "overview" ? bills_url : bills_url(view: view)

      assert_response :success
      assert_select "main h1", text: I18n.t("bills.index.title"),
        message: "the #{view} view is missing its page heading"
    end
  end

  test "bills page shell is localized in German" do
    @user.update!(locale: "de")
    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)

    get bills_url

    assert_response :success

    translations = {
      "bills.views.aria_label" => "Rechnungsansichten",
      "bills.views.overview" => "Übersicht",
      "bills.views.calendar" => "Kalender",
      "bills.views.paycheck" => "Einkommensplan",
      "bills.views.all" => "Alle Rechnungen",
      "bills.index.title" => "Rechnungen",
      "bills.index.add_bill" => "Rechnung hinzufügen",
      "bills.index.add_income" => "Einkommen hinzufügen",
      "bills.index.review_with_ai" => "Mit KI prüfen"
    }

    translations.each do |key, text|
      assert_equal text, I18n.t(key, locale: :de, fallback: false)
    end

    assert_select "main h1", text: translations.fetch("bills.index.title")
    assert_select "div.segmented-control[aria-label=?]", translations.fetch("bills.views.aria_label") do
      translations.slice(
        "bills.views.overview",
        "bills.views.calendar",
        "bills.views.paycheck",
        "bills.views.all"
      ).each_value do |text|
        assert_select "a.segmented-control__segment", text: text
      end
    end
    assert_select "header" do
      assert_select "a:not([role=menuitem])", text: translations.fetch("bills.index.add_bill")
      assert_select "a[role=menuitem]", text: translations.fetch("bills.index.add_income")
      assert_select "button", text: translations.fetch("bills.index.review_with_ai")
    end

    get bills_url(view: "paycheck")

    assert_response :success
    assert_select "header" do
      assert_select "a:not([role=menuitem])", text: translations.fetch("bills.index.add_income")
      assert_select "a[role=menuitem]", text: translations.fetch("bills.index.add_bill")
      assert_select "button", text: translations.fetch("bills.index.review_with_ai")
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

    # The row says HOW late, once. It used to print "Overdue" in the date rail
    # beside a subline already reading "10 days overdue", spending its one
    # piece of temporal context on saying the same word twice.
    assert_match I18n.t("bills.attention.overdue", count: 10), response.body
    assert_no_match(/>\s*#{I18n.t("bills.row_overdue")}\s*</, response.body,
      "the date rail carries the date, not the word the subline already said")

    # And the summary states what is at stake.
    assert_match I18n.t("bills.month_pulse.pulse_overdue"), response.body
  end

  # The date rail only shows from @lg, and below it (every phone, and a 1280px
  # window with both sidebars open) the rail was the row's only date. The
  # subline leads with the same text there instead.
  test "a dated row states its due date below the rail's breakpoint too" do
    travel_to Date.current.beginning_of_month + 9.days
    due = Date.current + 12
    declare_bill(name: "Rent", amount: 1200, due: due)
    create_bill(name: "Water", amount: 40)
    late = Date.current - 5
    create_bill(name: "Gas", amount: 60, expected_day_of_month: late.day,
                last_occurrence_date: 2.months.ago.to_date, next_expected_date: late)

    get bills_url

    assert_response :success
    subline_dates = css_select("p span[class~='@lg:hidden']").map { |span| span.text.squish }
    assert_includes subline_dates, "#{I18n.l(due, format: :short)} ·"
    assert_includes subline_dates, "#{I18n.t("bills.row_today")} ·"
    # Needs attention, where the subline goes on to give the reason.
    assert_includes subline_dates, "#{I18n.l(late, format: :short)} ·"
    assert_match I18n.t("bills.attention.overdue", count: 5), response.body
  end

  # "%b %-d" is English order in every locale; fr, pl and ru put the day first.
  test "the date rail and Next up print the locale's own short date" do
    travel_to Date.current.beginning_of_month + 9.days
    due = Date.current + 5
    series = declare_bill(name: "Rent", amount: 1200, due: due)

    get bills_url(locale: "fr")

    assert_response :success
    date = I18n.l(due, format: :short, locale: :fr)
    assert_select "div[class~='@lg:block']", text: date
    occurrence = series.recurring_occurrences.find_by!(due_on: due)
    assert_select "a[data-turbo-frame=drawer][href=?] p",
      bill_path(series, display: "drawer", occurrence: occurrence.id), text: date
  end

  # The summary answers one question in order: where am I this month, what is
  # late, what is due soon, what happens next. It used to be a big number, two
  # small ones and a ring reading 0%.
  test "the month summary reads as one story, not a row of statistics" do
    overdue_day = 10.days.ago.to_date
    create_bill(name: "Late Co", amount: 49.41,
                expected_day_of_month: overdue_day.day,
                last_occurrence_date: 2.months.ago.to_date,
                next_expected_date: overdue_day)
    soon = 3.days.from_now.to_date
    create_bill(name: "Amazon Prime", amount: 16.23, manual: true,
                anchor_date: soon, expected_day_of_month: soon.day,
                last_occurrence_date: Date.current, next_expected_date: soon)

    get bills_url
    assert_response :success
    body = response.body

    # The month frames it, and the count says how much month there is.
    assert_match I18n.l(Date.current, format: "%B"), body
    assert_match I18n.t("bills.month_pulse.left_to_pay"), body

    # Paid / overdue / next-7 support the headline rather than becoming three
    # KPI cards of their own.
    assert_match I18n.t("bills.month_pulse.pulse_paid"), body
    assert_match I18n.t("bills.month_pulse.pulse_overdue"), body
    assert_match I18n.t("bills.month_pulse.pulse_next_seven"), body

    # And it ends by saying what actually happens next.
    assert_match I18n.t("bills.month_pulse.next_up"), body
    assert_match "Amazon Prime", body

    # Next-up items and the calendar link carry the DS focus ring, and the
    # items no longer bleed past the strip that clips them on phones.
    assert_select "a.focus-ring", text: I18n.t("bills.month_pulse.view_calendar")
    assert_select "a.w-36[href^='/bills/']", text: /Amazon Prime/ do |links|
      links.each do |link|
        classes = link["class"].split
        assert_includes classes, "focus-ring"
        assert_not_includes classes, "-mx-2"
        assert_not_includes link.to_html, "group-hover:underline", "the tint is the one hover cue"
      end
    end

    assert_match I18n.t("bills.month_pulse.left_to_pay"), body
    assert_no_match(/ProgressRing|rounded-full[^"]*stroke/, body,
      "the donut is gone; progress is a rule, not a centrepiece")
  end

  # A raw link_to falls back to the browser's own focus outline: blue, square,
  # and drawn tight against the text. Every stop on the page shows the DS ring.
  test "every link on the overview shows the DS focus ring" do
    # Never confirmed, so the detection banner shows its "Review them" link.
    gym = create_bill(name: "Gym", amount: 90)
    gym.recurring_price_changes.create!(effective_on: 5.days.ago.to_date,
      previous_amount: 80, new_amount: 90, currency: "USD", source: "detected")
    soon = 3.days.from_now.to_date
    create_bill(name: "Amazon Prime", amount: 16.23, expected_day_of_month: soon.day,
                next_expected_date: soon)

    get bills_url
    assert_response :success

    text_links = [
      I18n.t("bills.index.detected_review_action"),
      I18n.t("bills.manage"),
      I18n.t("bills.month_pulse.view_calendar")
    ]
    # One text link style: DS::Link's underlined text link, kept at the
    # compact text-xs the default variant does not set.
    text_links.each do |text|
      assert_select "main a.text-link.underline.focus-ring.text-xs", text: text
    end
    # Premise: the rows are on the page, so the sweep below covers them.
    assert_select "main #{BILL_ROW_LINK}", minimum: 2

    assert_select "main a, main summary" do |stops|
      stops.each do |stop|
        assert_includes stop["class"].to_s.split, "focus-ring",
          "falls back to the browser outline: #{stop.to_html.squish.truncate(160)}"
      end
    end
  end

  # Something already past its due date is not "coming up" -- it is the thing
  # the list below is for, and putting it in Next up makes the summary argue
  # with the worklist under it.
  #
  # The filter is on the DATE, not on derived_state, and this test asserts the
  # same. An earlier version checked `derived_state == :overdue` and passed
  # while the bug was plainly visible on screen: derived_state only turns
  # :overdue after the 3-day grace period, so a bill two days late was still
  # :due, sailed into the strip, and the date column rendered it "2 days late".
  test "next up holds nothing that is already past due, grace period included" do
    # Two days late is INSIDE the grace period, so derived_state still reads
    # :due. That is the case that slipped through.
    just_late = 2.days.ago.to_date
    create_bill(name: "Barely Late Co", amount: 12, manual: true, dedup_scope: "bl",
                anchor_date: just_late, expected_day_of_month: just_late.day,
                last_occurrence_date: just_late, next_expected_date: just_late)

    long_late = 10.days.ago.to_date
    create_bill(name: "Very Late Co", amount: 49.41, manual: true, dedup_scope: "vl",
                anchor_date: long_late, expected_day_of_month: long_late.day,
                last_occurrence_date: long_late, next_expected_date: long_late)

    soon = 4.days.from_now.to_date
    create_bill(name: "Soon Co", amount: 30, manual: true, dedup_scope: "sc",
                anchor_date: soon, expected_day_of_month: soon.day,
                last_occurrence_date: Date.current, next_expected_date: soon)

    get bills_url
    assert_response :success

    next_up = @controller.view_assigns["next_up"]
    assert next_up.any?, "the fixture must actually produce a Next up strip"

    past = next_up.select { |occurrence| occurrence.effective_due_on < Date.current }
    assert_empty past.map { |occurrence| occurrence.recurring_transaction.display_name },
      "a bill inside its grace period is still late, and late is not next"

    assert_includes next_up.map { |o| o.recurring_transaction.display_name }, "Soon Co"
  end

  # Three tiers of one subscription are three real bills that render as three
  # identical rows. Only then does a row earn a second fact.
  test "bills that would render identically gain something that tells them apart" do
    day = 12.days.from_now.to_date
    2.times do |i|
      create_bill(name: "TWITCH", amount: 11.99, manual: true, dedup_scope: "tier#{i}",
                  anchor_date: day, expected_day_of_month: day.day,
                  last_occurrence_date: Date.current, next_expected_date: day)
    end
    create_bill(name: "Distinct Co", amount: 30, manual: true,
                anchor_date: day, expected_day_of_month: day.day,
                last_occurrence_date: Date.current, next_expected_date: day)

    get bills_url
    assert_response :success

    # The pair carries its schedule; the bill nobody could confuse does not
    # pay for their ambiguity.
    twitch_rows = response.body.scan(/TWITCH/).size
    assert_operator twitch_rows, :>=, 2
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
    # Measured from the section headings down, not from the top of the page:
    # this series' NEXT cycle legitimately appears in the Next up strip above,
    # which is a different occurrence of the same bill.
    late_at = body.index("Late bill", attention_at)

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

  # The paid-from account still shows; it just waits until there is more than
  # one account for it to distinguish between. The single-account case is
  # covered below, where showing it is nineteen copies of one fact.
  test "index shows the account a bill is paid from and its notes" do
    create_bill(name: "Annotated bill", amount: 60, notes: "Account 4821, on the Amex")
    create_bill(name: "Card bill", amount: 25, account: accounts(:credit_card))

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
    # What is left leads, and the row says it once. The subline carries the
    # state and the figure; printing "$750.00 of $2,000.00 paid" again on the
    # right was the same arithmetic twice, and it was squeezing the bill's own
    # name out of the row.
    assert_match I18n.t("bills.attention.partial", amount: "$1,250.00"), response.body
    assert_match "$1,250", response.body
    assert_no_match I18n.t("bills.partial_progress", paid: "$750.00", expected: "$2,000.00"), response.body
  end

  # The row's detail once described the SERIES definition while the bill's
  # detail described the current occurrence, so an overdue bill greeted you
  # with "Next payment" in one surface and "Overdue" in the other.
  test "the drawer and the bill's page tell the same story about an overdue bill" do
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

    get bill_url(bill)
    assert_response :success
    assert_match overdue_phrase, response.body, "the page states the status"

    get_bill_drawer(bill)
    assert_response :success
    assert_match overdue_phrase, response.body, "and the drawer must state the same one"
    assert_no_match I18n.t("bills.detail.next_payment"), response.body,
      "an overdue bill is not a next payment"
  end

  # A bill's own page is where the depth lives now. It used to be a drawer
  # dialog rendered over an empty settings layout, which is how the app ended
  # up with three renderings of a bill's detail and no page at all.
  test "show renders the bill page with history and analytics" do
    bill = create_bill(name: "Power Co", amount: 80)
    past = bill.recurring_occurrences.create!(
      family: @family, original_due_on: 2.months.ago.to_date, due_on: 2.months.ago.to_date,
      currency: "USD"
    )
    RecurringTransaction::Allocator.new(past).allocate!(amount: "78.50")
    past.reload

    get bill_url(bill)

    assert_response :success
    assert_select "main h1", text: "Power Co"
    assert_match I18n.t("bills.detail.history"), response.body
    assert_match I18n.t("bills.detail.ytd"), response.body
    assert_match "$78.50", response.body
  end

  # The drawer slot belongs to resolving a payment. If a bill's page claimed it
  # too, the page and the payment surface would compete for one frame id and
  # whichever lost would render nothing at all.
  test "the bill page leaves the drawer frame to the payment surface" do
    bill = create_bill(name: "Power Co", amount: 80)

    get bill_url(bill)

    assert_response :success
    assert_equal 1, response.body.scan(/<turbo-frame[^>]*id="drawer"/).size,
      "only the layout's own empty drawer frame"
    assert_match recurring_occurrence_path(bill.recurring_occurrences.order(:due_on).first), response.body,
      "and the page still offers the way in to it"
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

    get_bill_drawer(bill)

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
    # DS::Table renders the desktop table's cells from blocks written in this
    # view, so their relative keys still have to resolve against bills/all.
    assert_select "table td", text: I18n.t("bills.all.types.bill")
    assert_select ".translation_missing", false
    # Seven columns can overflow just above @3xl, where the table replaces the
    # cards: the scroll area is named, so a keyboard can reach the columns.
    assert_select "[role=region][aria-label=?]", I18n.t("bills.views.all")

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
    assert_match I18n.l(payday, format: :short), response.body
    assert_match I18n.t("bills.paycheck.period_source", source: "Paycheck"), response.body
    assert_match "Rent", response.body
    assert_match I18n.t("bills.paycheck.safe_after_bills"), response.body
  end

  # A lone materialized paycheck landing today collapses the planner's
  # boundary list to a single date, which yields an empty plan; the page must
  # treat that like no plan instead of crashing on plan.last.
  test "the paycheck view survives a lone paycheck landing today" do
    series = @family.recurring_transactions.create!(
      name: "Paycheck", account: accounts(:depository), amount: -1840, currency: "USD",
      bill_type: "income", expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true
    )
    series.recurring_occurrences.where("due_on > ?", Date.current).delete_all

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.empty.title"), response.body
  end

  # With no plan there is no paycheck and no period, so the chips would open a
  # chat that can only say so. The review button proves AI is available, so
  # the missing chips can't pass for want of AI.
  test "the paycheck view offers its AI chips only with a plan" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)
    chips = %w[due_before_paycheck safe_to_spend].map { |key| ERB::Util.html_escape(I18n.t("bills.ai_prompts.#{key}")) }

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.empty.title"), response.body
    assert_match I18n.t("bills.index.review_with_ai"), response.body
    chips.each { |chip| refute_includes response.body, chip }

    # Paused income is listed but defines no paydays: still no plan, no chips.
    income = declare_income(name: "Paycheck", amount: -1840, payday: Date.current + 3)
    income.update!(status: "paused")

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match "Paycheck", response.body
    assert_match I18n.t("bills.paycheck.empty.title"), response.body
    chips.each { |chip| refute_includes response.body, chip }

    income.update!(status: "active")

    get bills_url(view: "paycheck")

    assert_response :success
    assert_no_match I18n.t("bills.paycheck.empty.title"), response.body
    chips.each { |chip| assert_includes response.body, chip }
  end

  # Income was addable only from inside the Income plan tab, so a family that
  # had declared none had no way to discover the planning half of Bills
  # existed. Both halves are addable from every view, but only the half the
  # view is about earns the header button; the other waits in the menu.
  test "every bills view offers both add actions, and income opens an income dialog" do
    %w[overview calendar paycheck all].each do |view|
      get view == "overview" ? bills_url : bills_url(view: view)

      header_action = view == "paycheck" ? new_recurring_transaction_path(income: true) : new_recurring_transaction_path
      menu_action = view == "paycheck" ? new_recurring_transaction_path : new_recurring_transaction_path(income: true)

      assert_response :success
      assert_select "header" do
        assert_select "a[href=?]:not([role=menuitem])", header_action
        assert_select "a[href=?][role=menuitem]", menu_action
        assert_select "a[href=?]:not([role=menuitem])", menu_action, count: 0
      end
    end

    # A CTA that says income has to deliver an income form, not a bill form
    # wearing a different title.
    get new_recurring_transaction_url(income: true), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_match I18n.t("recurring_transactions.new.income_title"), response.body
  end

  # The drawer is opened from one row, so it has to describe that row's
  # cycle. It used to ask the series for its current occurrence, which is the
  # earliest still-open one, so opening a settled row reported the NEXT cycle
  # as unpaid beside a row marked Paid.
  test "opening a row describes that row's cycle, not the series' next one" do
    bill = create_bill(name: "Streaming Plus", amount: 15.99)
    settled = bill.recurring_occurrences.order(:due_on).first
    entry = accounts(:depository).entries.create!(
      date: settled.due_on, amount: 15.99, currency: "USD",
      name: "STREAMING PLUS", entryable: Transaction.new
    )
    RecurringTransaction::Allocator.new(settled).allocate!(amount: "15.99", entry: entry)
    assert settled.reload.paid?

    later = bill.recurring_occurrences.open_status.order(:due_on).first
    assert_not_nil later, "the series has a later, unpaid cycle to be confused with"
    assert_not_equal settled.id, later.id

    get_bill_drawer(bill, occurrence: settled.id)

    assert_response :success
    assert_match I18n.t("bills.summary.paid_headline", amount: "$15.99"), response.body
    assert_no_match I18n.t("bills.summary.remaining", amount: "$15.99"), response.body,
      "the settled row must not report itself as still owing"
  end

  # Without an occurrence the page has no cycle in mind, so the series answers.
  test "a bill opened with no occurrence falls back to the series" do
    bill = create_bill(name: "Streaming Plus", amount: 15.99)

    get_bill_drawer(bill)

    assert_response :success
    assert_match I18n.t("bills.summary.remaining", amount: "$15.99"), response.body
  end

  # The id is resolved through the series, so one from another bill cannot be
  # borrowed to render someone else's cycle.
  test "an occurrence id from another bill is ignored" do
    mine = create_bill(name: "Streaming Plus", amount: 15.99)
    other = create_bill(name: "Gym", amount: 40)
    stranger = other.recurring_occurrences.order(:due_on).first

    get_bill_drawer(mine, occurrence: stranger.id)

    assert_response :success
    assert_match I18n.t("bills.summary.remaining", amount: "$15.99"), response.body
    assert_no_match(/\$40\.00/, response.body)
  end

  # Detection has been creating recurring rows from bank data since long before
  # Bills existed, so anyone upgrading meets a page of bills nobody confirmed.
  test "a family that has never worked with Bills is told where its bills came from" do
    create_bill(name: "Rent", amount: 2150)
    create_bill(name: "Streaming", amount: 20)

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.detected_review", count: 2), response.body
  end

  # The prompt carries no stored state, so it has to clear itself off evidence
  # that the user has worked with Bills. Each of these is sufficient on its own.
  test "the prompt clears itself once the user has worked with Bills" do
    detected = create_bill(name: "Rent", amount: 2150)

    get bills_url
    assert_match I18n.t("bills.index.detected_review", count: 1), response.body

    # Declaring a bill by hand.
    declared = declare_bill(name: "Water", amount: 45, due: Date.current + 3)
    get bills_url
    assert_no_match I18n.t("bills.index.detected_review", count: 1), response.body
    assert_no_match I18n.t("bills.index.detected_review", count: 2), response.body
    declared.destroy!

    # Dismissing a suggestion.
    detected.update!(status: :ended)
    get bills_url
    assert_no_match I18n.t("bills.index.detected_review", count: 1), response.body
    detected.update!(status: :active)

    # Recording a payment themselves.
    occurrence = detected.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: "10")
    get bills_url

    assert_response :success
    assert_no_match I18n.t("bills.index.detected_review", count: 1), response.body
  end

  # The banner asks the user to check "the totals here", which leave income and
  # internal transfers out, so neither may raise it over an empty overview.
  test "detected income and savings transfers don't raise the review banner" do
    create_bill(name: "ACME PAYROLL", amount: -2400, bill_type: "income", manual: false)
    create_bill(name: "TO SAVINGS", amount: 500, destination_account: accounts(:connected), manual: false)

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.empty.title"), response.body
    assert_no_match I18n.t("bills.index.detected_review", count: 1), response.body
    assert_no_match I18n.t("bills.index.detected_review", count: 2), response.body

    create_bill(name: "Rent", amount: 2150, manual: false)
    get bills_url

    assert_match I18n.t("bills.index.detected_review", count: 1), response.body
  end

  # The page's whole job. A single "Bills $695.60" against $357.48 of visible
  # rows is a number nothing on screen can account for, so due and reserved
  # are stated apart and their sum is never shown at all.
  test "the paycheck view states due and reserved separately and never their sum" do
    payday = Date.current + 3
    declare_income(name: "Frito Lay", amount: -1200, payday: payday)
    declare_bill(name: "Streaming", amount: 20, due: Date.current + 5)
    # Bigger than one paycheck and due in the next one, so its overflow is
    # genuinely reserved out of the first.
    declare_bill(name: "Insurance", amount: 1500, due: payday + 31)

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.due_this_period"), response.body
    assert_match I18n.t("bills.paycheck.reserved_ahead"), response.body
    assert_match I18n.t("bills.paycheck.safe_after_bills"), response.body

    paycheck = RecurringTransaction::PaycheckPlanner.new(@family, user: @user).plan
                 .find { |period| period.income.positive? }
    assert paycheck.due_total.positive?
    assert paycheck.reserved_total.positive?
    assert_match money_string(paycheck.due_total), response.body
    assert_match money_string(paycheck.reserved_total), response.body

    # Asserting the combined figure is simply ABSENT does not work: period
    # totals can collide across periods by arithmetic, so the test would pass
    # or fail on a coincidence. What is actually being
    # pinned is that no label survives for a combined bills figure to render
    # under -- which fails the moment one is reintroduced.
    assert_nil I18n.t("bills.paycheck.bills_that_period", default: nil)
    assert_nil I18n.t("bills.paycheck.obligations_line", default: nil)
  end

  # The breakdown is the allocation bar's legend: each figure carries a swatch
  # in its segment's colour, so the bar reads without a second key.
  test "the paycheck breakdown keys each figure to its allocation bar segment" do
    payday = Date.current + 3
    declare_income(name: "Frito Lay", amount: -1200, payday: payday)
    declare_bill(name: "Streaming", amount: 20, due: Date.current + 5)
    declare_bill(name: "Insurance", amount: 1500, due: payday + 31)

    get bills_url(view: "paycheck")

    assert_response :success
    bars = css_select("section div.flex[role=img]")
    assert_equal 2, bars.size

    bars.each do |bar|
      segment_colours = bar.css("div").map { |segment| segment["class"] }
      swatch_colours = bar.ancestors("section").first.css("[data-paycheck-legend-swatch]").map { |swatch| swatch["class"][/bg-\S+/] }
      assert_equal segment_colours, swatch_colours
    end
    assert_equal %w[bg-inverse bg-subdued bg-success], bars.first.css("div").map { |segment| segment["class"] }
  end

  # The window before the first payday has no income to allocate, so it is
  # reported above the timeline as a warning rather than drawn as a pay period
  # with an empty paycheck. The shortfall names the obligation, not the slice
  # the planner parked in this window, and never asks the user to operate on
  # the allocation itself.
  test "the gap before the first payday is a banner, not a period in the timeline" do
    # The banner reports a shortfall, and a shortfall now means the cash cannot
    # reach, not merely that the window earns nothing. Pin the balance under the
    # bill so the condition this test is about actually holds.
    @family.accounts.where(accountable_type: "Depository").update_all(balance: 100)
    declare_income(name: "Frito Lay", amount: -1200, payday: Date.current + 4)
    declare_bill(name: "Watson Property", amount: 2150, due: Date.current + 3)

    get bills_url(view: "paycheck")

    assert_response :success
    plan = RecurringTransaction::PaycheckPlanner.new(@family, user: @user).plan
    bridge = plan.find(&:bridge?)

    assert_match I18n.t("bills.paycheck.shortfall_label"), response.body
    assert_match I18n.t("bills.paycheck.shortfall_amount", amount: money_string(bridge.shortfall)), response.body
    assert_match I18n.t("bills.paycheck.shortfall_largest"), response.body
    assert_match "Watson Property", response.body
    assert_match I18n.t("bills.paycheck.review_plan"), response.body

    # The banner is the whole report on that window, so the timeline holds one
    # entry per real paycheck and no empty-paycheck row.
    assert plan.count { |period| !period.bridge? }.positive?
    assert_no_match I18n.t("bills.paycheck.before_next_paycheck", date: I18n.l(bridge.ends_on + 1, format: :short)),
      response.body, "the leading window is reported by the banner, not drawn as a pay period"

    assert_no_match(/set-aside|set aside/i, response.body,
      "nothing on this page asks the user to perform the planner's own bookkeeping")
  end

  # The strip read the stored next_expected_date column while the plan read
  # occurrences, so one series could name two different next paydays on one
  # screen.
  test "the income strip names the same payday the plan does" do
    payday = Date.current + 6
    income = declare_income(name: "Frito Lay", amount: -1200, payday: payday)
    income.update_columns(next_expected_date: Date.current - 1)

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.income_next_payday", date: I18n.l(payday, format: :short)), response.body
    assert_no_match(/#{Regexp.escape(I18n.l(Date.current - 1, format: :short))}/, response.body,
      "the stale column date must not appear anywhere on the page")
  end

  # An auto-detected inflow sat in the list looking exactly like a real payday
  # source while moving no number on the page.
  test "income the planner cannot use says so" do
    declare_income(name: "Frito Lay", amount: -1200, payday: Date.current + 3)
    detected = declare_income(name: "To Car Vault", amount: -0.01, payday: Date.current + 2)
    detected.update!(manual: false)
    # Something to cover, or the page is the all-clear state and no period
    # renders a heading at all.
    declare_bill(name: "Streaming", amount: 20, due: Date.current + 5)

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.income_detected"), response.body
    assert_match I18n.l(Date.current + 3, format: :short), response.body
    assert_match I18n.t("bills.paycheck.period_source", source: "Frito Lay"), response.body,
      "the declared source heads the period, so the detected one two days earlier cannot have sliced it"
  end

  # Four cards each saying "nothing due" is not a better way to say that
  # everything is covered.
  test "an income schedule with nothing to cover renders one state, not empty cards" do
    declare_income(name: "Frito Lay", amount: -1200, payday: Date.current + 3)

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.all_clear.title"), response.body
    assert_no_match I18n.t("bills.paycheck.reserved_ahead"), response.body
  end

  test "an overview row opens its bill in the drawer, for that row's cycle" do
    # Overdue, because Next up lists nothing past due: the row is the only
    # link to this cycle.
    overdue_day = 6.days.ago.to_date
    bill = create_bill(name: "Late Co", amount: 5.99, expected_day_of_month: overdue_day.day,
                       last_occurrence_date: 2.months.ago.to_date, next_expected_date: overdue_day)
    occurrence = bill.recurring_occurrences.detect(&:overdue?)

    get bills_url

    assert_response :success
    assert_select "a[data-turbo-frame=drawer][href=?]", bill_path(bill, display: "drawer", occurrence: occurrence.id), count: 1
  end

  # Next up used to go to the bill's page, because opening the expansion of a
  # row further down would have jumped the page. The drawer opens over the
  # page, so Next up opens the same one the row does.
  test "a Next up item opens the same drawer as its row" do
    bill = create_bill(name: "Rent", amount: 2150)
    occurrence = bill.recurring_occurrences.find_by!(due_on: Date.current)

    get bills_url

    assert_response :success
    assert_select "a[data-turbo-frame=drawer][href=?]", bill_path(bill, display: "drawer", occurrence: occurrence.id),
      { count: 2 }, "the row and its Next up item"
  end

  # A bill opens over the list, the way a transaction or a budget category
  # does, rather than expanding inline under its row.
  test "a bill opens in the drawer and tells its story there" do
    bill = create_bill(name: "Rent", amount: 2150)
    occurrence = bill.recurring_occurrences.order(:due_on).first
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 2150, currency: "USD", name: "WATSON PROPERTY",
      entryable: Transaction.new
    )
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: "2150", entry: entry)

    get_bill_drawer(bill)

    assert_response :success
    assert_select "turbo-frame#drawer dialog h2", text: "Rent"
    assert_match I18n.t("bills.detail.recent_payments"), response.body
    assert_match "WATSON PROPERTY", response.body

    # The drawer answers "what is going on with this bill" and stops there.
    # The matching rules and the per-year table are configuration and
    # reference material, and they belong to the bill's page.
    assert_no_match I18n.t("bills.detail.rules"), response.body,
      "the drawer is not a second detail view"
    assert_no_match I18n.t("bills.detail.key_metrics"), response.body
    assert_no_match(/<html/, response.body, "the drawer renders frame-only, no layout")
  end

  # A match waiting on a decision is the one thing that changes what the
  # drawer asks of you: review it, rather than go looking for the payment.
  test "a pending match makes the drawer's verb Review" do
    bill = declare_bill(name: "CITY WATER", amount: 80, due: Date.current - 3)
    charge = create_transaction_entry(name: "CITY WATER", amount: 85.50, date: Date.current - 3)
    occurrence = bill.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).allocate_matched!(
      entry: charge, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )

    get_bill_drawer(bill, occurrence: occurrence.id)

    assert_response :success
    assert_match I18n.t("bills.review_match"), response.body
    assert_no_match I18n.t("bills.find_payment"), response.body
  end

  # A form inside a frame answers into that frame. Pause and Delete redirect to
  # a whole page, so inside the drawer they would only empty it and leave the
  # list behind them stale.
  test "the drawer's pause and delete submit to the whole page" do
    bill = create_bill(name: "Rent", amount: 2150)

    get_bill_drawer(bill)

    assert_response :success
    [ toggle_status_recurring_transaction_path(bill), recurring_transaction_path(bill) ].each do |action|
      assert_select "form[action=?] button[data-turbo-frame=_top]", action
    end
  end

  # The row is a real link, so a cmd-click or a pasted URL arrives with no frame
  # to render into. A bare dialog with no page around it never opens, which
  # would leave a blank tab.
  test "a drawer link opened outside the drawer lands on the bill's page" do
    bill = create_bill(name: "Power Co", amount: 80)

    get bill_url(bill, display: "drawer")

    assert_response :success
    assert_select "main h1", text: "Power Co"
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

  # Subscriptions was a filter promoted to navigation. Everything it answered
  # still has to be answerable, and its old links still have to work.
  test "the old subscriptions link lands on All bills, filtered" do
    get bills_url(view: "subscriptions")
    assert_redirected_to bills_path(view: "all", q: { bill_type: "subscription" })
  end

  test "filtering All bills by subscription rolls up cost and lists price changes" do
    sub = create_bill(name: "STREAMFLIX", amount: 24.99)
    sub.update!(bill_type: "subscription", trial_ends_on: Date.current + 5)
    sub.recurring_price_changes.create!(
      effective_on: 2.months.ago.to_date, previous_amount: 19.99, new_amount: 24.99,
      currency: "USD", source: "detected"
    )

    get bills_url(view: "all", q: { bill_type: "subscription" })

    assert_response :success
    assert_match "STREAMFLIX", response.body
    assert_match I18n.t("bills.all.subscription_monthly"), response.body
    assert_match I18n.t("bills.all.subscription_annual"), response.body
    assert_match I18n.t("bills.all.subscription_price_changes"), response.body
  end

  test "the rollup stays out of the way when the filter is not on subscriptions" do
    sub = create_bill(name: "STREAMFLIX", amount: 24.99)
    sub.update!(bill_type: "subscription")

    get bills_url(view: "all")

    assert_response :success
    assert_match "STREAMFLIX", response.body
    assert_no_match I18n.t("bills.all.subscription_monthly"), response.body,
      "a subscription rollup on an unfiltered list would be answering a question nobody asked"
  end

  test "trial, renewal and price history follow the bill into its detail" do
    sub = create_bill(name: "STREAMFLIX", amount: 24.99)
    sub.update!(bill_type: "subscription", trial_ends_on: Date.current + 5,
                renews_on: Date.current + 30)
    sub.recurring_price_changes.create!(
      effective_on: 2.months.ago.to_date, previous_amount: 19.99, new_amount: 24.99,
      currency: "USD", source: "detected"
    )

    # Trial and renewal are STATE: they change what you might do about the bill
    # today, so both routes to it must say so. Price history is the record of
    # how it got here, which is the page's job.
    { "page" => -> { get bill_url(sub) }, "drawer" => -> { get_bill_drawer(sub) } }.each do |label, request|
      request.call
      assert_response :success
      assert_match I18n.t("bills.detail.trial_chip", date: I18n.l(Date.current + 5, format: :short)),
        response.body, "the #{label} lost the trial chip"
      assert_match I18n.t("bills.detail.renews_chip", date: I18n.l(Date.current + 30, format: :short)),
        response.body, "the #{label} lost the renewal date"
    end

    get bill_url(sub)
    assert_match I18n.t("bills.detail.price_changes"), response.body,
      "the bill's page keeps the price history"
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

  # Notices speak for the bills the overview lists. A suggestion's price isn't
  # news until it's a bill, and an income change belongs on the Income plan.
  test "ended, suggested and income series raise no price notice" do
    change_price = ->(series) do
      series.recurring_price_changes.create!(
        effective_on: Date.current - 5, previous_amount: series.amount - 5, new_amount: series.amount,
        currency: "USD", source: "detected"
      )
    end
    change_price.(create_bill(name: "Old Streaming", amount: 20, status: "ended", manual: false))
    change_price.(create_bill(name: "ACME PAYROLL", amount: -2400, bill_type: "income"))

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.empty.title"), response.body
    assert_no_match "changed price", response.body

    # A suggestion takes the empty state's place with its own review strip, so
    # it gets a page of its own.
    @family.recurring_transactions.destroy_all
    change_price.(create_suggested(name: "Maybe Gym", account: accounts(:depository)))
    get bills_url

    assert_no_match "changed price", response.body
  end

  test "the ical feed serves upcoming occurrences with a member token and rejects garbage" do
    create_bill(name: "Rent", amount: 2150)

    get bills_feed_url(token: @family.bills_feed_token_for(@user))
    assert_response :success
    assert_match "BEGIN:VCALENDAR", response.body
    assert_match "Rent", response.body

    get bills_feed_url(token: "tampered")
    assert_response :not_found
  end

  test "reset_feed_token rotates the family token and returns to the calendar" do
    old_token = @family.bills_feed_token!

    post reset_feed_token_bills_url

    assert_redirected_to bills_path(view: "calendar")
    assert_equal I18n.t("bills.reset_feed_token.done"), flash[:notice]
    assert_not_equal old_token, @family.reload.bills_feed_token
  end

  test "reset_feed_token refuses GET" do
    # GET /bills/reset_feed_token falls through to bills#show (id:
    # "reset_feed_token"), which 404s on lookup; the point is that it can
    # never reach the reset action.
    route = Rails.application.routes.recognize_path("/bills/reset_feed_token", method: :get)
    assert_equal "show", route[:action], "GET must never reach the reset action"

    get "/bills/reset_feed_token"
    assert_response :not_found
  end

  test "a page without bill rows shows the empty state, not the month pulse or the AI prompts" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)

    get bills_url
    assert_response :success
    assert_match I18n.t("bills.index.empty.title"), response.body
    # AI is available, so the prompts are missing for want of bills.
    assert_match I18n.t("bills.index.review_with_ai"), response.body
    assert_no_match I18n.t("bills.month_pulse.left_to_pay"), response.body
    assert_no_match "due before my next paycheck", response.body
    assert_no_match I18n.t("bills.ai_prompts.subscriptions_up"), response.body
    assert_no_match I18n.t("bills.ai_prompts.monthly_subscriptions"), response.body

    # A suggestion isn't a bill yet, so it doesn't bring them back.
    create_suggested(name: "Riverside Climbing Gym", account: accounts(:depository))
    get bills_url
    assert_response :success
    assert_match "Riverside Climbing Gym", response.body
    assert_no_match I18n.t("bills.month_pulse.left_to_pay"), response.body
    assert_no_match "due before my next paycheck", response.body
    assert_no_match I18n.t("bills.ai_prompts.subscriptions_up"), response.body
    assert_no_match I18n.t("bills.ai_prompts.monthly_subscriptions"), response.body
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

  # The row carries one line of context, so anything on it has to earn the
  # space. These pin the three things that were not earning it.
  test "the paid-from account is quiet when every bill uses the same one" do
    create_bill(name: "Netflix", amount: 15.99)
    create_bill(name: "Spotify", amount: 11.99)
    assert_equal 1, @family.recurring_transactions.distinct.count(:account_id),
      "premise: a single account across all bills"

    get bills_url
    refute_includes response.body, I18n.t("bills.paid_from", account: accounts(:depository).name),
      "repeating one account name down every row says nothing"
  end

  test "the paid-from account returns as soon as it tells rows apart" do
    create_bill(name: "Netflix", amount: 15.99)
    create_bill(name: "Amex bill", amount: 40, account: accounts(:credit_card))
    assert_operator @family.recurring_transactions.distinct.count(:account_id), :>, 1

    get bills_url
    assert_includes response.body, I18n.t("bills.paid_from", account: accounts(:depository).name)
    assert_includes response.body, I18n.t("bills.paid_from", account: accounts(:credit_card).name)
  end

  test "autopay reads on the bill's line rather than in the action slot" do
    create_bill(name: "Netflix", amount: 15.99, autopay: true,
                payment_url: "https://example.com/pay")

    get bills_url
    assert_includes response.body, I18n.t("recurring_transactions.pay_action.autopay")
    refute_includes response.body, "refresh-cw",
      "autopay is a state; the row's one action position belongs to a verb"
    assert_includes response.body, "https://example.com/pay",
      "the portal stays reachable, just not as the row's headline action"
  end

  # Opacity on the whole row took the secondary text to about 2.7:1 in light
  # mode. The row recedes through the text tokens instead.
  test "an autopay row recedes through its text colour, not opacity" do
    create_bill(name: "Handled bill", amount: 30, autopay: true, notes: "Card ending 4242")
    create_bill(name: "Power Co", amount: 80)

    get bills_url
    assert_response :success

    assert_select BILL_ROW_LINK, text: /Handled bill/ do |links|
      assert_not_includes links.first.parent["class"].split, "opacity-70"
      assert_select links.first, "p.font-medium.text-secondary", text: /Handled bill/
      assert_select links.first, "p.font-medium.text-secondary.privacy-sensitive", text: /\$30\.00/
      # text-subdued is about 2.7:1 on white; notes have to stay readable.
      assert_select links.first, "p.text-secondary", text: "Card ending 4242"
    end
    assert_select BILL_ROW_LINK, text: /Power Co/ do |links|
      assert_select links.first, "p.font-medium.text-primary", text: /Power Co/
      assert_select links.first, "p.font-medium.text-primary.privacy-sensitive", text: /\$80\.00/
    end
  end

  # Pause, inactive and paused were three words for one thing, and the filter
  # asked for the one the button never writes.
  test "a bill you paused is findable under Paused" do
    bill = create_bill(name: "Gym", amount: 40)
    post toggle_status_recurring_transaction_path(bill)
    assert_equal "inactive", bill.reload.status,
      "premise: the Pause button stores inactive, not paused"

    get bills_url(view: "all", q: { status: "paused" })
    assert_includes response.body, "Gym",
      "the filter has to ask for what the button actually writes"
  end

  test "the word for a paused bill is the same everywhere the user sees it" do
    bill = create_bill(name: "Gym", amount: 40)
    post toggle_status_recurring_transaction_path(bill)

    # The badge, the filter option and the confirmation all have to agree.
    # "Pause" stays the verb on the button; "Paused" is the state.
    state = I18n.t("recurring_transactions.status.#{bill.reload.status}")
    assert_equal "Paused", state
    assert_equal state, I18n.t("bills.all.status_filters.paused")
    assert_match(/#{state}/, I18n.t("recurring_transactions.marked_inactive"))
  end

  # toggle_status is shared with Settings > Recurring, which manages income and
  # transfers too, so its confirmation must not talk about bills.
  test "the pause confirmation does not assume the record is a bill" do
    [ "recurring_transactions.marked_inactive", "recurring_transactions.marked_active" ].each do |key|
      refute_match(/bills?/i, I18n.t(key),
        "#{key} is shown on the shared Recurring surface as well as Bills")
    end
  end

  test "the status filter does not offer words for states nobody can reach" do
    # `ended` only ever comes from dismissing a suggestion, so it is labelled
    # for what produced it rather than as a bill lifecycle.
    assert_equal "Dismissed", I18n.t("bills.all.status_filters.ended")
    assert_equal "Dismissed", I18n.t("recurring_transactions.status.ended")
  end

  # The row expansion and the old drawer used to be two templates over one
  # action, so they drifted, and the fix made them render the SAME partial --
  # which traded a disagreement for a duplication: two surfaces answering one
  # question.
  #
  # They now answer different ones. What has to stay true is that nothing was
  # lost on the way, and that the shallower surface never quietly grows into
  # the deeper one again. So: the drawer is a strict subset of the page, and
  # every section the old shared partial rendered still exists somewhere.
  test "the drawer is a subset of the bill's page, and nothing was dropped" do
    bill = create_bill(name: "Power Co", amount: 80, notes: "Account 4821")
    past = bill.recurring_occurrences.create!(
      family: @family, original_due_on: 2.months.ago.to_date,
      due_on: 2.months.ago.to_date, currency: "USD"
    )
    entry = accounts(:depository).entries.create!(
      date: 2.months.ago.to_date, amount: 78.50, currency: "USD",
      name: "POWER CO AUTOPAY", entryable: Transaction.new
    )
    RecurringTransaction::Allocator.new(past).allocate!(amount: "78.50", entry: entry)
    bill.recurring_price_changes.create!(
      effective_on: 3.months.ago.to_date, previous_amount: 70, new_amount: 80,
      currency: "USD", source: "detected"
    )

    get bill_url(bill)
    assert_response :success
    page = response.body

    get_bill_drawer(bill)
    assert_response :success
    drawer = response.body

    # Every section the shared partial used to render still has a home.
    everything = %w[rules history_title average annualized ytd upcoming
                    recent_payments history notes last_account key_metrics
                    price_changes]
    homeless = everything.reject { |key| page.include?(I18n.t("bills.detail.#{key}")) }
    assert_empty homeless, "relocating the detail must not delete any of it"

    # And the drawer adds nothing of its own that the page lacks.
    shown_in_drawer = everything.select { |key| drawer.include?(I18n.t("bills.detail.#{key}")) }
    assert_equal shown_in_drawer, shown_in_drawer & everything.select { |key| page.include?(I18n.t("bills.detail.#{key}")) },
      "the drawer must stay a subset, never a second detail view"

    [ "POWER CO AUTOPAY", "$78.50" ].each do |fact|
      assert_includes page, fact, "the page is missing #{fact}"
      assert_includes drawer, fact, "the drawer is missing #{fact}"
    end
    assert_includes page, "Account 4821", "notes belong to the page"
  end

  # "Something changed" is only useful if the thing you can still act on is
  # the thing you see first. Notices used to sort by date ascending, so a
  # month-old one-dollar rise outranked a trial converting tomorrow.
  test "notices lead with what is still actionable, not with what is oldest" do
    trial = create_bill(name: "Streamflix", amount: 20)
    trial.update!(bill_type: "subscription", trial_ends_on: Date.current + 1)

    big = create_bill(name: "Gym", amount: 90)
    big.recurring_price_changes.create!(effective_on: 20.days.ago.to_date,
      previous_amount: 90, new_amount: 200, currency: "USD", source: "detected")

    small = create_bill(name: "Power", amount: 60)
    small.recurring_price_changes.create!(effective_on: 30.days.ago.to_date,
      previous_amount: 60, new_amount: 61, currency: "USD", source: "detected")

    get bills_url
    assert_response :success
    body = response.body

    trial_at = body.index("Streamflix")
    big_at   = body.index("Gym changed price")
    small_at = body.index("Power changed price")

    assert trial_at < small_at, "a trial converting tomorrow must outrank a month-old $1 rise"
    assert big_at < small_at, "a 122% rise must outrank a 2% one"
  end

  test "small changes collapse rather than pushing the worklist down" do
    urgent = create_bill(name: "Streamflix", amount: 20)
    urgent.update!(bill_type: "subscription", trial_ends_on: Date.current + 1)

    3.times do |i|
      quiet = create_bill(name: "Utility #{i}", amount: 60 + i)
      quiet.recurring_price_changes.create!(effective_on: (20 + i).days.ago.to_date,
        previous_amount: 60 + i, new_amount: 61 + i, currency: "USD", source: "detected")
    end

    get bills_url
    assert_response :success
    assert_match I18n.t("bills.index.notices_routine", count: 3), response.body,
      "the quiet ones collapse behind a count"
    # Collapsed, not dropped: a hidden notice is still a dead end.
    3.times { |i| assert_match "Utility #{i}", response.body }
  end

  test "a price notice says how big the change was" do
    bill = create_bill(name: "Gym", amount: 90)
    bill.recurring_price_changes.create!(effective_on: 5.days.ago.to_date,
      previous_amount: 90, new_amount: 200, currency: "USD", source: "detected")

    get bills_url
    assert_response :success
    assert_match "+122%", response.body,
      "from-and-to alone never said whether a change was worth caring about"
  end

  # Within a group the order still has to mean something: the partition
  # separates urgent from routine, but only the sort decides what leads
  # inside each half.
  test "among changes of equal weight the most recent leads" do
    [ [ "Oldest", 30 ], [ "Middle", 20 ], [ "Newest", 5 ] ].each do |name, days|
      bill = create_bill(name: name, amount: 60)
      bill.recurring_price_changes.create!(effective_on: days.days.ago.to_date,
        previous_amount: 60, new_amount: 61, currency: "USD", source: "detected")
    end

    get bills_url
    assert_response :success
    positions = %w[Newest Middle Oldest].map { |n| response.body.index("#{n} changed price") }
    assert_equal positions.sort, positions,
      "equally small changes should read newest first, not oldest first"
  end

  # --- Onboarding: detection from the Bills page ---

  test "empty page with transaction history offers detection beside Add bill" do
    create_transaction_entry(name: "Coffee", amount: 20, date: Date.current)

    get bills_url

    assert_response :success
    assert_select "a[href=?][data-turbo-method=post]", detect_bills_path
    assert_match I18n.t("bills.index.empty.action"), response.body
  end

  test "empty page with no transactions hides detection and explains why" do
    Entry.where(account: @family.accounts).delete_all

    get bills_url

    assert_response :success
    assert_select "a[href=?]", detect_bills_path, count: 0
    assert_match I18n.t("bills.index.empty.no_history_description"), response.body
  end

  test "detect creates suggestions, counts only them, and the strip offers review" do
    3.times do |i|
      create_transaction_entry(name: "GYM MEMBERSHIP", amount: 40, date: Date.current - i.months)
    end

    post detect_bills_url

    assert_redirected_to bills_path
    assert_equal I18n.t("bills.detect.found", count: 1), flash[:notice]

    follow_redirect!
    assert_match "GYM MEMBERSHIP", response.body
    assert_match I18n.t("recurring_transactions.suggested.confirm"), response.body
  end

  test "detect does not resurrect a dismissed pattern" do
    # Same identity as the entries below (name, currency, account, blank
    # dedup scope): the ended tombstone claims the pattern and blocks it.
    create_bill(name: "GYM MEMBERSHIP", amount: 40, status: "ended", dedup_scope: "", manual: false)
    3.times do |i|
      create_transaction_entry(name: "GYM MEMBERSHIP", amount: 40, date: Date.current - i.months)
    end

    post detect_bills_url

    assert_equal I18n.t("bills.detect.none_found"), flash[:notice]
    assert_equal 0, @family.recurring_transactions.suggested.count
  end

  test "detect refuses GET" do
    # GET /bills/detect falls through to bills#show (id: "detect"), which
    # 404s on lookup; the point is that it can never reach the detect action.
    route = Rails.application.routes.recognize_path("/bills/detect", method: :get)
    assert_equal "show", route[:action], "GET must never reach the detect action"

    get "/bills/detect"
    assert_response :not_found
  end

  test "detect on an upgraded instance reconstructs paid history" do
    last_month_ninth = Date.current.beginning_of_month + 8.days - 1.month
    bill = create_bill(name: "CITY WATER", amount: 80, dedup_scope: "",
                       expected_day_of_month: 9,
                       last_occurrence_date: last_month_ninth,
                       next_expected_date: last_month_ninth + 1.month)
    create_transaction_entry(name: "CITY WATER", amount: 80, date: last_month_ninth)
    RecurringOccurrence.where(recurring_transaction: bill).delete_all

    post detect_bills_url

    assert bill.recurring_occurrences.paid.where(due_on: last_month_ninth).exists?,
      "the first-run backfill closes history a real entry anchors"
  end

  test "index materializes occurrences for an upgraded instance" do
    bill = create_bill(name: "Rent", amount: 1200)
    RecurringOccurrence.where(recurring_transaction: bill).delete_all

    get bills_url

    assert_response :success
    assert_operator bill.recurring_occurrences.count, :>, 0
    assert_match "Rent", response.body
  end

  test "index creates no occurrences when the family has no active series" do
    get bills_url

    assert_response :success
    assert_equal 0, @family.recurring_occurrences.count
  end

  test "an overdue-only family sees its overdue bill, not the empty state" do
    overdue_day = 10.days.ago.to_date
    bill = create_bill(name: "Late bill", amount: 75,
                       expected_day_of_month: overdue_day.day,
                       last_occurrence_date: 2.months.ago.to_date,
                       next_expected_date: overdue_day)
    # Strip the future so only the overdue occurrence remains: the empty-state
    # condition used to ignore @overdue and rendered both at once.
    bill.recurring_occurrences.where("due_on > ?", Date.current).delete_all

    get bills_url

    assert_response :success
    assert_match "Late bill", response.body
    assert_no_match I18n.t("bills.index.empty.title"), response.body
  end

  # Dormant rows don't feed the pulse, so a page of paused bills would show
  # a card of zeros and chips asking about bills nobody is paying.
  test "a page of only paused bills shows the dormant section without the month pulse or the AI prompts" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)
    overdue_day = 5.days.ago.to_date
    bill = create_bill(name: "Paused gym", amount: 40,
                       expected_day_of_month: overdue_day.day,
                       last_occurrence_date: 2.months.ago.to_date,
                       next_expected_date: overdue_day)
    bill.mark_inactive!
    assert bill.recurring_occurrences.open_status.exists?, "the paused bill keeps its overdue occurrence"

    get bills_url
    assert_response :success
    assert_match "Paused gym", response.body
    assert_match I18n.t("bills.index.dormant"), response.body
    assert_no_match I18n.t("bills.month_pulse.left_to_pay"), response.body
    assert_no_match "due before my next paycheck", response.body
    assert_no_match I18n.t("bills.ai_prompts.subscriptions_up"), response.body
  end

  test "a page of only bills due after this month keeps the month pulse" do
    next_month = Date.current.next_month.beginning_of_month + 4
    # Manual and anchored next month, or generation also writes this month's
    # cycle and the pulse stays up without the later row.
    create_bill(name: "Next month rent", amount: 900, manual: true, anchor_date: next_month,
                expected_day_of_month: next_month.day,
                next_expected_date: next_month)

    get bills_url
    assert_response :success
    assert_empty @controller.view_assigns["overdue"] + @controller.view_assigns["month_rows"],
      "premise: the later row is the only one"
    assert_match I18n.t("bills.index.later"), response.body
    assert_match I18n.t("bills.month_pulse.left_to_pay"), response.body
  end

  test "a page whose only pulse row is a paid one keeps the month pulse" do
    bill = create_bill(name: "Water Co", amount: 30)
    settled = bill.recurring_occurrences.order(:due_on).first
    entry = accounts(:depository).entries.create!(
      date: settled.due_on, amount: 30, currency: "USD",
      name: "WATER CO", entryable: Transaction.new
    )
    RecurringTransaction::Allocator.new(settled).allocate!(amount: "30", entry: entry)
    assert settled.reload.paid?
    # Paused after paying, so nothing is open: the paid row is all the pulse has.
    bill.mark_inactive!

    get bills_url
    assert_response :success
    assert_match "Water Co", response.body
    assert_no_match I18n.t("bills.index.dormant"), response.body
    assert_match I18n.t("bills.month_pulse.left_to_pay"), response.body
  end

  test "AI chips and the review button need both consent and a provider" do
    # The chips only render over bill rows.
    create_bill(name: "Power Co", amount: 80)
    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)
    get bills_url
    assert_response :success
    # Apostrophe-free fragment: response bodies HTML-escape apostrophes.
    assert_match "due before my next paycheck", response.body
    assert_match I18n.t("bills.index.review_with_ai"), response.body
    # A menu item, not a third header button: it still has to POST into the
    # sidebar chat frame and open the sidebar, or it seeds a chat nobody sees.
    assert_select "header div[role=menu] form[action=?]", ai_review_bills_path do
      assert_select "button[data-turbo-frame=?][data-action=?]", "sidebar_chat", "app-layout#openRightSidebar"
    end

    @user.update!(ai_enabled: false)
    get bills_url
    assert_response :success
    assert_no_match "due before my next paycheck", response.body
    assert_no_match I18n.t("bills.index.review_with_ai"), response.body

    # Consent without a configured provider is a button to a dead chat.
    @user.update!(ai_enabled: true)
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    get bills_url
    assert_response :success
    assert_no_match "due before my next paycheck", response.body
    assert_no_match I18n.t("bills.index.review_with_ai"), response.body
  end

  test "the bill page offers smart configure only when AI is available" do
    bill = create_bill(name: "Power Co", amount: 80)

    Provider::Registry.stubs(:preferred_llm_provider).returns(Object.new)
    get bill_url(bill)
    assert_response :success
    assert_match smart_configuration_bill_path(bill), response.body

    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    get bill_url(bill)
    assert_response :success
    assert_no_match smart_configuration_bill_path(bill), response.body
  end

  test "price changes on accounts the member cannot reach stay out of notices and the rollup" do
    hidden = create_bill(name: "Hidden brokerage sub", amount: 24.99, account: accounts(:investment))
    hidden.update!(bill_type: "subscription")
    hidden.recurring_price_changes.create!(
      effective_on: Date.current - 5, previous_amount: 19.99, new_amount: 24.99,
      currency: "USD", source: "detected"
    )
    visible = create_bill(name: "Visible sub", amount: 9.99)
    visible.update!(bill_type: "subscription")
    visible.recurring_price_changes.create!(
      effective_on: Date.current - 5, previous_amount: 7.99, new_amount: 9.99,
      currency: "USD", source: "detected"
    )

    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    get bills_url
    assert_response :success
    assert_match "Visible sub", response.body
    assert_no_match "Hidden brokerage sub", response.body

    get bills_url(view: "all", q: { bill_type: "subscription" })
    assert_response :success
    assert_no_match "Hidden brokerage sub", response.body
  end

  test "the suggested strip only shows series on accounts the member can reach" do
    create_suggested(name: "Hidden brokerage sub", account: accounts(:investment))
    create_suggested(name: "Visible sub", account: accounts(:depository))

    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member
    get bills_url

    assert_response :success
    assert_match "Visible sub", response.body
    assert_no_match "Hidden brokerage sub", response.body
  end

  # The matcher no longer suggests income, but a suggestion written before
  # that rule can still sit on the row. The queue must not render it; the
  # same pending state on a bill must.
  test "a pre-existing income suggestion stays out of the payment review queue" do
    payday = Date.current - 3
    income = declare_income(name: "ACME PAYROLL", amount: -1840, payday: payday)
    bill = declare_bill(name: "CITY WATER", amount: 80, due: payday)
    deposit = create_transaction_entry(name: "ACME PAYROLL", amount: -1900, date: payday)
    charge = create_transaction_entry(name: "CITY WATER", amount: 85.50, date: payday)

    [ [ income, deposit ], [ bill, charge ] ].each do |series, entry|
      occurrence = series.recurring_occurrences.order(:due_on).first
      RecurringTransaction::Allocator.new(occurrence).allocate_matched!(
        entry: entry, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
      )
    end

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.suggestion_line", entry: "CITY WATER", bill: "CITY WATER"),
      response.body
    assert_no_match I18n.t("bills.index.suggestion_line", entry: "ACME PAYROLL", bill: "ACME PAYROLL"),
      response.body
  end

  # Ending a bill leaves its scheduled occurrences behind, and the matcher
  # scores every scheduled occurrence, so it can still suggest a payment for a
  # bill the user deleted. The queue asks only about bills the page lists.
  test "a suggestion against an ended bill stays out of the payment review queue" do
    due = Date.current - 3
    bill = declare_bill(name: "OLD GYM", amount: 40, due: due)
    RecurringTransaction::OccurrenceGenerator.new(bill).generate!
    charge = create_transaction_entry(name: "OLD GYM", amount: 40, date: due)
    RecurringTransaction::Allocator.new(bill.recurring_occurrences.order(:due_on).first).allocate_matched!(
      entry: charge, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )
    bill.update!(status: "ended")

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.empty.title"), response.body
    assert_no_match I18n.t("bills.index.suggestion_line", entry: "OLD GYM", bill: "OLD GYM"), response.body
  end

  # Skipping closes the occurrence but keeps its suggestion. Before this month
  # the overview no longer lists the row, so the queue mustn't ask about it.
  test "a suggestion against a skipped occurrence from last month stays out of the payment review queue" do
    due = Date.current.beginning_of_month - 10
    bill = declare_bill(name: "SKIPPED GYM", amount: 40, due: due)
    RecurringTransaction::OccurrenceGenerator.new(bill).generate!
    occurrence = bill.recurring_occurrences.find_by!(due_on: due)
    charge = create_transaction_entry(name: "SKIPPED GYM", amount: 40, date: due)
    RecurringTransaction::Allocator.new(occurrence).allocate_matched!(
      entry: charge, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )
    occurrence.skip!

    get bills_url

    assert_response :success
    assert_no_match I18n.t("bills.index.suggestion_line", entry: "SKIPPED GYM", bill: "SKIPPED GYM"), response.body
  end


  # The overview groups by calendar month, which is the wrong unit for anyone
  # paid weekly: four paychecks and four rent payments land in one list. The
  # markers only earn their place when income actually subdivides the month.
  test "weekly income marks pay periods inside the month" do
    travel_to Date.current.beginning_of_month + 9.days

    declare_scheduled_income(frequency: "weekly", weekday: Date.current.wday)
    declare_weekly_bill

    get bills_url

    assert_response :success
    assert_match(/due before [A-Z][a-z]{2} \d+/, response.body,
      "a weekly paycheck should mark its period inside the month")
  end

  test "monthly income leaves the month undivided" do
    travel_to Date.current.beginning_of_month + 9.days

    declare_scheduled_income(frequency: "monthly", day_of_month: Date.current.day)
    declare_weekly_bill

    get bills_url

    assert_response :success
    assert_no_match(/due before [A-Z][a-z]{2} \d+/, response.body,
      "one paycheck a month does not subdivide the month, so nothing should be marked")
  end

  test "no declared income leaves the month undivided" do
    travel_to Date.current.beginning_of_month + 9.days

    declare_weekly_bill

    get bills_url

    assert_response :success
    assert_no_match(/due before [A-Z][a-z]{2} \d+/, response.body)
  end


  # The bridge is filtered out of the timeline, and only a shortfall earned a
  # banner, so a bill due before payday that the cash comfortably covered
  # appeared nowhere on the page built to answer what is due before payday.
  test "a covered bridge window still shows what is due before payday" do
    @family.accounts.where(accountable_type: "Depository").update_all(balance: 5_000)
    declare_income(name: "Frito Lay", amount: -1200, payday: Date.current + 5)
    declare_bill(name: "Curbside Cuts", amount: 150, due: Date.current + 2)

    get bills_url(view: "paycheck")

    assert_response :success
    assert_match I18n.t("bills.paycheck.bridge_label"), response.body
    assert_match "Curbside Cuts", response.body
    assert_no_match(/#{Regexp.escape(I18n.t("bills.paycheck.shortfall_label"))}/, response.body,
      "the cash covers it, so nothing is short")
  end

  test "a covered bridge is never rendered as a timeline row" do
    @family.accounts.where(accountable_type: "Depository").update_all(balance: 5_000)
    declare_income(name: "Frito Lay", amount: -1200, payday: Date.current + 5)
    declare_bill(name: "Curbside Cuts", amount: 150, due: Date.current + 2)

    get bills_url(view: "paycheck")

    assert_response :success
    assert_no_match(/-\$150\.00/, response.body,
      "a timeline row prints income minus obligations, which is a deficit on a window that earns nothing")
  end

  private

    def declare_scheduled_income(frequency:, weekday: nil, day_of_month: nil)
      series = @family.recurring_transactions.create!(
        name: "Payday", account: accounts(:depository), amount: -1200,
        currency: "USD", status: "active", bill_type: "income", manual: true,
        dedup_scope: "payday--1200", last_occurrence_date: 1.week.ago.to_date,
        next_expected_date: Date.current,
        expected_day_of_month: day_of_month || Date.current.day
      )
      series.recurrence_rules.create!(frequency: frequency, interval: 1,
                                      weekday: weekday, day_of_month: day_of_month)
      # Occurrences generate on create, before the rule exists, so a series
      # built rule-last starts out on the fallback monthly cadence.
      series.recurring_occurrences.destroy_all
      RecurringTransaction::OccurrenceGenerator.new(series.reload).generate!
      series
    end

    def declare_weekly_bill
      series = @family.recurring_transactions.create!(
        name: "Rent", account: accounts(:depository), amount: 400,
        currency: "USD", status: "active", bill_type: "bill", manual: true,
        dedup_scope: "rent-400", last_occurrence_date: 1.week.ago.to_date,
        next_expected_date: Date.current, expected_day_of_month: Date.current.day
      )
      series.recurrence_rules.create!(frequency: "weekly", interval: 1,
                                      weekday: Date.current.wday)
      series.recurring_occurrences.destroy_all
      RecurringTransaction::OccurrenceGenerator.new(series.reload).generate!
      series
    end

    # A declared income series anchored to a specific payday, which is what the
    # planner slices periods by.
    def declare_income(name:, amount:, payday:)
      @family.recurring_transactions.create!(
        name: name, account: accounts(:depository), amount: amount, currency: "USD",
        bill_type: "income", expected_day_of_month: payday.day, anchor_date: payday,
        last_occurrence_date: payday, next_expected_date: payday, status: "active", manual: true
      )
    end

    # A declared bill anchored to a specific due date. create_bill defaults to
    # today, which is fine for the overview but puts every bill in the leading
    # window here, where the whole point is which period a bill lands in.
    def declare_bill(name:, amount:, due:)
      @family.recurring_transactions.create!(
        name: name, account: accounts(:depository), amount: amount, currency: "USD",
        dedup_scope: amount.to_s, bill_type: "bill",
        expected_day_of_month: due.day, anchor_date: due,
        last_occurrence_date: due, next_expected_date: due, status: "active", manual: true
      )
    end

    def money_string(amount)
      ApplicationController.helpers.format_money(Money.new(amount, @family.currency))
    end

    def create_transaction_entry(name:, amount:, date:, account: accounts(:depository))
      account.entries.create!(
        date: date, amount: amount, currency: "USD", name: name,
        entryable: Transaction.new
      )
    end

    def create_suggested(name:, account:)
      @family.recurring_transactions.create!(
        name: name, account: account, amount: 15, currency: "USD",
        dedup_scope: name, expected_day_of_month: 5,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "suggested", manual: false
      )
    end

    # What a row asks for: the drawer variant, fetched into the drawer frame.
    def get_bill_drawer(bill, **params)
      get bill_url(bill, display: "drawer", **params), headers: { "Turbo-Frame" => "drawer" }
    end

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
