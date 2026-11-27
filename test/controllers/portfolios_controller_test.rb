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

  # The rendered Value header is what a user clicks: a custom range rides
  # along, since it lives only in the request; a named period does not,
  # since Periodable saves it as the user's default and the page shows that.
  test "the holdings Value header keeps a custom range and leaves a named period out" do
    @user.update!(default_period: "last_30_days")

    get portfolio_path(start_date: "2026-01-01", end_date: "2026-06-30")
    value_href = css_select("a[href*='sort=value']").first&.[]("href")
    assert value_href, "the Value header link is missing"
    query = Rack::Utils.parse_query(URI(value_href).query)
    assert_equal({ "start_date" => "2026-01-01", "end_date" => "2026-06-30", "sort" => "value" }, query.except("dir"))

    get portfolio_path(period: "last_90_days")
    assert_equal "last_90_days", @user.reload.default_period, "the named period must be saved for the link to leave it out"
    value_href = css_select("a[href*='sort=value']").first&.[]("href")
    assert value_href, "the Value header link is missing"
    query = Rack::Utils.parse_query(URI(value_href).query)
    assert_equal({ "sort" => "value" }, query.except("dir"))
  end

  # The fixture family holds AAPL in accounts(:investment), so both sections
  # have something to show.
  test "renders the hub with its holdings and accounts sections" do
    get portfolio_path

    assert_response :success
    assert_select "h1", text: I18n.t("portfolios.show.title")
    assert_equal %w[holdings accounts], css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_select "header + div[role=list]"
  end

  # No section reads the period yet, so the page offers no control that
  # would change nothing.
  test "the page carries no period picker" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y"), count: 0
    assert_select "a[href^=?]", "#{portfolio_path}?period=", count: 0
  end

  test "an unknown period falls back rather than erroring" do
    get portfolio_path(period: "not_a_period")

    assert_response :success
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

  # `kpis` is a key not in Portfolio::SectionRegistry::KEYS, and is dropped
  # like any other unknown key.
  test "drops section keys the registry does not know, in both shapes" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[kpis nonsense accounts], portfolio_collapsed_sections: { accounts: true, kpis: true, nonsense: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
    assert_equal({ "accounts" => true }, @user.preferences["portfolio_collapsed_sections"],
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
    assert_equal %w[accounts holdings], css_select("[data-section-key]").map { |node| node["data-section-key"] }
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

  test "the investment accounts are queried once per page" do
    queries = capture_sql_queries { get portfolio_path }

    assert_response :success
    assert_select "#portfolio-accounts a", minimum: 1
    # The cards select `accounts.*`; an `any?`/`empty?` check selects `1 AS one`.
    # The layout's sidebar reads accounts with its own select list.
    matching = queries.select do |sql|
      sql.match?(/\ASELECT (DISTINCT )?("accounts"\.\*|1 AS one) FROM "accounts"/) && sql.include?(%("accounts"."exclude_from_reports"))
    end
    assert_equal 1, matching.size, matching.join("\n")
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
    # holding. The ceiling is that figure plus a little headroom, not a
    # guess; the assertion below is the one that matters.
    assert_operator baseline.size, :<=, PORTFOLIO_QUERY_CEILING, "GET /portfolio issued #{baseline.size} queries"

    build_portfolio(accounts: 10, securities: 2, existing_accounts: @family.accounts.where("name LIKE 'Bulk %'").to_a)
    grown = capture_sql_queries { get portfolio_path }
    assert_response :success

    assert_equal baseline.size, grown.size, "adding 20 holdings changed the query count:\n#{(grown - baseline).join("\n")}"
  end

  PORTFOLIO_QUERY_CEILING = 50

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
end
