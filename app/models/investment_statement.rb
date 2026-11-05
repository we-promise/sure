require "digest/md5"

class InvestmentStatement
  include Monetizable

  monetize :total_contributions, :total_dividends, :total_interest, :unrealized_gains

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user || Current.user
  end

  # Get totals for a specific period
  def totals(period: Period.current_month)
    account_ids = investment_account_ids

    result = totals_query(account_ids: account_ids, date_range: period.date_range)

    PeriodTotals.new(
      contributions: Money.new(result[:contributions], family.currency),
      withdrawals: Money.new(result[:withdrawals], family.currency),
      dividends: Money.new(result[:dividends], family.currency),
      interest: Money.new(result[:interest], family.currency),
      trades_count: result[:trades_count],
      currency: family.currency
    )
  end

  # Net contributions (contributions - withdrawals)
  def net_contributions(period: Period.current_month)
    t = totals(period: period)
    t.contributions - t.withdrawals
  end

  # Total portfolio value across all investment accounts
  def portfolio_value
    investment_accounts.sum { |a| convert_to_family_currency(a.balance, a.currency) }
  end

  def portfolio_value_money
    Money.new(portfolio_value, family.currency)
  end

  # Total cash in investment accounts
  def cash_balance
    investment_accounts.sum { |a| convert_to_family_currency(a.cash_balance, a.currency) }
  end

  def cash_balance_money
    Money.new(cash_balance, family.currency)
  end

  # Total holdings value
  def holdings_value
    portfolio_value - cash_balance
  end

  def holdings_value_money
    Money.new(holdings_value, family.currency)
  end

  # All current holdings across investment accounts. Holdings are returned in
  # their native currency; callers that aggregate across accounts must convert
  # to family currency via convert_to_family_currency.
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
  # to the holding (Holding.preload_avg_costs), so the roll-up's trends and
  # the holdings table do not run Holding#calculate_avg_cost's two queries
  # per holding. Memoized.
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
          amount: Money.new(value, family.currency),
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
        amount: Money.new(value, family.currency),
        weight: (value / total * 100).round(2),
        trend: combined_holding_trend(holdings)
      )
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
  # sort: one of HOLDINGS_SORT_KEYS; dir: "asc" or "desc". Anything else is
  # the default (value desc), so the query string cannot raise.
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

  # Unrealized gains across all holdings, summed in family currency
  def unrealized_gains
    current_holdings.sum do |holding|
      trend = holding.trend
      trend ? convert_to_family_currency(trend.value, holding.currency) : 0
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
    holdings = current_holdings.to_a
    return nil if holdings.empty?

    # Only include holdings with known cost basis in the calculation
    holdings_with_cost_basis = holdings.select(&:avg_cost)
    return nil if holdings_with_cost_basis.empty?

    current = holdings_with_cost_basis.sum do |h|
      convert_to_family_currency(h.amount, h.currency)
    end
    previous = holdings_with_cost_basis.sum do |h|
      convert_to_family_currency(h.qty * h.avg_cost.amount, h.currency)
    end

    Trend.new(
      current: Money.new(current, family.currency),
      previous: Money.new(previous, family.currency)
    )
  end

  def period_return_trend(period: Period.current_month)
    currency = family.currency
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

  # The snapshot before each current holding, keyed by [account_id,
  # security_id]: the latest row for the same account, security and currency
  # dated before the current row, which is what Holding#day_change compares
  # against. One query for every holding rather than one per holding, so a
  # page that lists every position does not issue a query per row. Memoized
  # like current_holdings.
  def previous_holdings
    @previous_holdings ||= begin
      current_ids = current_holdings.map(&:id)

      if current_ids.any?
        Holding
          .joins(ActiveRecord::Base.sanitize_sql_array([
            <<~SQL.squish,
              JOIN holdings current_holdings
                ON current_holdings.id IN (:current_ids)
                AND current_holdings.account_id = holdings.account_id
                AND current_holdings.security_id = holdings.security_id
                AND current_holdings.currency = holdings.currency
                AND holdings.date < current_holdings.date
            SQL
            { current_ids: current_ids }
          ]))
          .select("DISTINCT ON (holdings.account_id, holdings.security_id) holdings.*")
          .order(Arel.sql("holdings.account_id, holdings.security_id, holdings.date DESC"))
          .index_by { |holding| [ holding.account_id, holding.security_id ] }
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

    previous = previous_holdings[[ holding.account_id, holding.security_id ]]
    return nil unless previous&.amount_money

    Trend.new(current: holding.amount_money, previous: previous.amount_money)
  end

  # Day change across portfolio, summed in family currency
  def day_change
    changes = current_holdings.to_a.filter_map do |h|
      t = holding_day_change(h)
      next nil unless t
      [
        convert_to_family_currency(t.current.amount, h.currency),
        convert_to_family_currency(t.previous.amount, h.currency)
      ]
    end

    return nil if changes.empty?

    Trend.new(
      current: Money.new(changes.sum { |c, _| c }, family.currency),
      previous: Money.new(changes.sum { |_, p| p }, family.currency)
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
                    .reject { |c| c == family.currency }
        ExchangeRate.rates_for(foreign, to: family.currency, date: Date.current)
      end
    end

    # Unwrap Money first because this codebase's Money (lib/money.rb) ignores
    # the currency arg of `Money.new` when the payload is already a Money, and
    # `Money * numeric` preserves the source currency — so multiplying a
    # foreign-currency Money by a rate would FX-scale the amount but keep the
    # wrong currency label, corrupting downstream sums.
    def convert_to_family_currency(amount, from_currency)
      return amount if amount.nil?
      numeric = amount.is_a?(Money) ? amount.amount : amount
      return numeric if from_currency == family.currency
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

    # One row of #holdings_table_rows: a security rolled up across the
    # accounts that hold it, in family currency.
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
        cost = known.sum { |holding| convert_to_family_currency(holding.qty * holding.avg_cost.amount, holding.currency) }
        known_value = known.sum { |holding| convert_to_family_currency(holding.amount, holding.currency) }
        unrealized = Trend.new(current: Money.new(known_value, family.currency), previous: Money.new(cost, family.currency))
      end

      day_changes = positions.filter_map do |holding|
        trend = holding_day_change(holding)
        next unless trend
        [ convert_to_family_currency(trend.current.amount, holding.currency), convert_to_family_currency(trend.previous.amount, holding.currency) ]
      end
      day_change = if day_changes.any?
        Trend.new(
          current: Money.new(day_changes.sum(&:first), family.currency),
          previous: Money.new(day_changes.sum(&:last), family.currency)
        )
      end

      HoldingsTableRow.new(
        security: security,
        positions: positions,
        accounts_count: positions.map(&:account_id).uniq.size,
        qty: qty,
        avg_cost: (cost && known_qty.positive?) ? Money.new(cost / known_qty, family.currency) : nil,
        amount: Money.new(value, family.currency),
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
      present, absent = rows.partition { |row| sort_key_present?(row, sort) }
      present = present.sort_by { |row| sort_value(row, sort) }
      present.reverse! if dir == "desc"
      present + absent
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
            convert_to_family_currency(holding.amount, holding.currency).positive?
          end
          next if positive_holdings.empty?

          security = positive_holdings.first.security
          value = positive_holdings.sum { |h| convert_to_family_currency(h.amount, h.currency) }

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

        currents << convert_to_family_currency(trend.current, holding.currency)
        previouses << convert_to_family_currency(trend.previous, holding.currency)
      end

      return nil if currents.empty?

      Trend.new(
        current: Money.new(currents.sum, family.currency),
        previous: Money.new(previouses.sum, family.currency)
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
        "investment_statement", "totals_query/v2", family.id, user&.id, family.currency,
        account_ids_hash, date_range.begin, date_range.end, family.entries_cache_version
      ]) { Totals.new(family, account_ids: account_ids, date_range: date_range).call }
    end

    def monetizable_currency
      family.currency
    end
end
