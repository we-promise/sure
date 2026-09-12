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
    # Inside a collapsed <details>, so hidden until opened.
    assert_selector "table##{ActionView::RecordIdentifier.dom_id(loan_account, :loan_chart_table)}", visible: :all
    assert_selector "p.sr-only", text: payload[:aria_description], visible: :all
  end

  test "a non-loan account mounts the time-series chart and no loan chart" do
    render_inline(UI::Account::Chart.new(account: @account, view: "balance"))

    assert_no_selector "[data-controller='loan-payoff-chart']"
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

  # jjmata on we-promise/sure#3474: the table toggle is DS::Disclosure, so it
  # carries the design system's summary contract (focus ring, no native
  # marker) rather than a hand-built <details>.
  test "the chart's table toggle is a design-system disclosure" do
    loan_account = accounts(:loan)
    payload = Loan::PayoffChart.new(loan_account.loan, as_of: Date.current).payload
    assert_not_nil payload, "the loan fixture must have a schedule, or this test asserts nothing"

    render_inline(UI::Account::Chart.new(account: loan_account, loan_chart: payload))

    assert_selector "details.group > summary.focus-ring", text: I18n.t("UI.account.chart.loan.view_as_table")
    assert_selector "details.group table##{ActionView::RecordIdentifier.dom_id(loan_account, :loan_chart_table)}", visible: :all
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
