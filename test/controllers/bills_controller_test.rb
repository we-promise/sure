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
  test "index excludes income, transfers and inactive rows" do
    create_bill(name: "Real bill", amount: 50)
    create_bill(name: "Paycheck", amount: -2000)
    create_bill(name: "Paused bill", amount: 30, status: "inactive")
    create_bill(name: "Moved to savings", amount: 100,
                destination_account_id: accounts(:credit_card).id)

    get bills_url

    assert_response :success
    assert_match "Real bill", response.body
    assert_no_match "Paycheck", response.body
    assert_no_match "Paused bill", response.body
    assert_no_match "Moved to savings", response.body
  end

  test "index shows an overdue bill" do
    create_bill(name: "Late bill", amount: 75,
                last_occurrence_date: 2.months.ago.to_date,
                next_expected_date: 10.days.ago.to_date)

    get bills_url

    assert_response :success
    assert_match "Late bill", response.body
    assert_match I18n.t("bills.index.overdue"), response.body
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
        currency: "USD",
        expected_day_of_month: Date.current.day,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active"
      }.merge(overrides))
    end
end
