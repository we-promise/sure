require "digest/md5"

class InvestmentStatement
  include Monetizable

  monetize :total_contributions, :total_dividends, :total_interest, :unrealized_gains

  attr_reader :family, :user, :currency

  # `currency:` reports in one of the family's enabled currencies instead of
  # its primary one.
  def initialize(family, user: nil, currency: nil)
    @family = family
    @user = user || Current.user
    @currency = Family.normalize_currency_code(currency) || family.currency
  end

  # Get totals for a specific period
  def totals(period: Period.current_month)
    account_ids = investment_account_ids

    result = totals_query(account_ids: account_ids, date_range: period.date_range)

    PeriodTotals.new(
      contributions: Money.new(result[:contributions], currency),
      withdrawals: Money.new(result[:withdrawals], currency),
      dividends: Money.new(result[:dividends], currency),
      interest: Money.new(result[:interest], currency),
      trades_count: result[:trades_count],
      currency: currency
    )
  end

  # Net contributions (contributions - withdrawals)
  def net_contributions(period: Period.current_month)
    t = totals(period: period)
    t.contributions - t.withdrawals
  end

  # Total portfolio value across all investment accounts
  def portfolio_value
    investment_accounts.sum { |a| convert_to_report_currency(a.balance, a.currency) }
  end

  def portfolio_value_money
    Money.new(portfolio_value, currency)
  end

  # Total cash in investment accounts
  def cash_balance
    investment_accounts.sum { |a| convert_to_report_currency(a.cash_balance, a.currency) }
  end

  def cash_balance_money
    Money.new(cash_balance, currency)
  end

  # Total holdings value
  def holdings_value
    portfolio_value - cash_balance
  end

  def holdings_value_money
    Money.new(holdings_value, currency)
  end

  # All current holdings across investment accounts. Holdings are returned in
  # their native currency; callers that aggregate across accounts must convert
  # to report currency via convert_to_report_currency.
  #
  # Memoized: top_holdings, allocation, unrealized_gains, unrealized_gains_trend,
  # and day_change each call this, so an unmemoized version ran the same
  # DISTINCT ON query up to 5x per dashboard/report request.
  def current_holdings
    @current_holdings ||= Holding::CurrentForInvestmentAccounts
      .new(investment_account_ids)
      .relation
      .includes(:security, :account)
  end

  # current_holdings as an Array, with the average-cost fallback for every
  # holding that has no stored cost basis computed in one query and handed
  # to the holding (Holding.preload_avg_costs), so the roll-up's trends, the
  # unrealized gains and the holdings table do not run
  # Holding#calculate_avg_cost's two queries per holding. Memoized.
  def holdings_with_avg_costs
    @holdings_with_avg_costs ||= current_holdings.to_a.tap { |holdings| Holding.preload_avg_costs(holdings) }
  end

  # Top investments rolled up by security across accounts, ranked by
  # family-currency value. Weight is % of total portfolio (including cash).
  # Presence is gated on holdings totals — not Account#balance — so a stale
  # zero portfolio_value still surfaces real positions.
  def top_holdings(limit: 5)
    rolled_up = holdings_rolled_up_by_security
    return [] if rolled_up.empty?

    holdings_total = rolled_up.sum { |_, value, _| value }
    return [] if holdings_total.zero?

    total = weight_denominator(holdings_total)

    # Rank/limit on value first; only then compute cost-basis trends for the
    # rows that will be rendered. The cost basis behind them is preloaded for
    # every holding in one query (holdings_with_avg_costs).
    rolled_up
      .first(limit)
      .map do |security, value, holdings|
        HoldingAllocation.new(
          security: security,
          amount: Money.new(value, currency),
          weight: (value / total * 100).round(2),
          trend: combined_holding_trend(holdings)
        )
      end
  end

  # Portfolio allocation by security (rolled up across accounts). Shares the
  # weight denominator with top_holdings so the same security never reports two
  # different percentages. Weights therefore sum to the invested share of the
  # portfolio, not to 100 — cash is the residual.
  def allocation
    rolled_up = holdings_rolled_up_by_security
    holdings_total = rolled_up.sum { |_, value, _| value }
    return [] if holdings_total.zero?

    total = weight_denominator(holdings_total)

    rolled_up.map do |security, value, holdings|
      HoldingAllocation.new(
        security: security,
        amount: Money.new(value, currency),
        weight: (value / total * 100).round(2),
        trend: combined_holding_trend(holdings)
      )
    end
  end

  # Allocation of the portfolio grouped by a classification column of the
  # security, or by :account, :currency or :kind (cash, crypto, standard).
  # Every grouping measures the same portfolio: the holdings plus each
  # account's cash -- its balance less its holdings, positive only
  # (`positive_account_cash`) -- placed where the grouping says cash belongs.
  # So every grouping and every level of the drill-down sums to the same
  # total, and weights sum to 100 within rounding. Segments are sorted largest
  # first. Amounts convert to the report currency at the latest rate; a
  # currency with no rate counts 1:1 (`convert_to_report_currency`).
  ALLOCATION_GROUPINGS = %w[asset_class asset_sub_class sector region account currency kind].freeze

  # The bucket a holding falls into when the column it is grouped by is empty.
  # It is a real segment, not a gap, so a portfolio of unclassified securities
  # is told it has nothing classified yet rather than handed an empty list.
  UNCLASSIFIED = "unclassified".freeze

  # Where account cash and cash securities are filed: the asset class and the
  # sub-class a cash balance belongs to. Values from Security::ASSET_CLASSES
  # and Security::ASSET_SUB_CLASSES.
  CASH_ASSET_CLASS = "liquidity".freeze
  CASH_SUB_CLASS = "cash".freeze

  # One level down from a classification segment: asset class -> sub-class ->
  # positions. Sector, region, account, currency and kind do not nest, so they
  # return [].
  #
  # `parent` is the asset class the sub-class was reached through. A sub-class
  # name such as `unclassified` repeats across asset classes, so without it the
  # bottom level would list other classes' positions too.
  def allocation_children(by, bucket, parent: nil)
    case by.to_s
    when "asset_class" then allocation_sub_classes_within(bucket)
    when "asset_sub_class" then allocation_holdings_within(:asset_sub_class, bucket, CASH_SUB_CLASS, parent: parent)
    else []
    end
  end

  # A grouping outside ALLOCATION_GROUPINGS returns no segments, so a grouping
  # name taken from a query string cannot raise.
  def allocation_by(by)
    case by.to_s
    when "account" then allocation_by_account
    when "currency" then allocation_by_currency
    when "kind" then allocation_by_kind
    when "asset_class" then allocation_by_classification(:asset_class, cash_bucket: CASH_ASSET_CLASS)
    when "asset_sub_class" then allocation_by_classification(:asset_sub_class, cash_bucket: CASH_SUB_CLASS)
    when "sector" then allocation_by_classification(:sector)
    when "region" then allocation_by_classification(:region)
    else []
    end
  end

  # Every security the family holds as one row, with its positions across
  # accounts, sorted for a holdings table. Built from the preloaded
  # current_holdings (holdings_with_avg_costs) and previous_holdings, so the
  # query count does not grow with the number of holdings.
  #
  # Cost basis and unrealised P&L cover the positions whose Holding#avg_cost
  # is known -- a stored cost basis, or the average of the purchases -- and a
  # row with any position outside them is flagged missing_cost_basis. Weights
  # share top_holdings' denominator.
  #
  # sort: one of HOLDINGS_SORT_KEYS; dir: "asc" or "desc". Each falls back on
  # its own -- an unknown sort to "value", an unknown dir to "desc" -- so the
  # query string cannot raise and a valid half of it is kept.
  HOLDINGS_SORT_KEYS = %w[value weight return day_change name].freeze
  HOLDINGS_SORT_DIRECTIONS = %w[asc desc].freeze

  def holdings_table_rows(sort: "value", dir: "desc")
    rolled_up = holdings_rolled_up_by_security
    return [] if rolled_up.empty?

    total = weight_denominator(rolled_up.sum { |_, value, _| value })

    rows = rolled_up.map do |security, value, positions|
      build_holdings_table_row(security, value, positions, total)
    end

    sort_holdings_table_rows(rows, sort: sort, dir: dir)
  end

  # Unrealized gains across all holdings, summed in report currency
  def unrealized_gains
    holdings_with_avg_costs.sum do |holding|
      trend = holding.trend
      trend ? convert_to_report_currency(trend.value, holding.currency) : 0
    end
  end

  # Total contributions (all time) - returns numeric for monetize
  def total_contributions
    all_time_totals.contributions&.amount || 0
  end

  # Total dividends (all time) - returns numeric for monetize
  def total_dividends
    all_time_totals.dividends&.amount || 0
  end

  # Total interest (all time) - returns numeric for monetize
  def total_interest
    all_time_totals.interest&.amount || 0
  end

  def unrealized_gains_trend
    holdings = holdings_with_avg_costs
    return nil if holdings.empty?

    # Only include holdings with known cost basis in the calculation
    holdings_with_cost_basis = holdings.select(&:avg_cost)
    return nil if holdings_with_cost_basis.empty?

    current = holdings_with_cost_basis.sum do |h|
      convert_to_report_currency(h.amount, h.currency)
    end
    previous = holdings_with_cost_basis.sum do |h|
      convert_to_report_currency(h.qty * h.avg_cost.amount, h.currency)
    end

    Trend.new(
      current: Money.new(current, currency),
      previous: Money.new(previous, currency)
    )
  end

  def period_return_trend(period: Period.current_month)
    account_ids = investment_account_ids
    return nil if account_ids.empty?

    absolute_return = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COALESCE(SUM(b.net_market_flows * COALESCE(er.rate, 1)), 0)
          FROM balances b
          JOIN accounts a ON a.id = b.account_id
          LEFT JOIN exchange_rates er ON (
            er.date = b.date
            AND er.from_currency = b.currency
            AND er.to_currency = :currency
          )
          WHERE a.id IN (:account_ids)
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND b.date BETWEEN :start_date AND :end_date
        SQL
        {
          currency: currency,
          account_ids: account_ids,
          family_id: family.id,
          start_date: period.date_range.begin,
          end_date: period.date_range.end
        }
      ])
    ).to_d

    period_start = period.date_range.begin

    # Single query for all accounts' most recent pre-period balance (strict < to avoid
    # double-counting the first day's net_market_flows in both the denominator and absolute_return).
    # FX conversion is done in SQL (matching absolute_return) so balance rows whose currency
    # differs from the account's current currency (e.g. after a currency change) are still picked up.
    start_value = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COALESCE(SUM(b.end_balance * COALESCE(er.rate, 1)), 0)
          FROM accounts a
          INNER JOIN balances b ON b.account_id = a.id
          LEFT JOIN exchange_rates er ON (
            er.date = :period_start
            AND er.from_currency = b.currency
            AND er.to_currency = :currency
          )
          INNER JOIN (
            SELECT b2.account_id, MAX(b2.date) AS max_date
            FROM balances b2
            WHERE b2.account_id IN (:account_ids)
              AND b2.date < :period_start
            GROUP BY b2.account_id
          ) latest ON latest.account_id = b.account_id AND b.date = latest.max_date
          WHERE a.id IN (:account_ids)
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
        SQL
        { account_ids: account_ids, period_start: period_start, family_id: family.id, currency: currency }
      ])
    ).to_d

    return nil if start_value.zero?

    Trend.new(
      current: Money.new(start_value + absolute_return, currency),
      previous: Money.new(start_value, currency)
    )
  end

  # The snapshot before each current holding, keyed by the current holding's
  # id: the latest row for the same account, security and currency dated
  # before the current row, which is what Holding#day_change compares
  # against. One query for every holding rather than one per holding, so a
  # page that lists every position does not issue a query per row. Memoized
  # like current_holdings.
  def previous_holdings
    @previous_holdings ||= begin
      current_ids = current_holdings.map(&:id)

      if current_ids.any?
        # Keyed by the current holding, not by account and security: a provider
        # can report one security in two currencies, and each current row has
        # its own previous snapshot in its own currency.
        Holding.find_by_sql([ <<~SQL.squish, { current_ids: current_ids } ]).index_by(&:current_holding_id)
          SELECT prior.*, current_holdings.id AS current_holding_id
          FROM holdings current_holdings
          JOIN LATERAL (
            SELECT holdings.*
            FROM holdings
            WHERE holdings.account_id = current_holdings.account_id
              AND holdings.security_id = current_holdings.security_id
              AND holdings.currency = current_holdings.currency
              AND holdings.date < current_holdings.date
            ORDER BY holdings.date DESC
            LIMIT 1
          ) prior ON TRUE
          WHERE current_holdings.id IN (:current_ids)
        SQL
      else
        {}
      end
    end
  end

  # Day change for one current holding against its previous snapshot, in the
  # holding's currency, or nil without a prior snapshot. Same result as
  # Holding#day_change, without its per-holding query.
  def holding_day_change(holding)
    return nil unless holding.amount_money

    previous = previous_holdings[holding.id]
    return nil unless previous&.amount_money

    Trend.new(current: holding.amount_money, previous: previous.amount_money)
  end

  # Day change across portfolio, summed in report currency
  def day_change
    changes = current_holdings.to_a.filter_map do |h|
      t = holding_day_change(h)
      next nil unless t
      [
        convert_to_report_currency(t.current.amount, h.currency),
        convert_to_report_currency(t.previous.amount, h.currency)
      ]
    end

    return nil if changes.empty?

    Trend.new(
      current: Money.new(changes.sum { |c, _| c }, currency),
      previous: Money.new(changes.sum { |_, p| p }, currency)
    )
  end

  # Investment accounts
  def investment_accounts
    @investment_accounts ||= begin
      scope = family.accounts.visible.included_in_reports.where(accountable_type: %w[Investment Crypto])
      scope = scope.included_in_finances_for(user) if user
      scope
    end
  end

  private
    # Today's rates for every currency present on the family's investment
    # accounts and their holdings. Mirrors BalanceSheet::AccountTotals#exchange_rates.
    def exchange_rates
      @exchange_rates ||= begin
        account_currencies = investment_accounts.map(&:currency)
        holding_currencies = Holding.where(account_id: investment_account_ids).distinct.pluck(:currency)
        foreign = (account_currencies + holding_currencies)
                    .compact
                    .uniq
                    .reject { |c| c == currency }
        ExchangeRate.rates_for(foreign, to: currency, date: Date.current)
      end
    end

    # Unwrap Money first because this codebase's Money (lib/money.rb) ignores
    # the currency arg of `Money.new` when the payload is already a Money, and
    # `Money * numeric` preserves the source currency — so multiplying a
    # foreign-currency Money by a rate would FX-scale the amount but keep the
    # wrong currency label, corrupting downstream sums.
    def convert_to_report_currency(amount, from_currency)
      return amount if amount.nil?
      numeric = amount.is_a?(Money) ? amount.amount : amount
      return numeric if from_currency == currency
      rate = exchange_rates[from_currency] || 1
      numeric * rate
    end

    def all_time_totals
      @all_time_totals ||= totals(period: Period.all_time)
    end

    PeriodTotals = Data.define(:contributions, :withdrawals, :dividends, :interest, :trades_count, :currency) do
      def net_flow
        contributions - withdrawals
      end

      def total_income
        dividends + interest
      end
    end

    HoldingAllocation = Data.define(:security, :amount, :weight, :trend) do
      def ticker = security.ticker
      def name = security.name.presence || ticker
      def amount_money = amount
    end

    AllocationSegment = Data.define(:id, :name, :amount, :weight)

    # Each account's holdings plus its cash, by the rule every other grouping
    # files cash by. Not Account#balance: an account below its holdings (margin,
    # or a stale zero balance) would otherwise show less than it holds, or drop
    # out of the grouping altogether.
    def allocation_by_account
      cash = positive_account_cash.to_h { |account, value| [ account.id, value ] }
      segments = investment_accounts.map do |account|
        [ account.id, account.name, account_holdings_totals[account.id] + cash.fetch(account.id, 0) ]
      end
      build_segments(segments)
    end

    # Value by the currency each holding is priced in, plus each account's
    # cash (`positive_account_cash`) in the account's currency. Reads
    # `allocatable_holdings` so a corrupt negative row cannot net against a good
    # one here while the drill-down below drops it.
    def allocation_by_currency
      grouped = Hash.new(0)
      allocatable_holdings.each { |holding| grouped[holding.currency] += convert_to_report_currency(holding.amount, holding.currency) }
      positive_account_cash.each { |account, value| grouped[account.currency] += value }
      build_segments(grouped.map { |currency, value| [ currency, currency, value ] })
    end

    # Value by what kind of instrument each holding is -- cash, crypto or a
    # standard security -- from the security's own flags, with each account's
    # cash (`positive_account_cash`) under cash. Reads `allocatable_holdings` for the
    # same reason as `allocation_by_currency`.
    def allocation_by_kind
      grouped = Hash.new(0)
      allocatable_holdings.each do |holding|
        kind = if holding.security.cash? then "cash"
        elsif holding.security.crypto? then "crypto"
        else "standard"
        end
        grouped[kind] += convert_to_report_currency(holding.amount, holding.currency)
      end
      grouped["cash"] += account_cash_total if account_cash_total.positive?
      build_segments(grouped.map { |kind, value| [ kind, kind, value ] })
    end

    # One shape for all four classification groupings: read the column off the
    # security, fall back to UNCLASSIFIED, and place each account's cash
    # (`positive_account_cash`) where that grouping says it belongs.
    #
    # `cash_bucket` is the argument that matters. Cash is not a holding -- it
    # sits on the account -- so every grouping has to say where it goes, and
    # the honest answer differs. A cash balance IS liquidity, and IS cash as a
    # sub-class. It has no sector and no region, so for those it falls to
    # UNCLASSIFIED rather than being invented into someone's slice.
    def allocation_by_classification(column, cash_bucket: nil)
      grouped = Hash.new(0)

      allocatable_holdings.each do |holding|
        value = convert_to_report_currency(holding.amount, holding.currency)
        grouped[classification_bucket(holding.security, column, cash_bucket)] += value
      end

      grouped[cash_bucket || UNCLASSIFIED] += account_cash_total if account_cash_total.positive?

      build_segments(grouped.map { |bucket, value| [ bucket, bucket, value ] })
    end

    # Sub-classes inside one asset class. Cash is carried here too: it belongs
    # to `liquidity`/`cash`, so expanding Liquidity has to show it rather than
    # an empty list that contradicts the parent row's amount.
    def allocation_sub_classes_within(asset_class)
      grouped = Hash.new(0)

      holdings_classified_as(:asset_class, asset_class, CASH_ASSET_CLASS).each do |holding|
        bucket = classification_bucket(holding.security, :asset_sub_class, CASH_SUB_CLASS)
        grouped[bucket] += convert_to_report_currency(holding.amount, holding.currency)
      end

      grouped[CASH_SUB_CLASS] += account_cash_total if asset_class == CASH_ASSET_CLASS && account_cash_total.positive?

      build_segments(grouped.map { |bucket, value| [ bucket, bucket, value ] })
    end

    # The bottom of the ladder. Named by security so the row reads as a position
    # rather than as another bucket.
    #
    # It lists one row per security, summed in the report currency, and adds the
    # account cash the parent counts (`account_cash_rows`), so at every level a
    # bucket's positions sum to the bucket.
    def allocation_holdings_within(column, bucket, cash_bucket = nil, parent: nil)
      cash_rows = account_cash_rows(bucket, cash_bucket, parent)

      # One row per security: `current_holdings` has a row per account, so a
      # security held in several accounts, in any currencies, is summed here.
      grouped = Hash.new(0)
      names = {}
      holdings_classified_as(column, bucket, cash_bucket, parent: parent).each do |holding|
        grouped[holding.security_id] += convert_to_report_currency(holding.amount, holding.currency)
        names[holding.security_id] ||= holding.security.name.presence || holding.security.ticker
      end
      build_segments(grouped.map { |id, value| [ id, names[id], value ] } + cash_rows)
    end

    # Account cash as a position of the cash bucket: ONE row, the sum over
    # accounts of each account's cash (balance less holdings) in the family
    # currency where it is positive -- the rule `allocation_sub_classes_within` and
    # `allocation_by_classification` count it by. It belongs to Liquidity/Cash
    # only, so any other bucket, or a cash sub-class reached from another asset
    # class, gets none.
    def account_cash_rows(bucket, cash_bucket, parent)
      return [] unless cash_bucket.present? && bucket == cash_bucket
      return [] unless parent.nil? || parent == CASH_ASSET_CLASS

      [ [ "cash", I18n.t("models.investment_statement.cash"), account_cash_total ] ]
    end

    # Each investment account with cash, and that cash in the report currency.
    # An account's cash is its balance less its allocatable holdings, each
    # converted on its own and then subtracted, kept only where positive. Every
    # allocation grouping and level counts account cash through this one rule,
    # so a parent bucket and the positions below it cannot disagree about it,
    # and no grouping counts a balance another grouping drops.
    #
    # Not Account#cash_balance. It can be absent (a manual or never-synced
    # account), or default to the whole balance when a provider sends no cash
    # figure (`Account::ProviderImportAdapter#update_balance`), which would
    # count the holdings twice. `Balance::BaseCalculator` derives an
    # investment account's cash the same way, so on synced data the two agree.
    # Per account, so one account's margin cannot net against another's cash.
    def positive_account_cash
      @positive_account_cash ||= investment_accounts.filter_map do |account|
        balance = convert_to_report_currency(account.balance.to_d, account.currency)
        cash = balance - account_holdings_totals[account.id]
        [ account, cash ] if cash.positive?
      end
    end

    # Each account's allocatable holdings in the report currency, by account id.
    def account_holdings_totals
      @account_holdings_totals ||= allocatable_holdings.each_with_object(Hash.new(0)) do |holding, totals|
        totals[holding.account_id] += convert_to_report_currency(holding.amount, holding.currency)
      end
    end

    def account_cash_total
      positive_account_cash.sum { |_, value| value }
    end

    # One rule for which bucket a holding falls in, shared by the grouping, the
    # drill-down and the filter, so the three cannot disagree.
    #
    # A cash security is answered from `cash?` rather than from its columns. A
    # non-primary-currency cash position is a real holding -- `Security.cash_for`
    # creates one per currency -- and its `asset_class` may be nil. Reading the
    # column alone would file the family's euros under Unclassified while the
    # account's own euro cash balance sat under Liquidity: two answers for the
    # same money on one chart.
    def classification_bucket(security, column, cash_bucket)
      return cash_bucket if security.cash? && cash_bucket.present?

      security.public_send(column).presence || UNCLASSIFIED
    end

    # The allocatable holdings filed under `bucket` for `column`, which is what
    # the bottom level lists. `parent`, when given, also requires the holding's
    # asset class to match, because a sub-class name such as `unclassified`
    # repeats across asset classes (see `allocation_children`).
    def holdings_classified_as(column, bucket, cash_bucket = nil, parent: nil)
      allocatable_holdings.select do |holding|
        classification_bucket(holding.security, column, cash_bucket) == bucket &&
          (parent.nil? || classification_bucket(holding.security, :asset_class, CASH_ASSET_CLASS) == parent)
      end
    end

    # The allocation ladder's holdings, filtered by the per-row rule
    # `holdings_rolled_up_by_security` applies: a negative amount is corrupt
    # data (`Holding::Materializer` writes through `upsert_all`, skipping
    # validation). It is applied before anything sums, so a level above cannot
    # net a negative row that the bottom level then drops.
    def allocatable_holdings
      @allocatable_holdings ||= current_holdings.select do |holding|
        convert_to_report_currency(holding.amount, holding.currency).positive?
      end
    end

    def build_segments(rows)
      rows = rows.reject { |_, _, value| value.nil? || value <= 0 }
      total = rows.sum { |_, _, value| value }
      return [] if total.zero?

      rows
        .sort_by { |_, _, value| -value }
        .map do |id, name, value|
          AllocationSegment.new(id: id.to_s, name: name, amount: Money.new(value, currency), weight: (value / total * 100).round(2))
        end
    end

    # One row of #holdings_table_rows: a security rolled up across the
    # accounts that hold it, in report currency.
    HoldingsTableRow = Data.define(
      :security, :positions, :accounts_count, :qty, :avg_cost, :amount, :weight,
      :unrealized, :day_change, :missing_cost_basis
    ) do
      def ticker = security.ticker
      def name = security.name.presence || ticker
      def amount_money = amount
    end

    # Builds one rolled-up row of the holdings table for `security`: the summed
    # quantity across `positions`, its average cost and unrealised return over
    # the positions whose basis is known, and its weight against the caller's
    # `total` -- which is chosen by #weight_denominator, not here.
    def build_holdings_table_row(security, value, positions, total)
      qty = positions.sum(&:qty)

      # Same rule as combined_holding_trend: the return covers the positions
      # whose cost basis is known, and a position is known when
      # Holding#avg_cost answers -- which includes the trade-history fallback,
      # preloaded for every holding by holdings_with_avg_costs. Reading
      # `cost_basis` directly instead would hide a return on this table that
      # top_holdings counts for the same security.
      known = positions.select(&:avg_cost)
      missing_cost_basis = known.size < positions.size

      cost = nil
      unrealized = nil
      known_qty = known.sum(&:qty)
      if known.any?
        cost = known.sum { |holding| convert_to_report_currency(holding.qty * holding.avg_cost.amount, holding.currency) }
        known_value = known.sum { |holding| convert_to_report_currency(holding.amount, holding.currency) }
        unrealized = Trend.new(current: Money.new(known_value, currency), previous: Money.new(cost, currency))
      end

      day_changes = positions.filter_map do |holding|
        trend = holding_day_change(holding)
        next unless trend
        [ convert_to_report_currency(trend.current.amount, holding.currency), convert_to_report_currency(trend.previous.amount, holding.currency) ]
      end
      day_change = if day_changes.any?
        Trend.new(
          current: Money.new(day_changes.sum(&:first), currency),
          previous: Money.new(day_changes.sum(&:last), currency)
        )
      end

      HoldingsTableRow.new(
        security: security,
        positions: positions,
        accounts_count: positions.map(&:account_id).uniq.size,
        qty: qty,
        avg_cost: (cost && known_qty.positive?) ? Money.new(cost / known_qty, currency) : nil,
        amount: Money.new(value, currency),
        weight: total.zero? ? 0 : (value / total * 100).round(2),
        unrealized: unrealized,
        day_change: day_change,
        missing_cost_basis: missing_cost_basis
      )
    end

    def sort_holdings_table_rows(rows, sort:, dir:)
      sort = HOLDINGS_SORT_KEYS.include?(sort.to_s) ? sort.to_s : "value"
      dir = HOLDINGS_SORT_DIRECTIONS.include?(dir.to_s) ? dir.to_s : "desc"

      # Rows without the sorted figure go last whichever direction is asked.
      # Ties break by name, then security id, in both directions, so rows with
      # the same figure keep their order between requests.
      present, absent = rows.partition { |row| sort_key_present?(row, sort) }
      present = present.sort do |a, b|
        order = sort_value(a, sort) <=> sort_value(b, sort)
        order = -order if dir == "desc"
        order.nonzero? || (tiebreak(a) <=> tiebreak(b))
      end
      present + absent.sort_by { |row| tiebreak(row) }
    end

    def tiebreak(row)
      [ row.name.downcase, row.security.id.to_s ]
    end

    def sort_value(row, sort)
      case sort
      when "value" then row.amount.amount
      when "weight" then row.weight
      when "return" then row.unrealized.value.amount
      when "day_change" then row.day_change.value.amount
      when "name" then row.name.downcase
      end
    end

    def sort_key_present?(row, sort)
      case sort
      when "return" then row.unrealized.present?
      when "day_change" then row.day_change.present?
      else true
      end
    end

    # Groups current holdings by security and sums family-currency value.
    # Returns [[security, value, holdings], ...] sorted by value descending.
    # Callers that need return trends should call combined_holding_trend only
    # for rows they will render (e.g. after top_holdings applies its limit).
    # Shared by top_holdings and allocation so one security cannot report two
    # different percentages.
    #
    # max(portfolio_value, holdings_total) rather than portfolio_value alone:
    # portfolio_value includes cash, which goes negative on margin or an
    # unsettled buy and would push a weight past 100%. The holdings total acts
    # as a floor. It also covers a stale-zero portfolio_value, where the cached
    # Account#balance lags behind the Holding rows.
    def weight_denominator(holdings_total)
      [ portfolio_value, holdings_total ].max
    end

    # Memoized: top_holdings, allocation and holdings_table_rows all start
    # here, and the grouping and FX conversion need only run once per instance.
    def holdings_rolled_up_by_security
      @holdings_rolled_up_by_security ||= holdings_with_avg_costs
        .group_by(&:security_id)
        .filter_map do |_security_id, holdings|
          # Filter row by row rather than on the netted total. current_holdings
          # is DISTINCT ON (account_id, security_id), so one security held in two
          # accounts yields two rows; a negative row in one would otherwise net
          # against the good row in the other and understate the position.
          positive_holdings = holdings.select do |holding|
            convert_to_report_currency(holding.amount, holding.currency).positive?
          end
          next if positive_holdings.empty?

          security = positive_holdings.first.security
          value = positive_holdings.sum { |h| convert_to_report_currency(h.amount, h.currency) }

          # positive_holdings, not holdings, so the trend excludes the bad row too.
          [ security, value, positive_holdings ]
        end
        .sort_by { |_, value, _| -value }
    end

    def combined_holding_trend(holdings)
      currents = []
      previouses = []

      holdings.each do |holding|
        trend = holding.trend
        next unless trend

        currents << convert_to_report_currency(trend.current, holding.currency)
        previouses << convert_to_report_currency(trend.previous, holding.currency)
      end

      return nil if currents.empty?

      Trend.new(
        current: Money.new(currents.sum, currency),
        previous: Money.new(previouses.sum, currency)
      )
    end

    def investment_account_ids
      @investment_account_ids ||= investment_accounts.pluck(:id)
    end

    def totals_query(account_ids:, date_range:)
      if account_ids.empty?
        return Totals.new(family, account_ids: account_ids, date_range: date_range).call
      end

      account_ids_hash = Digest::MD5.hexdigest(account_ids.sort.join(","))

      Rails.cache.fetch([
        "investment_statement", "totals_query/v2", family.id, user&.id, currency,
        account_ids_hash, date_range.begin, date_range.end, family.entries_cache_version
      ]) { Totals.new(family, account_ids: account_ids, date_range: date_range).call }
    end

    def monetizable_currency
      currency
    end
end
