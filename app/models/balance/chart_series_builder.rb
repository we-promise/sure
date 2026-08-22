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

  private
    attr_reader :account_ids, :currency, :period, :favorable_direction, :account_active_until_dates

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
