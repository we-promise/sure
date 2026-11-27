require "test_helper"

class PortfoliosControllerTest < ActionDispatch::IntegrationTest
  include SqlQueryCapture

  setup do
    @user = users(:family_admin)
    @family = @user.family
    enable_preview(@user)
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects users without preview access to the dashboard" do
    disable_preview(@user)

    get portfolio_path

    assert_redirected_to root_path
    assert_equal I18n.t("preview.not_enabled"), flash[:alert]
  end

  # The class-level gate covers every action, so the one endpoint that writes
  # cannot save preferences for a page its caller is not allowed to see.
  test "preference writes are preview-gated like the page" do
    disable_preview(@user)

    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts] } },
      as: :json

    assert_redirected_to root_path
    assert_nil @user.reload.preferences["portfolio_section_order"]
  end

  test "a request the gate turns away does not save its period as the user's default" do
    disable_preview(@user)
    @user.update!(default_period: "last_30_days")

    get portfolio_path(period: "last_5_years")

    assert_redirected_to root_path
    assert_equal "last_30_days", @user.reload.default_period
  end

  test "a preview user's period pick is still saved as their default" do
    @user.update!(default_period: "last_30_days")

    get portfolio_path(period: "last_365_days")

    assert_response :success
    assert_equal "last_365_days", @user.reload.default_period
  end

  # The KPI row reads the family's income totals. Those used a ::boolean cast
  # on provider pending flags, so one flag PostgreSQL cannot parse raised out
  # of the aggregation and took the whole page down with it.
  test "the hub renders when an income entry carries a non-boolean pending flag" do
    accounts(:investment).entries.create!(
      name: "Dividend", date: Date.current, amount: -12, currency: "USD",
      entryable: Transaction.new(investment_activity_label: "Dividend", extra: { "plaid" => { "pending" => "maybe" } })
    )

    get portfolio_path

    assert_response :success
    assert_select "[data-section-key=?]", "kpis", count: 1
  end

  # The fixture family holds AAPL in accounts(:investment), so both sections
  # have something to show.
  test "renders the hub, its turbo frame and every section the family has data for" do
    get portfolio_path

    assert_response :success
    assert_select "h1", text: I18n.t("portfolios.show.title")
    assert_select "turbo-frame#portfolio_sections"
    assert_equal %w[kpis value_chart holdings accounts], css_select("[data-section-key]").map { |node| node["data-section-key"] }
  end

  test "the period picker reflects the requested period" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    # DS::MenuItem marks the current row with role=menuitemradio + aria-checked
    # (not aria-current), so that is what the picker's selection looks like.
    assert_select "a[href=?][aria-checked=?]", portfolio_path(period: "last_5_years"), "true"
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y")
    assert_equal "last_5_years", @user.reload.default_period
  end

  # The picker shares the heading's row rather than taking one of its own
  # between the heading and the first section, and that row is the frame's
  # first child so the first section follows it.
  test "the period picker shares the heading's row, directly above the sections" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    assert_select "turbo-frame#portfolio_sections > div:first-child > header h1",
      text: I18n.t("portfolios.show.title")
    assert_select "turbo-frame#portfolio_sections > div:first-child > header + div[data-controller='DS--menu']" do
      assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y")
    end
    assert_select "turbo-frame#portfolio_sections > div:first-child + div[role=list]"
  end

  # Each picker link re-renders the frame, and the frame sends every other
  # link inside it (an account card, say) to the whole page.
  test "the picker links target the sections frame, and the frame breaks out for everything else" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    assert_select "turbo-frame#portfolio_sections[target=_top]"
    assert_select "a[href=?][data-turbo-frame=?]", portfolio_path(period: "last_30_days"), "portfolio_sections"
  end

  # A period pick keeps the holdings table's sort, so picking a period does
  # not reset the order the user chose.
  test "the picker links carry the holdings sort" do
    get portfolio_path(period: "last_5_years", sort: "name", dir: "asc")

    assert_response :success
    assert_select "a[href=?][data-turbo-frame=?]", portfolio_path(dir: "asc", period: "last_30_days", sort: "name"), "portfolio_sections"
  end

  test "an unknown period falls back rather than erroring" do
    get portfolio_path(period: "not_a_period")

    assert_response :success
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "30D")
  end

  test "the KPI row prints the statement's own figures" do
    period = Period.last_30_days
    statement = InvestmentStatement.new(@family, user: @user)
    helpers = ApplicationController.helpers

    expected = [
      helpers.format_money(statement.portfolio_value_money),
      helpers.format_money(statement.net_contributions(period: period)),
      helpers.format_money(statement.totals(period: period).total_income)
    ]
    expected << helpers.format_money(statement.day_change.value) if statement.day_change
    expected << helpers.format_money(statement.unrealized_gains_trend.value) if statement.unrealized_gains_trend
    expected << helpers.format_money(statement.period_return_trend(period: period).value) if statement.period_return_trend(period: period)

    get portfolio_path(period: "last_30_days")

    assert_response :success
    expected.each do |amount|
      assert_match amount, response.body, "the KPI row should print #{amount}"
    end
  end

  # An account whose currency has no rate is left out of the period return
  # rather than converted at parity, and the card has to say so: a partial
  # figure that does not announce itself reads as a whole one.
  test "the period return card says how many accounts it left out" do
    hint = I18n.t("portfolios.kpi_row.unconvertible_accounts", count: 2)

    get portfolio_path(period: "last_30_days")
    assert_response :success
    assert_no_match hint, response.body, "the fixture must convert every account, or this proves nothing"

    InvestmentStatement.any_instance.stubs(:period_return_unconvertible_count).returns(2)
    get portfolio_path(period: "last_30_days")

    assert_response :success
    assert_select "[data-section-key=kpis] p", text: "#{Period.last_30_days.comparison_label} · #{hint}"
  end

  test "the day change card says how many positions it covers" do
    get portfolio_path
    assert_response :success
    assert_nil kpi_card_hint("day_change"), "every fixture position must have a previous snapshot, or this proves nothing"

    security = Security.create!(ticker: "HALF", name: "Half covered")
    second_broker = @family.accounts.create!(name: "Second broker", balance: 900, cash_balance: 0, currency: "USD", accountable: Investment.new)
    Holding.create!(account: accounts(:investment), security: security, date: 1.day.ago.to_date, qty: 1, price: 100, amount: 100, currency: "USD")
    Holding.create!(account: accounts(:investment), security: security, date: Date.current, qty: 1, price: 120, amount: 120, currency: "USD")
    Holding.create!(account: second_broker, security: security, date: Date.current, qty: 9, price: 100, amount: 900, currency: "USD")

    get portfolio_path
    assert_response :success

    # AAPL and HALF in the first account have a previous snapshot; HALF in the
    # second broker does not.
    assert_equal I18n.t("portfolios.kpi_row.day_change_partial", covered: 2, total: 3), kpi_card_hint("day_change")
  end

  test "the unrealised P&L card says how many positions have no cost basis" do
    get portfolio_path
    assert_response :success
    assert_nil kpi_card_hint("unrealized_pnl"), "every fixture position must have a cost basis, or this proves nothing"

    Holding.create!(account: accounts(:investment), security: Security.create!(ticker: "NOBASIS", name: "Without basis"),
                    date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    # Cash has no cost basis by nature, so it is not a gap.
    Holding.create!(account: accounts(:investment), security: Security.create!(ticker: "CASHX", name: "Cash", kind: "cash"),
                    date: Date.current, qty: 5, price: 1, amount: 5, currency: "USD")

    get portfolio_path
    assert_response :success

    assert_equal I18n.t("portfolios.kpi_row.unrealized_missing_cost_basis", count: 1), kpi_card_hint("unrealized_pnl")
  end

  test "the value card shows not enough data when no account converts" do
    accounts = InvestmentStatement.new(@family, user: @user).investment_accounts
    assert_nil ExchangeRate.find_by(from_currency: "EUR", to_currency: "USD"), "the premise: EUR has no rate into USD"
    accounts.update_all(currency: "EUR")

    get portfolio_path
    assert_response :success

    assert_equal I18n.t("portfolios.kpi_row.no_data"), kpi_card_figure("value")
    assert_includes kpi_card_hint("value"), I18n.t("portfolios.kpi_row.unconvertible_accounts", count: accounts.size)
  end

  test "the value card says how many accounts it left out" do
    get portfolio_path
    assert_response :success
    value = kpi_card_figure("value")
    as_of = I18n.t("portfolios.kpi_row.as_of", date: I18n.l(Date.current, format: :long))
    assert_equal as_of, kpi_card_hint("value")

    @family.accounts.create!(name: "Euro broker", balance: 500, currency: "EUR", accountable: Investment.new, owner: @user)
    get portfolio_path
    assert_response :success

    assert_equal value, kpi_card_figure("value"), "the convertible accounts' value must stand"
    assert_equal "#{as_of} · #{I18n.t("portfolios.kpi_row.unconvertible_accounts", count: 1)}", kpi_card_hint("value")
  end

  test "the value card still prints a genuine zero" do
    InvestmentStatement.new(@family, user: @user).investment_accounts.update_all(balance: 0)

    get portfolio_path
    assert_response :success

    assert_equal ApplicationController.helpers.format_money(Money.new(0, @family.currency)), kpi_card_figure("value")
  end

  test "the value chart shows no data when no account converts" do
    InvestmentStatement.new(@family, user: @user).investment_accounts.each { |account| seed_end_balances(account) }
    get portfolio_path(period: "last_30_days")
    assert_response :success
    assert_select "#portfolioValueChart", 1, "the fixture must chart in USD, or this proves nothing"
    assert_no_match ApplicationController.helpers.format_money(Money.new(0, @family.currency)), css_select("#portfolio-value-chart").first.text

    move_investments_to_currency_without_rate("JPY")
    get portfolio_path(period: "last_30_days")
    assert_response :success

    chart = css_select("#portfolio-value-chart").first
    assert chart, "the value chart section should render"
    assert_no_match ApplicationController.helpers.format_money(Money.new(0, @family.currency)), chart.text
    assert_select "#portfolioValueChart", 0
    assert_includes chart.text, I18n.t("portfolios.value_chart.no_data")
  end

  test "the value chart still draws when only some accounts convert" do
    InvestmentStatement.new(@family, user: @user).investment_accounts.each { |account| seed_end_balances(account) }
    yen = @family.accounts.create!(name: "Yen broker", balance: 50_000, currency: "JPY", accountable: Investment.new, owner: @user)
    seed_end_balances(yen)

    get portfolio_path(period: "last_30_days")
    assert_response :success

    assert_select "#portfolioValueChart", 1
    assert_includes kpi_card_hint("value"), I18n.t("portfolios.kpi_row.unconvertible_accounts", count: 1)
    assert_equal kpi_card_figure("value"), css_select("#portfolio-value-chart p").first.text.squish
  end

  test "the day change and unrealised P&L cards show not enough data when no account converts" do
    no_data = I18n.t("portfolios.kpi_row.no_data")
    # A stored cost basis, as a synced broker keeps it, so the unrealised
    # figure does not rest on USD trades the currency move would orphan.
    Holding.where(account: InvestmentStatement.new(@family, user: @user).investment_accounts).update_all(cost_basis: 150)
    get portfolio_path
    assert_response :success
    assert_not_equal no_data, kpi_card_figure("day_change"), "the fixture must have a day change, or this proves nothing"
    assert_not_equal no_data, kpi_card_figure("unrealized_pnl"), "the fixture must have an unrealised P&L, or this proves nothing"

    move_investments_to_currency_without_rate("JPY")
    get portfolio_path
    assert_response :success

    assert_equal no_data, kpi_card_figure("day_change")
    assert_equal no_data, kpi_card_figure("unrealized_pnl")
  end

  test "the value chart is mounted with the statement's series" do
    seed_investment_balances

    period = Period.last_30_days
    series = InvestmentStatement.new(@family, user: @user).value_series(period: period)
    assert_operator series.values.size, :>=, 2, "fixture setup should produce a chartable series"

    get portfolio_path(period: "last_30_days")

    assert_response :success
    chart = css_select("#portfolioValueChart").first
    assert chart, "the value chart should be mounted"
    data = JSON.parse(chart["data-time-series-chart-data-value"])
    assert_equal series.values.size, data["values"].size
  end

  # The value shown is the series' last point, so the caption dates that
  # point: the end of a past period, not today.
  test "the value chart is dated by its last point, not by today" do
    account = accounts(:investment)
    (0..45).each do |days_ago|
      account.balances.create!(date: days_ago.days.ago.to_date, balance: 10_000 + days_ago, cash_balance: 5_000, currency: "USD")
    end
    period_end = 20.days.ago.to_date
    series = InvestmentStatement.new(@family, user: @user).value_series(period: Period.custom(start_date: 40.days.ago.to_date, end_date: period_end))
    assert_equal period_end, series.values.last&.date, "fixture setup should chart up to the period's end"

    get portfolio_path(start_date: 40.days.ago.to_date.iso8601, end_date: period_end.iso8601)

    assert_response :success
    assert_select "#portfolio-value-chart p", text: I18n.t("portfolios.value_chart.as_of", date: I18n.l(period_end, format: :long))
    assert_select "#portfolio-value-chart p", text: I18n.t("portfolios.value_chart.as_of", date: I18n.l(Date.current, format: :long)), count: 0
  end

  # The chart reads the picked period, not the default one.
  test "the value chart follows the picked period" do
    seed_investment_balances

    get portfolio_path(period: "last_7_days")
    week = JSON.parse(css_select("#portfolioValueChart").first["data-time-series-chart-data-value"])["values"].size
    get portfolio_path(period: "last_30_days")
    month = JSON.parse(css_select("#portfolioValueChart").first["data-time-series-chart-data-value"])["values"].size

    assert_equal InvestmentStatement.new(@family, user: @user).value_series(period: Period.last_7_days).values.size, week
    assert_operator week, :<, month
  end

  test "renders sections in the saved order, collapsed where the user left them" do
    @user.update_section_preferences("portfolio", order: %w[value_chart kpis], collapsed: { "kpis" => true })

    get portfolio_path

    assert_response :success
    # The saved order places the chart first; sections it does not mention
    # follow in declaration order.
    assert_equal %w[value_chart kpis holdings accounts], css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_select "[data-section-key=kpis][data-reports-section-collapsed-value=?]", "true"
    assert_select "[data-section-key=value_chart][data-reports-section-collapsed-value=?]", "false"
  end

  test "shows an empty state with an add-account link when the family has no investment accounts" do
    user = users(:empty)
    enable_preview(user)
    sign_in user
    assert_empty InvestmentStatement.new(user.family, user: user).investment_accounts

    get portfolio_path

    assert_response :success
    assert_match I18n.t("portfolios.empty_state.title"), response.body
    assert_select "a[href=?]", new_account_path
    assert_select "[data-section-key]", count: 0
    assert_select "turbo-frame#portfolio_sections", count: 0
  end

  test "saves the section order and collapsed set under the portfolio namespace only" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts], portfolio_collapsed_sections: { accounts: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
    assert @user.section_collapsed?("portfolio", "accounts")
    assert_nil @user.preferences["reports_section_order"]
    assert_nil @user.preferences["reports_collapsed_sections"]
  end

  test "drops preference keys that are not the portfolio's own" do
    patch update_preferences_portfolio_path,
      params: { preferences: { reports_section_order: %w[x] } },
      as: :json

    assert_response :ok
    assert_nil @user.reload.preferences["reports_section_order"]
  end

  # `performance` is a key not in Portfolio::SectionRegistry::KEYS, and is
  # dropped like any other unknown key.
  test "drops section keys the registry does not know, in both shapes" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[kpis performance nonsense value_chart accounts], portfolio_collapsed_sections: { kpis: true, performance: true, nonsense: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[kpis value_chart accounts], @user.preferences["portfolio_section_order"]
    assert_equal({ "kpis" => true }, @user.preferences["portfolio_collapsed_sections"],
      "an unknown key must not be written into the user's preferences")
  end

  test "stores the holdings section in the saved order and collapsed set" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts holdings], portfolio_collapsed_sections: { holdings: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[accounts holdings], @user.preferences["portfolio_section_order"]
    assert_equal({ "holdings" => true }, @user.preferences["portfolio_collapsed_sections"])

    get portfolio_path
    assert_equal %w[accounts holdings kpis value_chart], css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_select "[data-section-key=holdings][data-reports-section-collapsed-value=?]", "true"
  end

  test "a preferences body that is not an object is refused and writes nothing" do
    before = @user.reload.preferences.dup

    patch update_preferences_portfolio_path, params: { preferences: "foo" }

    assert_response :bad_request
    assert_equal before, @user.reload.preferences
  end

  test "an order that is not a list leaves the saved order alone" do
    @user.update!(preferences: @user.preferences.merge("portfolio_section_order" => %w[accounts]))

    [ "accounts", { accounts: 1 } ].each do |order|
      patch update_preferences_portfolio_path, params: { preferences: { portfolio_section_order: order } }, as: :json

      assert_response :ok
      assert_equal %w[accounts], @user.reload.preferences["portfolio_section_order"], "order #{order.inspect} must not be stored"
    end
  end

  test "deduplicates the saved order, first occurrence winning" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts accounts] } },
      as: :json

    assert_response :ok
    assert_equal %w[accounts], @user.reload.preferences["portfolio_section_order"]
  end

  test "a collapsed payload that is not an object is dropped rather than raised on" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_collapsed_sections: "true", portfolio_section_order: %w[accounts] } },
      as: :json

    assert_response :ok
    @user.reload
    assert_nil @user.preferences["portfolio_collapsed_sections"]
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
  end

  test "renders sections collapsed where the user left them" do
    get portfolio_path
    assert_select "[data-section-key=accounts][data-reports-section-collapsed-value=?]", "false"
    assert_select "[data-section-key=accounts] > details[open] > summary"

    @user.update_section_preferences("portfolio", collapsed: { "accounts" => true })
    get portfolio_path

    assert_response :success
    assert_select "[data-section-key=accounts][data-reports-section-collapsed-value=?]", "true"
    assert_select "[data-section-key=accounts] > details:not([open]) > summary"
  end

  test "the sortable container posts to the portfolio endpoint under its own namespace" do
    get portfolio_path

    assert_response :success
    assert_select "[data-controller~=sortable-list][data-sortable-list-url-value=?][data-sortable-list-param-value=?]",
                  update_preferences_portfolio_path, "preferences.portfolio_section_order"
    assert_select "[data-section-key=accounts][data-reports-section-url-value=?][data-reports-section-preference-key-value=?]",
                  update_preferences_portfolio_path, "portfolio"
  end

  test "the nav shows Portfolio on desktop only, and never without the preview flag" do
    get portfolio_path

    assert_response :success
    assert_select "ul li a[href=?]", portfolio_path, minimum: 1
    assert_select "nav[data-viewport-target=bottomNav] a[href=?]", portfolio_path, count: 0

    disable_preview(@user)
    get root_path

    assert_response :success
    assert_select "a[href=?]", portfolio_path, count: 0
  end

  # Portfolio is the only desktop-only entry, so every other item still
  # reaches both bars: the mobile bar is the desktop rail without Portfolio,
  # plus the mobile-only Assistant.
  test "every other nav item still renders in both bars" do
    get root_path
    assert_response :success

    desktop = css_select("ul li a").map { |link| link["href"] }
    mobile = css_select("nav[data-viewport-target=bottomNav] a").map { |link| link["href"] }

    assert_includes desktop, portfolio_path
    assert_equal desktop - [ portfolio_path ], mobile - [ chats_path ]
    assert_includes mobile, chats_path if @family.assistant_enabled?
  end

  test "accounts grid links every countable investment account to its holdings tab and skips excluded shares" do
    other = users(:family_member)
    shared = @family.accounts.create!(name: "Shared brokerage", balance: 500, currency: "USD", accountable: Investment.new, owner: other)
    shared.share_with!(@user, permission: "read_only", include_in_finances: false)

    get portfolio_path
    assert_response :success

    assert_select "#portfolio-accounts a[href=?]", account_path(accounts(:investment), tab: "holdings")
    assert_select "#portfolio-accounts a[href=?]", account_path(shared, tab: "holdings"), count: 0
    assert_equal InvestmentStatement.new(@family, user: @user).investment_accounts.count, css_select("#portfolio-accounts a").size
    # The cards sit in a narrow grid cell, so they truncate and show focus.
    assert_select "#portfolio-accounts a.focus-ring p.truncate", minimum: 2
  end

  # Each card's logo falls back to its provider's, read through
  # AccountProvider#provider, so the provider records are loaded with the
  # accounts rather than once per card.
  test "the accounts grid loads provider-linked accounts without a query per card" do
    link_investment_account(0)
    one = provider_queries { get portfolio_path }

    link_investment_account(1)
    link_investment_account(2)
    three = provider_queries { get portfolio_path }

    assert_response :success
    assert_select "#portfolio-accounts a", minimum: 3
    assert_equal one, three, "loading the linked accounts' providers grew with the number of cards"
  end

  # Two account lists, each read once: the current scope (the cards, the
  # holdings and the KPI figures) and the historical scope the value chart
  # reads, which also keeps a disabled account up to its cut-off.
  test "the investment accounts are queried once per page" do
    queries = capture_sql_queries { get portfolio_path }

    assert_response :success
    assert_select "#portfolio-accounts a", minimum: 1
    # The cards select `accounts.*`; an `any?`/`empty?` check selects `1 AS one`.
    # The layout's sidebar reads accounts with its own select list.
    matching = queries.select do |sql|
      sql.match?(/\ASELECT (DISTINCT )?("accounts"\.\*|1 AS one) FROM "accounts"/) && sql.include?(%("accounts"."exclude_from_reports"))
    end
    assert_equal 2, matching.size, matching.join("\n")
    assert_equal 2, matching.uniq.size, "one scope was read twice:\n#{matching.join("\n")}"
  end

  # Without an id tiebreaker Postgres may return same-named accounts in any
  # order, so the cards could swap places between requests. The ids descend
  # in insertion order, so storage order and id order disagree.
  test "accounts with the same name are listed in id order" do
    same = %w[f d b].map do |digit|
      @family.accounts.create!(id: "#{digit * 8}-0000-4000-8000-000000000000", name: "Same brokerage", balance: 100,
                               currency: "USD", accountable: Investment.new, owner: @user)
    end

    get portfolio_path

    assert_response :success
    hrefs = css_select("#portfolio-accounts a").map { |a| a["href"] }
    shown = hrefs.filter_map { |href| same.find { |account| href == account_path(account, tab: "holdings") } }
    assert_equal same.sort_by(&:id), shown
  end

  # The empty state shows whenever the viewer counts no investment account,
  # which includes a family whose investment accounts are all excluded.
  test "the empty state does not claim the family has no investment accounts" do
    user = users(:empty)
    enable_preview(user)
    sign_in user
    user.family.accounts.create!(name: "Excluded brokerage", balance: 100, currency: "USD", accountable: Investment.new,
                                 owner: user, exclude_from_reports: true)

    get portfolio_path

    assert_response :success
    assert_select "[data-section-key]", count: 0
    assert_match I18n.t("portfolios.empty_state.title"), response.body
    assert_no_match(/yet/i, I18n.t("portfolios.empty_state.title"))
  end

  test "holdings table renders one row per security with its per-account positions" do
    second = create_second_aapl_account(qty: 20, price: 215)
    statement = InvestmentStatement.new(@family, user: @user)
    row = statement.holdings_table_rows.find { |r| r.ticker == "AAPL" }
    assert_equal 2, row.positions.size, "fixture must hold AAPL in two accounts"

    get portfolio_path
    assert_response :success

    assert_select "#portfolio-holdings tr[data-portfolio-holding='AAPL']", count: 1
    assert_select "#portfolio-holdings tr[data-portfolio-holding='AAPL'] [data-portfolio-value]", text: ApplicationController.helpers.format_money(row.amount_money)
    toggle = css_select("#portfolio-holdings tr[data-portfolio-holding='AAPL'] button[aria-expanded='false'][aria-controls]").first
    assert toggle, "the summary row must carry a collapsed toggle"
    detail = css_select("#portfolio-holdings tr##{toggle["aria-controls"]}[hidden]").first
    assert detail, "the toggle must point at the hidden detail row"
    positions = css_select(detail, "[data-portfolio-positions='AAPL'] a[href^='/holdings/']")
    assert_equal 2, positions.size
    assert_includes positions.map { |a| a["href"] }, holding_path(second.holdings.first)
  end

  test "holdings table sorts through links that flip the active column's direction" do
    zzz = Security.create!(ticker: "ZZZ", name: "Zeta")
    Holding.create!(account: accounts(:investment), security: zzz, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)

    get portfolio_path(sort: "name", dir: "asc")
    assert_response :success

    assert_equal %w[AAPL ZZZ], css_select("#portfolio-holdings tr[data-portfolio-holding]").map { |n| n["data-portfolio-holding"] }
    assert_select "#portfolio-holdings th[aria-sort='ascending'] a[href=?]", "#{portfolio_path}?dir=desc&sort=name"
    assert_select "#portfolio-holdings th a[href=?]", "#{portfolio_path}?dir=desc&sort=value"
    assert_select "#portfolio-holdings th[aria-sort]", count: 1

    get portfolio_path(sort: "value", dir: "asc")
    assert_equal %w[ZZZ AAPL], css_select("#portfolio-holdings tr[data-portfolio-holding]").map { |n| n["data-portfolio-holding"] }
    assert_select "#portfolio-holdings th[aria-sort='ascending'] a[href=?]", "#{portfolio_path}?dir=desc&sort=value"
  end

  # Anything outside the statement's whitelists falls back to the default
  # sort, value descending, and never reaches a link.
  test "holdings sort params are whitelisted before they reach the sort links" do
    get portfolio_path(sort: "drop table", dir: "sideways")
    assert_response :success

    assert_select "#portfolio-holdings th[aria-sort='descending'] a[href=?]", "#{portfolio_path}?dir=asc&sort=value"
    assert_select "#portfolio-holdings th[aria-sort]", count: 1
    assert_select "#portfolio-holdings a[href*=?]", "drop", count: 0
    assert_select "#portfolio-holdings a[href*=?]", "sideways", count: 0
  end

  test "holdings table flags a row whose position has no cost basis" do
    priced = Security.create!(ticker: "BASIS", name: "With basis")
    Holding.create!(account: accounts(:investment), security: priced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)
    # Neither a stored basis nor a buy trade to compute one from, so
    # Holding#avg_cost is nil and the row is flagged. AAPL is deliberately
    # not the example: it has a fixture trade, so its basis is computable
    # even though nothing is stored on the holding.
    unknown = Security.create!(ticker: "NOBASIS", name: "Without basis")
    Holding.create!(account: accounts(:investment), security: unknown, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    # One security, a known basis in one account and none in another: the row
    # warns, yet still shows the average cost of the position that has one.
    partial = Security.create!(ticker: "PARTIAL", name: "Partly known basis")
    second_broker = accounts(:investment).family.accounts.create!(name: "Second broker", balance: 10, cash_balance: 0, currency: "USD", accountable: Investment.new)
    Holding.create!(account: accounts(:investment), security: partial, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true)
    Holding.create!(account: second_broker, security: partial, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    get portfolio_path
    assert_response :success

    row_hint = I18n.t("portfolios.holdings.missing_cost_basis_hint")
    position_hint = I18n.t("portfolios.holdings.position_missing_cost_basis_hint")
    eight = Regexp.escape(ApplicationController.helpers.format_money(Money.new(8, "USD")))

    assert_select "tr[data-portfolio-holding='NOBASIS']", text: /#{I18n.t("portfolios.holdings.missing_cost_basis")}/
    assert_select "tr[data-portfolio-holding='NOBASIS'] span[title=?]", row_hint
    assert_select "[data-portfolio-positions='NOBASIS'] span[title=?]", position_hint, text: "—"
    assert_select "tr[data-portfolio-holding='AAPL']", text: /#{I18n.t("portfolios.holdings.missing_cost_basis")}/, count: 0,
      message: "AAPL's basis is computable from its trade, so the row must not warn"
    assert_select "tr[data-portfolio-holding='BASIS']", text: /#{I18n.t("portfolios.holdings.missing_cost_basis")}/, count: 0
    assert_select "tr[data-portfolio-holding='BASIS']", text: /#{eight}/

    assert_select "tr[data-portfolio-holding='PARTIAL'] span[title=?]", row_hint
    assert_select "tr[data-portfolio-holding='PARTIAL']", text: /#{eight}/,
      message: "a partly known basis still shows the average cost the row hint describes"
    assert_select "[data-portfolio-positions='PARTIAL'] span[title=?]", position_hint, count: 1
    # AAPL stores no basis but has a buy trade, so its position shows the
    # computed average cost rather than the missing-basis dash.
    aapl_cost = statement_avg_cost("AAPL")
    assert_select "[data-portfolio-positions='AAPL'] span[title=?]", position_hint, count: 0
    assert_select "[data-portfolio-positions='AAPL'] td", text: ApplicationController.helpers.format_money(aapl_cost)
  end

  test "holdings table renders its figures with design-system parts in the page's locale" do
    second = create_second_aapl_account(qty: 20, price: 215)
    statement = InvestmentStatement.new(@family, user: @user)
    row = statement.holdings_table_rows.find { |r| r.ticker == "AAPL" }
    assert row.unrealized, "precondition: AAPL has a return to show"

    get portfolio_path(locale: "de")
    assert_response :success

    aapl = "#portfolio-holdings tr[data-portfolio-holding='AAPL']"
    # DS::ProgressRing: a decorative svg the adjacent percentage labels, not
    # the legacy partial's hard-coded gray track.
    assert_select "#{aapl} svg[aria-hidden='true'] circle", minimum: 2
    assert_select "#{aapl} circle.text-gray-300", count: 0
    expected = I18n.with_locale(:de) { ApplicationController.helpers.number_to_percentage(row.unrealized.percent, precision: 1) }
    assert_select "#{aapl} [data-trend-percent]", text: "(#{expected})"
    assert_match ",", expected, "precondition: German writes a decimal comma"
    assert_select "#{aapl} p.wrap-anywhere", text: row.name
    assert_select "[data-portfolio-positions='AAPL'] th", text: I18n.t("portfolios.holdings.columns.cost_basis_per_share", locale: :de)
    assert second
  end

  # The row's warning badge explains itself on hover only through its title,
  # so the explanation is also visible text in the row's details.
  test "a row without a full cost basis explains it in its details as visible text" do
    unknown = Security.create!(ticker: "NOBASIS", name: "Without basis")
    Holding.create!(account: accounts(:investment), security: unknown, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    get portfolio_path
    assert_response :success

    toggle = css_select("#portfolio-holdings tr[data-portfolio-holding='NOBASIS'] button[aria-controls]").first
    assert_select "tr##{toggle["aria-controls"]} p", text: I18n.t("portfolios.holdings.missing_cost_basis_hint")
  end

  test "a day change that covers only some positions says how many" do
    security = Security.create!(ticker: "HALF", name: "Half covered")
    second_broker = @family.accounts.create!(name: "Second broker", balance: 900, cash_balance: 0, currency: "USD", accountable: Investment.new)
    Holding.create!(account: accounts(:investment), security: security, date: 1.day.ago.to_date, qty: 1, price: 100, amount: 100, currency: "USD")
    Holding.create!(account: accounts(:investment), security: security, date: Date.current, qty: 1, price: 120, amount: 120, currency: "USD")
    Holding.create!(account: second_broker, security: security, date: Date.current, qty: 9, price: 100, amount: 900, currency: "USD")

    get portfolio_path
    assert_response :success

    assert_select "tr[data-portfolio-holding='HALF'] [data-day-change-partial]",
      text: I18n.t("portfolios.holdings.day_change_partial", covered: 1, total: 2)
    assert_select "tr[data-portfolio-holding='AAPL'] [data-day-change-partial]", count: 0
  end

  test "the page's query count is bounded and does not grow with holdings" do
    build_portfolio(accounts: 10, securities: 6)
    baseline = capture_sql_queries { get portfolio_path }
    assert_response :success

    # Measured: 42 queries for this page (layout included) with the holdings
    # and accounts sections, 10 accounts and 60 holdings, none of them per
    # holding; 68 with the KPI row and the value chart, which read the
    # family-wide figures and series once each. The ceiling is that figure plus a little headroom, not a
    # guess; the assertion below is the one that matters.
    assert_operator baseline.size, :<=, PORTFOLIO_QUERY_CEILING, "GET /portfolio issued #{baseline.size} queries"

    build_portfolio(accounts: 10, securities: 2, existing_accounts: @family.accounts.where("name LIKE 'Bulk %'").to_a)
    grown = capture_sql_queries { get portfolio_path }
    assert_response :success

    assert_equal baseline.size, grown.size, "adding 20 holdings changed the query count:\n#{(grown - baseline).join("\n")}"
  end

  PORTFOLIO_QUERY_CEILING = 72

  private
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => false))
    end

    def link_investment_account(index)
      account = @family.accounts.create!(name: "Linked brokerage #{index}", balance: 1_000, currency: "USD",
                                         accountable: Investment.new, owner: @user)
      provider = LunchflowAccount.create!(lunchflow_item: lunchflow_items(:one), account_id: "lf_portfolio_#{index}",
                                          name: account.name, currency: "USD")
      AccountProvider.create!(account: account, provider: provider)
    end

    # The KPI card labelled with portfolios.kpi_row.<label_key>: its first
    # paragraph is the figure, a second one the hint.
    def kpi_card(label_key)
      label = I18n.t("portfolios.kpi_row.#{label_key}")
      card = css_select("[data-section-key=kpis] span").find { |span| span.text.strip == label }&.ancestors("div")&.[](1)
      assert card, "no KPI card labelled #{label}"
      card
    end

    def kpi_card_figure(label_key)
      kpi_card(label_key).css("p")[0].text.squish
    end

    def kpi_card_hint(label_key)
      kpi_card(label_key).css("p")[1]&.text&.squish
    end

    def provider_queries(&block)
      capture_sql_queries(&block).count { |sql| sql.include?(%(FROM "lunchflow_accounts")) }
    end

    def statement_avg_cost(ticker)
      row = InvestmentStatement.new(@family, user: @user).holdings_table_rows.find { |r| r.ticker == ticker }
      assert_nil row.positions.sole.cost_basis, "the premise: #{ticker} stores no cost basis"
      row.positions.sole.avg_cost
    end

    def create_second_aapl_account(qty:, price:)
      account = @family.accounts.create!(owner: @user, name: "Second Brokerage", balance: qty * price, cash_balance: 0, currency: "USD", accountable: Investment.new)
      Holding.create!(account: account, security: securities(:aapl), date: Date.current, qty: qty, price: price, amount: qty * price, currency: "USD")
      account
    end

    # `accounts` investment accounts each holding `securities` securities,
    # with a previous-day snapshot per position so day change has work to do.
    # Every other security has no stored cost basis, the shape a synced
    # brokerage produces, so a view that reached for Holding#avg_cost (and
    # its per-holding trades query) would show up in the count.
    def build_portfolio(accounts:, securities:, existing_accounts: nil)
      accounts = existing_accounts || Array.new(accounts) do |i|
        @family.accounts.create!(owner: @user, name: "Bulk #{i}", balance: 1000 * securities, cash_balance: 50, currency: "USD", accountable: Investment.new)
      end
      securities = Array.new(securities) do |i|
        Security.create!(ticker: "B#{SecureRandom.hex(3).upcase}#{i}", name: "Bulk security #{i}")
      end
      accounts.each do |account|
        securities.each_with_index do |security, index|
          basis = index.even? ? { cost_basis: 90, cost_basis_locked: true } : {}
          Holding.create!(account: account, security: security, date: 1.day.ago.to_date, qty: 10, price: 95, amount: 950, currency: "USD", **basis)
          Holding.create!(account: account, security: security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD", **basis)
        end
      end
    end

    # Every investment account, its balances and its holdings in a currency
    # with no rate into the family's, so nothing on the page converts.
    def move_investments_to_currency_without_rate(currency)
      assert_nil ExchangeRate.find_by(from_currency: currency, to_currency: @family.currency), "the premise: #{currency} has no rate"
      accounts = InvestmentStatement.new(@family, user: @user).investment_accounts
      accounts.update_all(currency: currency)
      Balance.where(account: accounts).update_all(currency: currency)
      Holding.where(account: accounts).update_all(currency: currency)
    end

    # Two days of balances whose end_balance is the account's balance, as a
    # sync stores them, so the chart's last point matches the value card.
    def seed_end_balances(account)
      [ 1.day.ago.to_date, Date.current ].each do |date|
        account.balances.create!(date: date, balance: account.balance, cash_balance: account.balance,
                                 start_cash_balance: account.balance, currency: account.currency)
      end
    end

    def seed_investment_balances
      account = accounts(:investment)
      (0..10).each do |days_ago|
        date = days_ago.days.ago.to_date
        account.balances.create!(date: date, balance: 10_000 + days_ago, cash_balance: 5_000, currency: "USD")
      end
    end
end
