require "test_helper"

class BillsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    ensure_tailwind_build
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
    create_bill(name: "Paycheck", amount: -2000)
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
    assert_no_match "Paycheck", response.body
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
    assert_match I18n.t("bills.index.overdue"), response.body
    assert_match I18n.t("bills.index.kpi_past_due"), response.body
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
    assert_match I18n.t("bills.index.kpi_remaining"), response.body
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

  test "index renders an empty state with no bills" do
    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.empty.title"), response.body
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
