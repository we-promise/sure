class Balance::ChartSeriesBuilder
  def initialize(account_ids:, currency:, period: Period.last_30_days, interval: nil,
                 favorable_direction: "up", account_active_until_dates: {})
    @account_ids = account_ids
    @currency = currency
    @period = period
    @interval = interval
    @favorable_direction = favorable_direction
    @account_active_until_dates = account_active_until_dates.compact
      .transform_keys(&:to_s)
      .transform_values { |date| date.to_date.iso8601 }
  end

  def balance_series
    build_series_for(:end_balance)
  rescue => e
    Rails.logger.error "Balance series error: #{e.message} for accounts #{@account_ids}"
    raise
  end

  def cash_balance_series
    build_series_for(:end_cash_balance)
  rescue => e
    Rails.logger.error "Cash balance series error: #{e.message} for accounts #{@account_ids}"
    raise
  end

  def holdings_balance_series
    build_series_for(:end_holdings_balance)
  rescue => e
    Rails.logger.error "Holdings balance series error: #{e.message} for accounts #{@account_ids}"
    raise
  end

  # Unrealized gains series: for each date, sum of (market value - cost basis) across
  # the latest holding snapshot per security. Holdings without a usable cost basis
  # (nil, or unlocked zero from providers) contribute a gain of 0.
  def gains_series
    values = gains_query_data.map do |datum|
      Series::Value.new(
        date: datum.date,
        date_formatted: I18n.l(datum.date, format: :long),
        value: Money.new(datum.end_gains, currency),
        trend: Trend.new(
          current: Money.new(datum.end_gains, currency),
          previous: Money.new(datum.start_gains, currency),
          favorable_direction: favorable_direction
        )
      )
    end

    Series.new(
      start_date: period.start_date,
      end_date: period.end_date,
      interval: interval,
      values: values,
      favorable_direction: favorable_direction
    )
  rescue => e
    Rails.logger.error "Gains series error: #{e.message} for accounts #{@account_ids}"
    raise
  end

  # Net contributions series: for each date of the balance series, what
  # the owner has put into these accounts so far, net of what they took out.
  #
  # Inception-anchored, not period-anchored: it starts from the opening value
  # of the accounts' first balance row and adds every external flow up to the
  # date, however early the period starts. What counts as external is decided
  # by Portfolio::FlowClassifier with these accounts as the scope, read
  # through Portfolio::DailyReturns so a flow is valued exactly as the returns
  # engine values it: a deposit at its cash amount, a security journalled in
  # at the position's value, a foreign-currency flow at the previous day's
  # rate. Dividends, interest, fees, buys and sells are not external, so
  # they never move this line.
  #
  # `anchor_date` is for a series whose value line starts later than its
  # first balance row (a linked investment account trimmed to supported
  # history): the line then opens at that day's closing value and adds only
  # the flows after it, so both lines start from the same point.
  #
  # `dates` defaults to the balance series' own dates; a caller whose value
  # line was reshaped after the query (Account::Chartable) passes that line's
  # dates so the two are drawn on the same points.
  #
  # Dates before the accounts' first balance read zero, as the value line does.
  #
  # Accounts that hold trades are assets, so no sign is applied here; the
  # only caller draws this line for them alone (UI::Account::Chart).
  def net_contributions_series(anchor_date: nil, dates: nil)
    dates = (dates || query_data.map(&:date)).sort
    cumulative = net_contributions_by_date(anchor_date: anchor_date, through: dates.max).to_h

    previous = nil
    values = dates.map do |date|
      amount = cumulative.fetch(date, 0)
      money = Money.new(amount, currency)
      value = Series::Value.new(
        date: date,
        date_formatted: I18n.l(date, format: :long),
        value: money,
        trend: Trend.new(current: money, previous: previous || money, favorable_direction: favorable_direction)
      )
      previous = money
      value
    end

    Series.new(
      start_date: period.start_date,
      end_date: period.end_date,
      interval: interval,
      values: values,
      favorable_direction: favorable_direction
    )
  rescue => e
    Rails.logger.error "Net contributions series error: #{e.message} for accounts #{@account_ids}"
    raise
  end

  # True when a flow the line counts could not be valued, so the line is
  # understated by it from that day on. The returns engine reads the same
  # two conditions: a flow in a currency with no rate (`rate_missing`)
  # and a journal with no price for its date. The second is read off
  # `suppressed`, which DailyReturns also sets for a non-positive
  # denominator, so a suppressed day with a positive denominator is the
  # unpriced journal.
  def net_contributions_understated?(anchor_date: nil, dates: nil)
    dates = (dates || query_data.map(&:date))
    counted_contribution_rows(anchor_date: anchor_date, through: dates.max).any? do |row|
      row.rate_missing || (row.suppressed && row.denominator.positive?)
    end
  end

  private
    attr_reader :account_ids, :currency, :period, :favorable_direction, :account_active_until_dates

    # [[date, cumulative amount], ...] for EVERY day from the anchor to
    # `through` (DailyReturns is always daily), so any sampled date in that
    # range has its own row. Empty when the accounts have no balances on or
    # before `through`.
    def net_contributions_by_date(anchor_date:, through:)
      rows, explicit_anchor = net_contribution_rows(anchor_date: anchor_date, through: through)
      return [] if rows.empty?

      first, *rest = rows
      running = if explicit_anchor
        first.value_close
      else
        first.value_open + first.external_flow + first.composition_flow
      end

      [ [ first.date, running ] ] + rest.map do |row|
        running += row.external_flow + row.composition_flow
        [ row.date, running ]
      end
    end

    # The rows whose flows the line adds: all of them, except the anchor
    # day's when an explicit anchor opens the line at that day's close.
    def counted_contribution_rows(anchor_date:, through:)
      rows, explicit_anchor = net_contribution_rows(anchor_date: anchor_date, through: through)
      explicit_anchor ? rows.drop(1) : rows
    end

    # DailyReturns rows from the anchor to `through`, and whether the anchor
    # was explicit. Memoized, so the series and the understated check share
    # one query.
    def net_contribution_rows(anchor_date:, through:)
      @net_contribution_rows ||= {}
      @net_contribution_rows[[ anchor_date, through ]] ||= begin
        first_date = first_balance_date
        explicit_anchor = first_date.present? && anchor_date.present? && anchor_date > first_date
        start_date = explicit_anchor ? anchor_date : first_date

        if start_date.nil? || through.nil? || start_date > through
          [ [], explicit_anchor ]
        else
          rows = Portfolio::DailyReturns.new(
            account_ids: account_ids,
            currency: currency,
            period: Period.custom(start_date: start_date, end_date: through),
            active_until_dates: account_active_until_dates
          ).rows
          [ rows, explicit_anchor ]
        end
      end
    end

    def first_balance_date
      Balance.joins(:account)
        .where(account_id: account_ids)
        .where("balances.currency = accounts.currency")
        .minimum(:date)
    end

    def interval
      @interval || period.interval
    end

    def build_series_for(column)
      values = query_data.map do |datum|
        # Map column names to their start equivalents
        previous_column = case column
        when :end_balance then :start_balance
        when :end_cash_balance then :start_cash_balance
        when :end_holdings_balance then :start_holdings_balance
        end

        Series::Value.new(
          date: datum.date,
          date_formatted: I18n.l(datum.date, format: :long),
          value: Money.new(datum.send(column), currency),
          trend: Trend.new(
            current: Money.new(datum.send(column), currency),
            previous: Money.new(datum.send(previous_column), currency),
            favorable_direction: favorable_direction
          )
        )
      end

      Series.new(
        start_date: period.start_date,
        end_date: period.end_date,
        interval: interval,
        values: values,
        favorable_direction: favorable_direction
      )
    end

    def query_data
      @query_data ||= Balance.find_by_sql([
        query,
        {
          account_ids: account_ids,
          target_currency: currency,
          start_date: period.start_date,
          end_date: period.end_date,
          interval: interval,
          sign_multiplier: sign_multiplier,
          account_active_until_dates_json: account_active_until_dates.to_json
        }
      ])
    rescue => e
      Rails.logger.error "Query data error: #{e.message} for accounts #{account_ids}, period #{period.start_date} to #{period.end_date}"
      raise
    end

    # Executes the gains query and memoizes the per-date rows
    # (date, end_gains, start_gains) used to build the gains series.
    def gains_query_data
      @gains_query_data ||= Balance.find_by_sql([
        gains_query,
        {
          account_ids: account_ids,
          target_currency: currency,
          start_date: period.start_date,
          end_date: period.end_date,
          interval: interval,
          account_active_until_dates_json: account_active_until_dates.to_json
        }
      ])
    rescue => e
      Rails.logger.error "Gains query data error: #{e.message} for accounts #{account_ids}, period #{period.start_date} to #{period.end_date}"
      raise
    end

    # Since the query aggregates the *net* of assets - liabilities, this means that if we're looking at
    # a single liability account, we'll get a negative set of values.  This is not what the user expects
    # to see.  When favorable direction is "down" (i.e. liability, decrease is "good"), we need to invert
    # the values by multiplying by -1.
    def sign_multiplier
      favorable_direction == "down" ? -1 : 1
    end

    def query
      <<~SQL
        WITH dates AS (
          SELECT generate_series(DATE :start_date, DATE :end_date, :interval::interval)::date AS date
          UNION DISTINCT
          SELECT :end_date::date  -- Ensure end date is included
        ),
        account_windows AS (
          SELECT
            account_window.account_id::uuid AS account_id,
            account_window.active_until_date::date AS active_until_date
          FROM jsonb_each_text(CAST(:account_active_until_dates_json AS jsonb))
            AS account_window(account_id, active_until_date)
        ),
        selected_accounts AS (
          SELECT accounts.*, account_windows.active_until_date
          FROM accounts
          LEFT JOIN account_windows ON account_windows.account_id = accounts.id
          WHERE accounts.id = ANY(array[:account_ids]::uuid[])
        )
        SELECT
          d.date,
          -- Use flows_factor: already handles asset (+1) vs liability (-1)
          COALESCE(SUM(last_bal.end_balance * last_bal.flows_factor * COALESCE(er.rate, 1) * :sign_multiplier::integer), 0) AS end_balance,
          COALESCE(SUM(last_bal.end_cash_balance * last_bal.flows_factor * COALESCE(er.rate, 1) * :sign_multiplier::integer), 0) AS end_cash_balance,
          -- Holdings only for assets (flows_factor = 1)
          COALESCE(SUM(
            CASE WHEN last_bal.flows_factor = 1
              THEN last_bal.end_non_cash_balance
              ELSE 0
            END * COALESCE(er.rate, 1) * :sign_multiplier::integer
          ), 0) AS end_holdings_balance,
          -- Previous balances
          COALESCE(SUM(last_bal.start_balance * last_bal.flows_factor * COALESCE(er.rate, 1) * :sign_multiplier::integer), 0) AS start_balance,
          COALESCE(SUM(last_bal.start_cash_balance * last_bal.flows_factor * COALESCE(er.rate, 1) * :sign_multiplier::integer), 0) AS start_cash_balance,
          COALESCE(SUM(
            CASE WHEN last_bal.flows_factor = 1
              THEN last_bal.start_non_cash_balance
              ELSE 0
            END * COALESCE(er.rate, 1) * :sign_multiplier::integer
          ), 0) AS start_holdings_balance
        FROM dates d
        LEFT JOIN selected_accounts accounts
          ON accounts.active_until_date IS NULL OR d.date <= accounts.active_until_date
        LEFT JOIN LATERAL (
          SELECT b.end_balance,
                 b.end_cash_balance,
                 b.end_non_cash_balance,
                 b.start_balance,
                 b.start_cash_balance,
                 b.start_non_cash_balance,
                 b.flows_factor
          FROM balances b
          WHERE b.account_id = accounts.id
            AND b.currency = accounts.currency
            AND b.date <= d.date
          ORDER BY b.date DESC
          LIMIT 1
        ) last_bal ON TRUE
        LEFT JOIN LATERAL (
          SELECT COALESCE(
            (SELECT er.rate
             FROM exchange_rates er
             WHERE er.from_currency = accounts.currency
               AND er.to_currency = :target_currency
               AND er.date <= d.date
             ORDER BY er.date DESC
             LIMIT 1),
            (SELECT er.rate
             FROM exchange_rates er
             WHERE er.from_currency = accounts.currency
               AND er.to_currency = :target_currency
               AND er.date > d.date
             ORDER BY er.date ASC
             LIMIT 1)
          ) AS rate
        ) er ON TRUE
        GROUP BY d.date
        ORDER BY d.date
      SQL
    end

    # Mirrors the balance query structure: for each date in the series, find the latest
    # holding snapshot per (account, security) on or before that date (LOCF), convert to
    # the target currency, and aggregate unrealized gains (amount - cost_basis * qty).
    # Holdings only exist on asset accounts, so no liability sign handling is needed.
    def gains_query
      <<~SQL
        WITH dates AS (
          SELECT generate_series(DATE :start_date, DATE :end_date, :interval::interval)::date AS date
          UNION DISTINCT
          SELECT :end_date::date  -- Ensure end date is included
        ),
        account_windows AS (
          SELECT
            account_window.account_id::uuid AS account_id,
            account_window.active_until_date::date AS active_until_date
          FROM jsonb_each_text(CAST(:account_active_until_dates_json AS jsonb))
            AS account_window(account_id, active_until_date)
        ),
        selected_accounts AS (
          SELECT accounts.*, account_windows.active_until_date
          FROM accounts
          LEFT JOIN account_windows ON account_windows.account_id = accounts.id
          WHERE accounts.id = ANY(array[:account_ids]::uuid[])
        ),
        account_securities AS (
          SELECT DISTINCT h.account_id, h.security_id
          FROM holdings h
          WHERE h.account_id = ANY(array[:account_ids]::uuid[])
        ),
        daily_gains AS (
          SELECT
            d.date,
            COALESCE(SUM(
              CASE
                WHEN last_basis.cost_basis IS NOT NULL
                THEN (last_h.amount - (last_basis.cost_basis * last_h.qty)) * COALESCE(er.rate, 1)
                ELSE 0
              END
            ), 0) AS gains
          FROM dates d
          LEFT JOIN selected_accounts accounts
            ON accounts.active_until_date IS NULL OR d.date <= accounts.active_until_date
          LEFT JOIN account_securities sec ON sec.account_id = accounts.id
          LEFT JOIN LATERAL (
            SELECT h.amount, h.qty, h.currency
            FROM holdings h
            WHERE h.account_id = accounts.id
              AND h.security_id = sec.security_id
              AND h.date <= d.date
            ORDER BY h.date DESC
            LIMIT 1
          ) last_h ON TRUE
          -- Cost basis is looked up separately from the latest row that has a usable one:
          -- gap-filled holding rows (weekends, price-history gaps) are persisted without
          -- cost_basis even though the position and basis are unchanged, so the basis is
          -- carried forward from the last real snapshot instead of zeroing those points.
          LEFT JOIN LATERAL (
            SELECT h2.cost_basis
            FROM holdings h2
            WHERE h2.account_id = accounts.id
              AND h2.security_id = sec.security_id
              AND h2.date <= d.date
              AND h2.cost_basis IS NOT NULL
              AND (h2.cost_basis_locked OR h2.cost_basis > 0)
            ORDER BY h2.date DESC
            LIMIT 1
          ) last_basis ON TRUE
          LEFT JOIN LATERAL (
            SELECT COALESCE(
              (SELECT er.rate
               FROM exchange_rates er
               WHERE er.from_currency = last_h.currency
                 AND er.to_currency = :target_currency
                 AND er.date <= d.date
               ORDER BY er.date DESC
               LIMIT 1),
              (SELECT er.rate
               FROM exchange_rates er
               WHERE er.from_currency = last_h.currency
                 AND er.to_currency = :target_currency
                 AND er.date > d.date
               ORDER BY er.date ASC
               LIMIT 1)
            ) AS rate
          ) er ON TRUE
          GROUP BY d.date
        )
        SELECT
          dg.date,
          dg.gains AS end_gains,
          COALESCE(LAG(dg.gains) OVER (ORDER BY dg.date), dg.gains) AS start_gains
        FROM daily_gains dg
        ORDER BY dg.date
      SQL
    end
end
