# The list of sections the portfolio hub renders, in the order the user last
# left them.
#
# Same shape as ReportsController#build_reports_sections -- a hash per section
# with `key`, an i18n `title` key, a `partial`, its `locals`, and the `visible`
# / `collapsible` flags -- so the Reports section chrome (drag to reorder,
# chevron to collapse) renders it unchanged. It lives here rather than in the
# controller because the ordering rule and the section list are domain
# decisions the controller only renders, and because a PORO can be unit-tested
# without a request.
#
# Every local a partial needs is passed in. Nothing here (and nothing in the
# partials) reads Date.current or Current.family: the controller captures one
# `as_of` and one statement per request and hands them down, so the sections
# that take a date all read the same one.
class Portfolio::SectionRegistry
  # The built-in section keys, in declaration order. The preferences
  # endpoint accepts only these, so a saved order or collapsed set cannot
  # carry arbitrary strings into the user's preferences.
  KEYS = %w[kpis performance index_chart value_chart holdings accounts].freeze

  # Everything an account card's logo reads, preloaded onto the cards.
  CARD_PRELOADS = [ { logo_attachment: :blob }, :accountable, :plaid_account, :simplefin_account, { account_providers: :provider } ].freeze

  attr_reader :statement, :period, :as_of, :user, :sort, :dir, :extra_sections

  # `sort` and `dir` are the holdings table's query-string state, passed
  # through as given: the statement whitelists them
  # (InvestmentStatement::HOLDINGS_SORT_KEYS, HOLDINGS_SORT_DIRECTIONS) and
  # falls back to its defaults for anything else.
  #
  # `extra_sections` are appended after the built-ins, in the order given. It
  # is the seam that keeps this list open: a section can be added (or a test
  # can add one) without editing the built-in list.
  def initialize(statement:, period:, as_of:, user:, sort: nil, dir: nil, extra_sections: [])
    @statement = statement
    @period = period
    @as_of = as_of
    @user = user
    @sort = sort
    @dir = dir
    @extra_sections = extra_sections || []
  end

  # True when the viewer counts no investment account; the page shows its
  # empty state instead of the sections. Reads the same loaded list as the
  # cards, so the accounts are queried once per request.
  def empty?
    accounts_for_cards.empty?
  end

  def sections
    all = built_in_sections + extra_sections

    # Order by the user's saved order; anything the saved order doesn't
    # mention (a section added since they last dragged one) is appended in
    # declaration order, so a new section always appears rather than
    # disappearing until the next drag. Same rule as Reports.
    # `uniq` before the lookup: a saved order that repeats a key would
    # otherwise render that section once per occurrence. The endpoint
    # deduplicates what it writes, but an order written by anything else
    # still has to render once.
    ordered = Array(user&.section_order("portfolio")).uniq.filter_map do |key|
      all.find { |section| section[:key] == key }
    end

    # Matched by key, never by comparing whole section hashes: a section's
    # locals carry the statement and whatever it has memoised, and the order
    # must not depend on how those compare.
    placed = ordered.map { |section| section[:key] }
    ordered + all.reject { |section| placed.include?(section[:key]) }
  end

  private
    def built_in_sections
      [
        {
          key: "kpis",
          title: "portfolios.sections.kpis",
          partial: "portfolios/kpi_row",
          locals: shared_locals.merge(kpis: kpis),
          visible: true,
          collapsible: true
        },
        # Always visible, like kpis and value_chart. A period in which no
        # figure could be computed is a fact about the portfolio worth showing
        # -- the section says which figures are missing and why -- where a
        # vanishing section reads as "this page does not do returns".
        {
          key: "performance",
          title: "portfolios.sections.performance",
          partial: "portfolios/performance",
          locals: shared_locals.merge(performance: performance, returns: returns),
          visible: true,
          collapsible: true
        },
        # Hidden when the period cannot produce two points to join. Unlike the
        # performance cards, an empty chart says nothing a sentence could not
        # say better, and the cards above already state why a period has no
        # figures.
        {
          key: "index_chart",
          title: "portfolios.sections.index_chart",
          partial: "portfolios/index_chart",
          locals: shared_locals.merge(series: index_chart_series, flows_known: performance.flows_known?),
          visible: index_chart_series.present?,
          collapsible: true
        },
        {
          key: "value_chart",
          title: "portfolios.sections.value_chart",
          partial: "portfolios/value_chart",
          locals: shared_locals.merge(series: statement.value_series(period: period)),
          visible: true,
          collapsible: true
        },
        {
          key: "holdings",
          title: "portfolios.sections.holdings",
          partial: "portfolios/holdings",
          locals: shared_locals.merge(rows: holdings_rows, sort: holdings_sort.first, dir: holdings_sort.last),
          visible: holdings_rows.any?,
          collapsible: true
        },
        {
          key: "accounts",
          title: "portfolios.sections.accounts",
          partial: "portfolios/accounts",
          locals: shared_locals.merge(accounts: accounts_for_cards),
          visible: accounts_for_cards.any?,
          collapsible: true
        }
      ]
    end

    # The six KPI figures, read from the statement here so the partial only
    # formats them.
    def kpis
      @kpis ||= {
        value: statement.portfolio_value_money,
        day_change: statement.day_change,
        unrealized: statement.unrealized_gains_trend,
        period_return: statement.period_return_trend(period: period),
        period_return_unconvertible: statement.period_return_unconvertible_count(period: period),
        net_contributions: statement.net_contributions(period: period),
        income: statement.totals(period: period).total_income
      }
    end

    # One Portfolio::Performance for the request, so the six figures below and
    # the disclosure flags all come from a single computation over a single
    # period rather than from six that could each re-derive it.
    def performance
      @performance ||= statement.performance(period: period)
    end

    # The six return figures, read here so the partial only formats. Each may
    # be nil -- a missing rate, fewer than two balance days, or no
    # money-weighted return for a valuation-only scope -- and nil is passed
    # through rather than defaulted, because a zero return and no return are
    # different statements.
    def returns
      @returns ||= {
        twr: performance.time_weighted_return,
        annualized_twr: performance.annualized_time_weighted_return,
        mwr: performance.money_weighted_return,
        annualized_mwr: performance.annualized_money_weighted_return,
        volatility: performance.volatility,
        max_drawdown: performance.max_drawdown
      }
    end

    # The flow-adjusted index as a Series the time-series chart can draw.
    #
    # Built here rather than in the partial for the same reason the KPI
    # figures are: the view formats, it does not assemble. Built here rather
    # than on Portfolio::Performance because a Series is a presentation shape,
    # and that class stays free of one.
    #
    # `index_series` is [[date, level], ...] rebased on 100, so the values are
    # plain BigDecimals rather than Money. Series passes a non-Money value
    # through untouched (`display_amount`), and the chart's tooltip then reads
    # a level and a percentage change -- which is what an index is, and why
    # this is not the value chart with different numbers in it.
    #
    # from_raw_values demands two values, and a period with one day or none has
    # no line to draw; nil here is what hides the section.
    def index_chart_series
      return @index_chart_series if defined?(@index_chart_series)

      # Size checked before mapping: a period with one point or none has no line
      # to draw, and building the hashes only to discard them is allocation for
      # nothing on a page that renders this on every request.
      levels = performance.index_series
      @index_chart_series =
        if levels.size >= 2
          # Rounded to two places HERE, because nothing downstream will do it.
          # A chained level is a BigDecimal division result --
          # 112.30000000000000000000000000000311 for an ordinary two-day series
          # -- and Series#display_amount passes a non-Money value through
          # untouched, Trend#as_json emits it raw, and the chart's
          # _extractFormattedValue returns it verbatim. The hover would read
          # every one of those digits. The percentage half is already fine:
          # Trend#percent_formatted rounds it.
          series = Series.from_raw_values(
            levels.map { |date, level| { date: date, value: level.round(2) } }
          )
          # from_raw_values measures the first point against zero, which the
          # tooltip would show as a gain of the whole first level. Nothing
          # precedes the first day, so it reads as no change. Not a nil trend:
          # the chart's tooltip reads every point's trend.
          first = series.values.first
          first.trend = Trend.new(current: first.value, previous: first.value)
          series
        end
    end

    def holdings_rows
      @holdings_rows ||= statement.holdings_table_rows(sort: holdings_sort.first, dir: holdings_sort.last)
    end

    # The sort the statement applies, so the view marks the header the rows
    # are ordered by even when the requested one fell back.
    def holdings_sort
      @holdings_sort ||= InvestmentStatement.holdings_sort(sort, dir)
    end

    # The accounts the cards show, in name order (case-insensitive; id breaks
    # ties, so same-named cards keep their places), with every record the logo
    # reads (the attachment, the accountable's colour, the provider links and
    # the provider each falls back to) loaded here rather than once per card.
    #
    # They are the statement's own records, sorted here, rather than a second
    # query: the holdings section's weights load the same accounts through the
    # statement, and the page reads them once.
    def accounts_for_cards
      @accounts_for_cards ||= begin
        accounts = statement.investment_accounts.to_a.sort_by { |account| [ account.name.downcase, account.id ] }
        ActiveRecord::Associations::Preloader.new(records: accounts, associations: CARD_PRELOADS).call
        accounts
      end
    end

    def shared_locals
      { statement: statement, period: period, as_of: as_of }
    end
end
