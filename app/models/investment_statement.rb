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
    # rows that will be rendered (avoids avg_cost/trade lookups for the rest).
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

  # Allocation of the portfolio grouped by a classification column of the
  # security. Each account's cash -- its balance less its holdings, positive
  # only (`positive_account_cash`) -- is placed where the grouping says cash
  # belongs, so every grouping and every level of the drill-down sums to the
  # same total, and weights sum to 100 within rounding. Segments are
  # sorted largest first. Amounts convert to the family currency at the latest
  # rate; a currency with no rate counts 1:1 (`convert_to_family_currency`).
  ALLOCATION_GROUPINGS = %w[asset_class asset_sub_class sector region].freeze

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
  # positions. Sector and region do not nest, so they return [].
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
    when "asset_class" then allocation_by_classification(:asset_class, cash_bucket: CASH_ASSET_CLASS)
    when "asset_sub_class" then allocation_by_classification(:asset_sub_class, cash_bucket: CASH_SUB_CLASS)
    when "sector" then allocation_by_classification(:sector)
    when "region" then allocation_by_classification(:region)
    else []
    end
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

  # Portfolio value (cash + holdings) over the period, in family currency.
  #
  # Charted from the *historical* account scope, so a disabled broker keeps its
  # history up to its cut-off date. The last point therefore diverges from
  # #portfolio_value (visible accounts only) whenever a disabled account still
  # carries a non-zero balance. See HistoricalScope for the rationale.
  def value_series(period: Period.last_30_days)
    fetch_series(:value, period) { |builder| builder.balance_series }
  end

  # Holdings-only value (portfolio value minus cash) over the period.
  def holdings_value_series(period: Period.last_30_days)
    fetch_series(:holdings_value, period) { |builder| builder.holdings_balance_series }
  end

  # Unrealized gains (market value minus cost basis) over the period.
  def gains_series(period: Period.last_30_days)
    fetch_series(:gains, period) { |builder| builder.gains_series }
  end

  def historical_scope
    @historical_scope ||= HistoricalScope.new(family, user: user)
  end

  # Day change across portfolio, summed in family currency
  def day_change
    changes = current_holdings.to_a.filter_map do |h|
      t = h.day_change
      next nil unless t
      curr = t.current.is_a?(Money) ? t.current.amount : t.current
      prev = t.previous.is_a?(Money) ? t.previous.amount : t.previous
      [
        convert_to_family_currency(curr, h.currency),
        convert_to_family_currency(prev, h.currency)
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
    # Two layers of caching, mirroring BalanceSheet::NetWorthSeriesBuilder:
    # Rails.cache across requests, plus a per-instance memo so a single
    # dashboard render that asks for the same series twice runs one query.
    #
    # Every series is trimmed to the first date any linked account in the
    # scope has history for: the balance rows before a broker's first snapshot
    # are zeros, and charting them shows a portfolio that appears from nothing
    # on the day the connection was made. The earliest start, not the common
    # one, so linking a new broker does not erase the history of an older
    # one, open or closed.
    def fetch_series(kind, period)
      @series_cache ||= {}
      @series_cache[[ kind, period.start_date, period.end_date ]] ||= Rails.cache.fetch(series_cache_key(kind, period)) do
        Balance::LinkedInvestmentSeriesNormalizer.trim_to_supported_history(
          yield(series_builder(period)),
          account_ids: historical_scope.account_ids,
          history_start: series_history_start
        )
      end
    end

    # The trim fetch_series applies, read by its cache key too, so a series
    # cached under one trim is never served under another.
    def series_history_start
      :earliest
    end

    def series_builder(period)
      Balance::ChartSeriesBuilder.new(
        account_ids: historical_scope.account_ids,
        account_active_until_dates: historical_scope.active_until_dates,
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )
    end

    # Beyond the family key (sync time and accounts.updated_at), the key
    # carries a version for each table the series reads that can change
    # without a sync or an account write:
    #
    # - shares (every kind): revoking a share deletes a row, which changes
    #   neither maximum(:updated_at) nor accounts.updated_at, and a key built
    #   from those alone would keep serving a series that still counts the
    #   revoked account.
    # - holdings (every kind): the gains series reads holdings.cost_basis,
    #   which a manual cost-basis edit, an unlock or a security remap
    #   rewrites in place. Every series is also trimmed to the supported
    #   history start, which provider holdings' dates and securities
    #   decide, so deleting or remapping a holding can move the value and
    #   holdings-value charts' first date without a sync.
    # - the family currency (every kind): every series is converted to it,
    #   and a profile currency change neither syncs nor writes an account.
    # - the accounts version (every kind): deleting an account with no
    #   holdings that was not the most recently updated one leaves
    #   maximum(:updated_at), the sync time and the holdings version where
    #   they were before its deletion was scheduled; only the count moves.
    # - the history trim (every kind): it decides the series' first point, and
    #   nothing else in the key moves when only the trim does.
    def series_cache_key(kind, period)
      key = [
        "investment_statement_#{kind}_series",
        "start-#{series_history_start}",
        user&.id,
        family.currency,
        accounts_version,
        shares_version,
        holdings_version,
        period.start_date,
        period.end_date
      ].compact.join("_")

      family.build_cache_key(key, invalidate_on_data_updates: true)
    end

    # Memoized: one instance builds a key per series kind it is asked for,
    # and the versions need not be re-queried between them.
    def accounts_version
      @accounts_version ||= family.accounts_status_version
    end

    def shares_version
      return nil unless user

      @shares_version ||= begin
        shares = AccountShare.where(user: user)
        "#{shares.count}-#{shares.maximum(:updated_at)&.to_f || 0}"
      end
    end

    # Count plus latest timestamp over the holdings the series can read, so a
    # cost-basis edit, unlock or remap (rows rewritten in place) and a
    # deletion (a row gone, timestamps unchanged) each move every series key.
    def holdings_version
      @holdings_version ||= begin
        # The provider-linked count covers an unlink, which clears
        # account_provider_id with update_all and leaves updated_at alone,
        # yet moves the supported-history trim that reads that column.
        count, linked, latest = Holding.where(account_id: historical_scope.account_ids)
          .pick(Arel.sql("COUNT(*), COUNT(account_provider_id), MAX(updated_at)"))
        "#{count}-#{linked}-#{latest&.to_f || 0}"
      end
    end

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

    AllocationSegment = Data.define(:id, :name, :amount, :weight)

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
        value = convert_to_family_currency(holding.amount, holding.currency)
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
        grouped[bucket] += convert_to_family_currency(holding.amount, holding.currency)
      end

      grouped[CASH_SUB_CLASS] += account_cash_total if asset_class == CASH_ASSET_CLASS && account_cash_total.positive?

      build_segments(grouped.map { |bucket, value| [ bucket, bucket, value ] })
    end

    # The bottom of the ladder. Named by security so the row reads as a position
    # rather than as another bucket.
    #
    # It lists one row per security, summed in the family currency, and adds the
    # account cash the parent counts (`account_cash_rows`), so at every level a
    # bucket's positions sum to the bucket.
    def allocation_holdings_within(column, bucket, cash_bucket = nil, parent: nil)
      cash_rows = account_cash_rows(bucket, cash_bucket, parent)

      # One row per security: `current_holdings` has a row per account, so a
      # security held in several accounts, in any currencies, is summed here.
      grouped = Hash.new(0)
      names = {}
      holdings_classified_as(column, bucket, cash_bucket, parent: parent).each do |holding|
        grouped[holding.security_id] += convert_to_family_currency(holding.amount, holding.currency)
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

    # Each investment account with cash, and that cash in the family currency.
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
        balance = convert_to_family_currency(account.balance.to_d, account.currency)
        cash = balance - account_holdings_totals[account.id]
        [ account, cash ] if cash.positive?
      end
    end

    # Each account's allocatable holdings in the family currency, by account id.
    def account_holdings_totals
      @account_holdings_totals ||= allocatable_holdings.each_with_object(Hash.new(0)) do |holding, totals|
        totals[holding.account_id] += convert_to_family_currency(holding.amount, holding.currency)
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
        convert_to_family_currency(holding.amount, holding.currency).positive?
      end
    end

    def build_segments(rows)
      rows = rows.reject { |_, _, value| value.nil? || value <= 0 }
      total = rows.sum { |_, _, value| value }
      return [] if total.zero?

      rows
        .sort_by { |_, _, value| -value }
        .map do |id, name, value|
          AllocationSegment.new(id: id.to_s, name: name, amount: Money.new(value, family.currency), weight: (value / total * 100).round(2))
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

    def holdings_rolled_up_by_security
      current_holdings
        .to_a
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
