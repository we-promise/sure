require "test_helper"

class Portfolio::SectionRegistryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @period = Period.last_30_days
    @as_of = Date.current
    @statement = InvestmentStatement.new(@family, user: @user)
  end

  test "registers the built-in sections with their partials and locals" do
    sections = registry.sections

    assert_equal %w[kpis performance index_chart value_chart holdings accounts], Portfolio::SectionRegistry::KEYS
    assert_equal Portfolio::SectionRegistry::KEYS, sections.map { |s| s[:key] }
    assert_equal %w[portfolios/kpi_row portfolios/performance portfolios/index_chart portfolios/value_chart portfolios/holdings portfolios/accounts], sections.map { |s| s[:partial] }
    assert sections.all? { |s| s[:collapsible] }

    # Every partial gets its locals passed in: none of them reaches for
    # Date.current or Current.family on its own.
    sections.each do |section|
      assert_equal({ statement: @statement, period: @period, as_of: @as_of }, section[:locals].slice(:statement, :period, :as_of),
        "#{section[:key]} must receive the shared locals rather than reading them itself")
    end
  end

  # The six return figures come from ONE Portfolio::Performance for the request.
  # Six independently-derived figures could each re-read the period, which is
  # the class of defect the "one as_of, passed down" rule on this class exists
  # to prevent.
  test "the performance section reads every figure from one computation" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    @statement.expects(:performance).with(period: @period).returns(perf).once

    section = registry.sections.find { |s| s[:key] == "performance" }

    assert_equal "portfolios/performance", section[:partial]
    assert_same perf, section[:locals][:performance]
    assert_equal %i[twr annualized_twr mwr annualized_mwr volatility max_drawdown].sort,
                 section[:locals][:returns].keys.sort
  end

  # nil is an outcome, not a gap: a figure whose rate is missing is
  # suppressed, as is one for an account with fewer than two balance days, and
  # the money-weighted return is withheld from a valuation-only scope. Passing nil through
  # rather than defaulting is what lets the card say "no data" instead of
  # printing a zero return that nobody earned.
  test "the performance section passes a withheld figure through as nil" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:time_weighted_return).returns(BigDecimal("0.21"))
    perf.stubs(:money_weighted_return).returns(nil)
    @statement.stubs(:performance).returns(perf)

    returns = registry.sections.find { |s| s[:key] == "performance" }[:locals][:returns]

    assert_equal BigDecimal("0.21"), returns[:twr]
    assert_nil returns[:mwr], "a withheld figure must not be defaulted to zero"
  end

  # The index is a level, not an amount: 121.34 means the portfolio returned
  # 21.34%. Series passes a non-Money value through untouched, which is what
  # lets the same chart controller draw it -- and is also what would let a
  # Money slip in unnoticed, so the payload is asserted rather than assumed.
  test "the index chart series carries rebased levels, not money" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:index_series).returns([
      [ Date.new(2026, 3, 1), BigDecimal("100") ],
      [ Date.new(2026, 3, 2), BigDecimal("110") ],
      [ Date.new(2026, 3, 3), BigDecimal("121.34") ]
    ])
    @statement.stubs(:performance).returns(perf)

    section = registry.sections.find { |s| s[:key] == "index_chart" }

    assert section[:visible]
    values = section[:locals][:series].values
    assert_equal 4, values.size, "the three levels after the base of 100"
    assert_equal BigDecimal("121.34"), values.last.value
    assert_not values.any? { |v| v.value.is_a?(Money) }, "an index level is not money"

    # Rounded before it reaches the wire. A chained level is a division result,
    # and nothing downstream rounds it: the hover would otherwise read
    # 112.30000000000000000000000000000311.
    # Built the way Portfolio::Performance builds it -- chained DIVISION
    # results, not a literal -- because that is what produces the long value.
    # Verified: this is 112.30000000000000000000000000000311, 32 places.
    r1 = (BigDecimal(1037) / BigDecimal(1000)) - 1
    r2 = (BigDecimal(1123) / BigDecimal(1037)) - 1
    chained = BigDecimal(100) * (1 + r1) * (1 + r2)
    assert_operator chained.to_s.split(".").last.length, :>, 4,
                    "the fixture must actually be long, or this test proves nothing"

    long = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    long.stubs(:index_series).returns([
      [ Date.new(2026, 3, 1), BigDecimal("100") ],
      [ Date.new(2026, 3, 2), chained ]
    ])
    @statement.stubs(:performance).returns(long)

    serialised = registry.sections.find { |s| s[:key] == "index_chart" }[:locals][:series].to_json
    assert_no_match(/\d+\.\d{4,}/, serialised,
                    "a level reaches the tooltip with two decimals, not thirty")
  end

  # Performance#index_series starts at the level after the first day's return,
  # 100 * (1 + r1). The chart starts from the base itself, on the day before,
  # so the first day's move is drawn and the tooltip measures it from 100.
  test "the index chart starts from a base of 100 the day before its first return" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:index_series).returns([
      [ Date.new(2026, 3, 2), BigDecimal("104.5") ],
      [ Date.new(2026, 3, 3), BigDecimal("102.25") ]
    ])
    @statement.stubs(:performance).returns(perf)

    series = registry.sections.find { |s| s[:key] == "index_chart" }[:locals][:series]

    assert_equal [ Date.new(2026, 3, 1), Date.new(2026, 3, 2), Date.new(2026, 3, 3) ], series.values.map(&:date)
    assert_equal [ 100, BigDecimal("104.5"), BigDecimal("102.25") ], series.values.map(&:value)
    base, first_day = series.values.first(2)
    assert_equal "flat", base.trend.direction, "nothing precedes the base"
    assert_equal 100, base.trend.current, "the tooltip reads the base's level from its trend"
    assert_equal 100, first_day.trend.previous
    assert_in_delta 4.5, first_day.trend.percent, 0.001, "the first day's return is measured from the base"
  end

  # from_raw_values demands two points, and a period with one day or none has
  # no line to draw. An empty chart says nothing the performance cards above
  # have not already said, so the section hides rather than drawing a blank box.
  test "the index chart section hides when there is no line to draw" do
    perf = Portfolio::Performance.new(family: @family, account_ids: [], period: @period)
    perf.stubs(:index_series).returns([ [ Date.new(2026, 3, 1), BigDecimal("100") ] ])
    @statement.stubs(:performance).returns(perf)

    section = registry.sections.find { |s| s[:key] == "index_chart" }

    assert_not section[:visible]
    assert_nil section[:locals][:series]
  end

  test "the accounts section is visible only when the family has investment accounts" do
    assert registry.sections.find { |s| s[:key] == "accounts" }[:visible]

    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections
    assert_not empty.find { |s| s[:key] == "accounts" }[:visible]
  end

  # The KPI row, the performance cards and the value chart speak for
  # themselves when empty: each says there is not enough data rather than
  # disappearing. (The controller shows the whole-page empty state anyway.)
  test "the KPI row, the performance cards and the value chart stay visible for a family with no data" do
    empty_statement = InvestmentStatement.new(families(:empty), user: nil)
    empty = Portfolio::SectionRegistry.new(statement: empty_statement, period: @period, as_of: @as_of, user: @user).sections

    assert_equal %w[kpis performance value_chart], empty.select { |s| s[:visible] }.map { |s| s[:key] }
  end

  # Every period-dependent figure reads the registry's period. A custom range
  # differs from every default, so a figure that fell back to one would show.
  test "the KPI row and the value chart read the registry's period" do
    period = Period.custom(start_date: 10.days.ago.to_date, end_date: 3.days.ago.to_date)
    # The fixture's figures are the same for any period, so these three are
    # pinned by the argument they are asked with rather than by their value.
    trend = Trend.new(current: Money.new(110, "USD"), previous: Money.new(100, "USD"))
    totals = @statement.totals(period: period)
    @statement.expects(:period_return_trend).with(period: period).returns(trend)
    @statement.expects(:period_return_unconvertible_count).with(period: period).returns(2)
    # net_contributions reads totals for the same period, hence at least once.
    @statement.expects(:totals).with(period: period).at_least_once.returns(totals)

    sections = registry(period: period).sections.index_by { |s| s[:key] }
    kpis = sections["kpis"][:locals][:kpis]

    assert_same trend, kpis[:period_return]
    assert_equal 2, kpis[:period_return_unconvertible]
    assert_equal totals.total_income, kpis[:income]
    assert_equal @statement.net_contributions(period: period), kpis[:net_contributions]
    assert_equal @statement.value_series(period: period).values.size, sections["value_chart"][:locals][:series].values.size
    assert_equal period.end_date, sections["value_chart"][:locals][:series].values.last.date
  end

  test "the KPI row carries the statement's current figures" do
    kpis = registry.sections.find { |s| s[:key] == "kpis" }[:locals][:kpis]

    assert_equal @statement.portfolio_value_money, kpis[:value]
    assert_equal %i[value value_unconvertible day_change day_change_coverage unrealized unrealized_missing_cost_basis
                    period_return period_return_unconvertible net_contributions income], kpis.keys
  end

  # Created in reverse name order, so the cards come back by name only if the
  # query asks for it.
  test "the accounts section lists the cards in name order" do
    zeta = @family.accounts.create!(name: "Zeta brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    alpha = @family.accounts.create!(name: "Alpha brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_includes cards, zeta
    assert_operator cards.index(alpha), :<, cards.index(zeta)
    assert_equal @statement.investment_accounts.to_a.sort_by(&:id), cards.sort_by(&:id),
      "the cards must be exactly the statement's investment accounts"
  end

  # The cards are the statement's own records, so the associations their
  # logos read have to be preloaded onto those records, not left to load per
  # card.
  test "the account cards come with everything their logos read preloaded" do
    logoed = accounts(:investment)
    logoed.logo.attach(io: StringIO.new("logo"), filename: "logo.png", content_type: "image/png")
    provider = LunchflowAccount.create!(lunchflow_item: lunchflow_items(:one), account_id: "lf_registry_logo",
                                        name: logoed.name, currency: "USD")
    AccountProvider.create!(account: logoed, provider: provider)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_not_empty cards
    cards.each do |account|
      %i[logo_attachment accountable plaid_account simplefin_account account_providers].each do |name|
        assert account.association(name).loaded?, "#{name} is not preloaded on #{account.name}"
      end
    end
    card = cards.find { |account| account.id == logoed.id }
    assert card.logo_attachment.association(:blob).loaded?, "the logo's blob is not preloaded"
    assert_not_empty card.account_providers
    card.account_providers.each do |link|
      assert link.association(:provider).loaded?, "the provider link's provider is not preloaded"
    end
  end

  test "the account cards ignore case when ordering by name" do
    lower = @family.accounts.create!(name: "alpha brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    upper = @family.accounts.create!(name: "Beta brokerage", balance: 100, currency: "USD", accountable: Investment.new, owner: @user)
    @statement = InvestmentStatement.new(@family, user: @user)

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_operator cards.index(lower), :<, cards.index(upper)
  end

  # The statement's query has no order of its own, so the tiebreak must not
  # lean on whatever order its rows arrive in: feed them in descending id.
  test "account cards with the same name are ordered by id whatever order the statement returns" do
    same = %w[b d f].map do |digit|
      @family.accounts.create!(id: "#{digit * 8}-0000-4000-8000-000000000000", name: "Same brokerage", balance: 100,
                               currency: "USD", accountable: Investment.new, owner: @user)
    end
    @statement.stubs(:investment_accounts).returns(@family.accounts.where(id: same.map(&:id)).order(id: :desc))

    cards = registry.sections.find { |s| s[:key] == "accounts" }[:locals][:accounts]

    assert_equal same.map(&:id), cards.map(&:id)
  end

  test "orders sections by the user's saved order, appending anything it omits" do
    @user.update_section_preferences("portfolio", order: %w[stub])

    assert_equal %w[stub kpis performance index_chart value_chart holdings accounts], registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }
  end

  test "a saved order that repeats a key renders that section once" do
    @user.update_section_preferences("portfolio", order: %w[stub accounts stub])

    keys = registry(extra_sections: [ stub_section ]).sections.map { |s| s[:key] }

    assert_equal %w[stub accounts kpis performance index_chart value_chart holdings], keys
  end

  test "ignores keys in the saved order that no longer exist" do
    @user.update_section_preferences("portfolio", order: %w[gone accounts])

    assert_equal %w[accounts kpis performance index_chart value_chart holdings], registry.sections.map { |s| s[:key] }
  end

  test "appends extra sections after the built-ins" do
    sections = registry(extra_sections: [ stub_section ]).sections

    assert_equal %w[kpis performance index_chart value_chart holdings accounts stub], sections.map { |s| s[:key] }
  end

  # A family whose investment accounts hold nothing has no rows to list, so
  # the section stays out rather than drawing an empty table.
  test "the holdings section is visible only when the family holds a security" do
    assert registry.sections.find { |s| s[:key] == "holdings" }[:visible]

    Holding.where(account: @statement.investment_accounts).delete_all
    @statement = InvestmentStatement.new(@family, user: @user)
    sections = registry.sections

    assert_not sections.find { |s| s[:key] == "holdings" }[:visible]
    assert sections.find { |s| s[:key] == "accounts" }[:visible], "the accounts still list with nothing held"
  end

  # The statement falls back on its own for an unknown sort, so the view must
  # be told what it fell back to, or no header shows the sort it sees.
  test "passes the effective sort and direction to the holdings locals" do
    holdings = Portfolio::SectionRegistry.new(
      statement: @statement, period: @period, as_of: @as_of, user: @user, sort: "unsupported", dir: "asc"
    ).sections.find { |s| s[:key] == "holdings" }

    assert_equal [ "value", "asc" ], [ holdings[:locals][:sort], holdings[:locals][:dir] ]
    values = holdings[:locals][:rows].map { |row| row.amount.amount }
    assert_equal values.sort, values, "the rows are in the order the locals name"
  end

  test "passes the sort and direction through to the holdings locals" do
    # Ticker order and name order disagree for this one: it sorts last by
    # ticker and first by name, so a name sort that secretly ordered by
    # ticker would put it in the wrong place.
    zebra = Security.create!(ticker: "ZZZA", name: "Aardvark Holdings")
    Holding.create!(
      account: accounts(:investment), security: zebra, date: Date.current,
      qty: 1, price: 10, amount: 10, currency: "USD", cost_basis: 8, cost_basis_locked: true
    )

    holdings = Portfolio::SectionRegistry.new(
      statement: @statement, period: @period, as_of: @as_of, user: @user, sort: "name", dir: "asc"
    ).sections.find { |s| s[:key] == "holdings" }

    assert_equal "name", holdings[:locals][:sort]
    assert_equal "asc", holdings[:locals][:dir]
    rows = holdings[:locals][:rows]
    names = rows.map { |row| row.name.downcase }
    assert_equal names.sort, names, "sort: \"name\" must order by security name, not ticker"
    assert_equal "ZZZA", rows.first.ticker, "the name sort must put Aardvark first despite its ticker"
  end

  private
    def stub_section
      { key: "stub", title: "portfolios.sections.accounts", partial: "portfolios/accounts",
        locals: {}, visible: true, collapsible: true }
    end

    def registry(extra_sections: [], period: @period)
      Portfolio::SectionRegistry.new(
        statement: @statement,
        period: period,
        as_of: @as_of,
        user: @user,
        extra_sections: extra_sections
      )
    end
end
