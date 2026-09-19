require "test_helper"

class UI::Account::ChartTest < ViewComponent::TestCase
  setup do
    @account = accounts(:investment)
    @account.holdings.destroy_all
  end

  test "renders positive gains with explicit plus sign" do
    create_holding(cost_basis: 90)

    render_inline(UI::Account::Chart.new(account: @account, view: "gains"))

    assert_text "+$100.00"
  end

  test "does not sign non-gains views" do
    component = UI::Account::Chart.new(account: @account, view: "balance")

    assert_equal @account.balance_money.format, component.view_balance_display
    refute component.view_balance_display.start_with?("+")
  end

  test "negative gains keep plain money formatting" do
    create_holding(cost_basis: 110)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "-$100.00", component.view_balance_display
  end

  test "converted amount is signed like the main indicator for foreign-currency accounts" do
    @account.update!(currency: "EUR")
    create_holding(cost_basis: 90)
    ExchangeRate.create!(date: Date.current, from_currency: "EUR", to_currency: "USD", rate: 1.1)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "+€100.00", component.view_balance_display
    assert_equal "+$110.00", component.converted_balance_display
  end

  # #100: a loan with a schedule takes the loan balance chart; every other
  # account keeps the chart it always had. Asserted on the mounted controller,
  # because "unchanged for everyone else" is the blast-radius promise this
  # branch makes.
  test "a loan account with a chart payload mounts the loan balance chart and nothing else" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan fixture must have a schedule, or this test asserts nothing"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload))

    assert_selector "[data-controller='loan-payoff-chart']"
    assert_no_selector "[data-controller='time-series-chart']"
    # Owner review of #3474: no data table under the chart; the Schedule tab
    # carries the figures.
    assert_no_selector "table", visible: :all
    assert_selector "p.sr-only", text: payload[:aria_description], visible: :all
  end

  test "a non-loan account mounts the time-series chart and no loan chart" do
    render_inline(UI::Account::Chart.new(account: @account, view: "balance"))

    assert_no_selector "[data-controller='loan-payoff-chart']"
  end

  # Owner review of #3474: the balance a loan's chart plots is what is still
  # owed, and the title says so without "principal".
  test "a loan account's chart is titled remaining balance" do
    render_inline(UI::Account::Chart.new(account: accounts(:loan)))

    assert_selector "p", exact_text: "Remaining balance"
  end

  test "a loan without a chart payload falls back to the chart every account has" do
    loan_account = accounts(:loan)

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: nil))

    assert_no_selector "[data-controller='loan-payoff-chart']"
    assert_selector "[data-controller='time-series-chart']", count: 1
  end

  # Degradation matrix (#100 brief 7.5): the legend promises only the lines
  # the payload says are drawn. Under a period that ends today the forward
  # lines have no room, and a legend entry for a line that is not there is a
  # chart lying about itself.
  test "the legend lists only the series the payload marks visible" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan fixture must have a schedule, or this test asserts nothing"
    windowed = payload.merge(visible: %w[actual scheduled])

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: windowed))

    legend = "ul[aria-label='#{I18n.t("UI.account.chart.loan.legend")}'] li"
    assert_selector legend, count: 2
    assert_selector legend, text: payload[:labels][:actual]
    assert_selector legend, text: payload[:labels][:scheduled]
    assert_no_selector legend, text: payload[:labels][:projected]
  end

  # A projection that ran but never clears the balance has a line and no
  # payoff date. The cards would quote a date that does not exist; the notice
  # says why there is none instead.
  test "a projection with no payoff date shows the not-converged notice in place of the cards" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan fixture must have a schedule, or this test asserts nothing"
    assert payload[:projected].any?, "the fixture loan must project, or this asserts nothing"
    stalled = payload.merge(projected_payoff_date: nil, months_saved: nil, interest_saved: nil, balloon: 12_345.67)

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: stalled))

    # The notice quotes the balloon, so the page says how far behind rather
    # than only that it is.
    assert_text I18n.t("UI.account.chart.loan.not_converged", balloon: Money.new(12_345.67, "USD").format)
    # The card title; the accessible description also says "projected payoff",
    # and must, so the text alone would not tell the two apart.
    assert_no_selector "h4", text: I18n.t("UI.account.chart.loan.projected_payoff")
    assert_selector "[data-controller='loan-payoff-chart']"
  end

  # The cards compare today's recorded balance with the schedule's balance on
  # the same day, and a payment posted before its scheduled date reads as
  # ahead until that date. The basis is stated beside the figures it governs.
  test "the projection cards state the basis of their comparison" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan fixture must have a schedule, or this test asserts nothing"
    assert_not_nil payload[:projected_payoff_date], "the fixture loan must project a payoff, or this asserts nothing"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload))

    assert_text I18n.t("UI.account.chart.loan.projection_basis")
  end

  # jjmata on we-promise/sure#3474: the trend, its comparison label and the
  # chart mount all read the series. It is built once per render, not once per
  # reader.
  test "the card builds its balance series once per render" do
    loan_account = accounts(:loan)
    series = loan_account.balance_series(period: Period.last_30_days, view: "balance")
    loan_account.expects(:balance_series).once.returns(series)

    render_inline(UI::Account::Chart.new(account: loan_account))
  end

  # Owner review of #3474: a loan's picker offers timescales that run forward
  # from its start date, labelled M, 90D, YTD, 1Y, 5Y, 10Y and All. The keys are
  # the shared periods', so a pick stays the user's default everywhere, and a
  # saved period the loan chart does not offer reads as All.
  test "a loan's period picker offers windows that run from its start" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan fixture must have a schedule, or this test asserts nothing"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, period: Period.from_key("last_5_years")))

    {
      "current_month" => "M", "last_90_days" => "90D", "current_year" => "YTD", "last_365_days" => "1Y",
      "last_5_years" => "5Y", "last_10_years" => "10Y", "all_time" => "All"
    }.each do |key, label|
      # The label's own span: the link also holds the menu's check-mark slot.
      assert_selector "a[href*='period=#{key}'] span", exact_text: label, visible: :all
    end
    assert_no_selector "a[href*='period=last_30_days']", visible: :all
    assert_selector "button", text: "5Y"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, period: Period.from_key("last_30_days")))
    assert_selector "button", text: "All"
  end

  # Owner review of #3474: on a loan the change line compares today's balance
  # with the amount borrowed, whatever window is picked.
  test "a loan's change line compares with the original loan amount" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan fixture must have a schedule, or this test asserts nothing"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload, period: Period.from_key("last_5_years")))

    assert_text I18n.t("UI.account.chart.loan.since_start")
    assert_no_text Period.from_key("last_5_years").comparison_label
  end

  test "scopes all_time period to account history_start_date when history postdates family oldest entry date" do
    account_opening = 60.days.ago.to_date
    @account.stubs(:history_start_date).returns(account_opening)

    family_oldest = 5.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal account_opening, component.period.start_date
    assert_equal Date.current, component.period.end_date
    assert_equal "1 day", component.period.interval
  end

  test "does not clamp non-all_time periods even if account opening postdates period start" do
    account_opening = 10.days.ago.to_date
    @account.stubs(:history_start_date).returns(account_opening)

    last_30_days = Period.from_key("last_30_days")
    component = UI::Account::Chart.new(account: @account, period: last_30_days)

    assert_equal "last_30_days", component.period.key
    assert_equal 30.days.ago.to_date, component.period.start_date
  end

  test "unlinked account with trade 2 years ago clamps all_time to 2 years with 1 week interval" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    family_oldest = 10.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal two_years_ago, component.period.start_date
    assert_equal "1 week", component.period.interval
  end

  test "unlinked account with trade 10 years ago clamps all_time to 10 years with 1 month interval" do
    ten_years_ago = 10.years.ago.to_date
    @account.stubs(:history_start_date).returns(ten_years_ago)

    family_oldest = 15.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal ten_years_ago, component.period.start_date
    assert_equal "1 month", component.period.interval
  end

  test "unlinked account on 5Y period does not clamp period and shows full timeframe comparison" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    last_5_years = Period.from_key("last_5_years")
    component = UI::Account::Chart.new(account: @account, period: last_5_years)

    assert_equal "last_5_years", component.period.key
    assert_equal 5.years.ago.to_date, component.period.start_date
    assert_equal "1 week", component.period.interval

    last_10_years = Period.from_key("last_10_years")
    ten_year_component = UI::Account::Chart.new(account: @account, period: last_10_years)
    assert_equal "last_10_years", ten_year_component.period.key
    assert_equal 10.years.ago.to_date, ten_year_component.period.start_date
    assert_equal "1 month", ten_year_component.period.interval

    # When series covers full period (unlinked account showing 0 baseline)
    mock_series = Series.new(
      start_date: 5.years.ago.to_date,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: 5.years.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: @account.favorable_direction
    )
    component.stubs(:series).returns(mock_series)
    assert_equal "vs. 5 years ago", component.comparison_label
  end

  test "linked account on 5Y period with trimmed history shows vs available history comparison" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    last_5_years = Period.from_key("last_5_years")
    component = UI::Account::Chart.new(account: @account, period: last_5_years)

    # Series normalized to 2 years ago (trimmed from 5 years ago)
    mock_series = Series.new(
      start_date: two_years_ago,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: two_years_ago, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: @account.favorable_direction
    )
    component.stubs(:series).returns(mock_series)
    assert_equal I18n.t("UI.account.chart.vs_available_history"), component.comparison_label
  end

  test "empty account with nil history_start_date leaves all_time period unchanged" do
    @account.stubs(:history_start_date).returns(nil)

    family_oldest = 5.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal family_oldest, component.period.start_date
  end

  private
    # 10 shares at $100 market price; gain = 1000 - cost_basis * 10
    def create_holding(cost_basis:)
      Holding.create!(
        account: @account,
        security: securities(:aapl),
        date: Date.current,
        qty: 10,
        price: 100,
        amount: 1000,
        currency: @account.currency,
        cost_basis: cost_basis
      )
    end
end
