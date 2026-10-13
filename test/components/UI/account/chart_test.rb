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
