# The daily return series a set of accounts produced over a period, in the
# family's currency.
#
# Division of labour: the database does the joining, windowing
# and FX -- what it is good at -- and returns raw components. The arithmetic that
# has to be exact and auditable happens here in BigDecimal, where it can be unit
# tested without a fixture round-trip. Computing `r_t` inside a CASE expression
# would bury the flow convention in SQL and make it a query edit.
#
# The query is always DAILY regardless of what interval a chart eventually
# displays: chaining at a coarser interval silently changes the answer
# whenever a flow lands mid-interval.
#
# CURRENCY DECOMPOSITION. Each day's change in family-currency value is
# split exactly:
#
#   ΔV(t) = r(t-1)·ΔA(t)  +  A_end(t)·Δr(t)
#           \___local___/    \____fx_____/
#
# so every local component (flows, market, revaluations) is converted at the
# PREVIOUS day's rate and the fx term is the closing local balance times the
# rate change. That identity is what lets Portfolio::Drivers report a genuine
# `unexplained` residual instead of defining one away.
class Portfolio::DailyReturns
  # One day. `r` is nil until #returns computes it, so a caller reading rows
  # directly cannot mistake a raw component for a return.
  Row = Data.define(
    :date, :value_open, :value_close, :external_flow, :composition_flow,
    :income, :fees, :market, :revaluations, :fx_effect,
    :rate_missing, :suppressed
  ) do
    # Flows are start-of-day: the day's start-of-day capital is the opening value plus every
    # flow that joined it -- external flows, and the value an account brought
    # into or carried out of the scope.
    def denominator
      value_open + external_flow + composition_flow
    end

    # Zero or negative denominators are suppressed rather than inverted.
    # `suppressed` is the answer to "does this day contribute a return?", so it
    # is what #returns must consult.
    def computable?
      !suppressed && denominator.positive?
    end

    def change
      value_close - value_open
    end

    # What the named components do not account for. Zero for an ordinary day,
    # and zero when an account enters or leaves the scope, because that is
    # described as a composition flow. Non-zero only when the value moved for a reason
    # no driver records.
    def unexplained
      change - (external_flow + composition_flow + income - fees + market + revaluations + fx_effect)
    end
  end

  # Where a fragment built elsewhere goes in the query; see #bind_and_splice.
  # A comment with no colon, so sanitize_sql_array passes over it. The bound
  # values (ids, dates, a currency code) cannot spell one.
  FRAGMENT_MARKER = %r{/\* fragment (\w+) \*/}

  attr_reader :account_ids, :currency, :period, :active_until_dates

  # The flow classifier's "inside" is `account_ids` itself: a scope is
  # external to everything it does not contain (see Portfolio::FlowClassifier).
  #
  # Deliberately not a separate, wider set. Classifying against accounts the
  # series does not value makes a transfer to one of them internal, so it
  # leaves the denominator alone while the money leaves the close, and the
  # source account's drop reads as a loss.
  #
  # Asset accounts only. The levels are multiplied by flows_factor, but the
  # flows (-entries.amount, a journal's value) are not, so on a liability they
  # would carry the wrong sign against its balance and nothing would flag it.
  # A liability is refused when the series is first queried (see
  # #refuse_liabilities!), so building one stays free for a caller that only
  # reads its attributes.
  def initialize(account_ids:, currency:, period:, active_until_dates: {})
    @account_ids = Array(account_ids).compact.map(&:to_s)
    @currency = currency
    @period = period
    @active_until_dates = (active_until_dates || {}).compact
      .transform_keys(&:to_s)
      .transform_values { |date| date.to_date.iso8601 }
  end

  # Every day in the period, with its raw components. Empty when no accounts.
  def rows
    @rows ||= begin
      return [] if account_ids.empty?

      previous_close = nil

      raw_rows.map do |raw|
        value_close = decimal(raw["value_close"])

        # The opening value is the previous day's close. On the first day of
        # the period there is no previous row, so the balance row's own
        # start_balance is used -- converted at the previous day's rate, which is
        # what makes it equal to the prior close by construction.
        value_open = previous_close || decimal(raw["value_open"])
        previous_close = value_close

        # A change in what the scope CONTAINS is a flow, not a return.
        #
        # An account arriving mid-period appears in value_close with nothing in
        # value_open, and an account passing its active_until_date drops out of
        # value_close while value_open still carries yesterday's close. Read as a
        # return, the first is a gain of the whole arriving balance and the
        # second a loss of the whole departing one.
        #
        # So both join the day's start-of-day capital, exactly as a deposit or a
        # withdrawal would: the value that arrived is added, the value that
        # left is taken away, and the rest of the scope's genuine return that day
        # survives. An empty account arriving or leaving carries zero and changes
        # nothing. See arrivals_by_date and departures_by_date in #query.
        composition_flow = decimal(raw["arrived_value"]) - decimal(raw["departed_value"])
        external_flow = decimal(raw["external_flow"])
        denominator = value_open + external_flow + composition_flow

        Row.new(
          date: raw["date"].to_date,
          value_open: value_open,
          value_close: value_close,
          external_flow: external_flow,
          composition_flow: composition_flow,
          income: decimal(raw["income"]),
          fees: decimal(raw["fees"]),
          market: decimal(raw["market"]),
          revaluations: decimal(raw["revaluations"]),
          fx_effect: decimal(raw["fx_effect"]),
          rate_missing: raw["rate_missing"] == true,
          # Same rule as a non-positive denominator: a day carrying a journal that
          # could not be valued is suppressed rather than returned. Its flow is
          # missing from the denominator while its value is present in the
          # close, so the day would read as return the portfolio did not earn.
          suppressed: !denominator.positive? || raw["journal_unpriced"] == true
        )
      end
    end
  end

  # [[date, r_t], ...] in BigDecimal. Suppressed days contribute a return of
  # zero and stay in the series so the calendar is unbroken.
  def returns
    @returns ||= rows.map do |row|
      r = if row.computable?
        (row.value_close / row.denominator) - 1
      else
        BigDecimal(0)
      end

      [ row.date, r ]
    end
  end

  # Days whose return was suppressed. Surfaced rather than hidden so
  # the UI can say why a figure is not what a user expects.
  def suppressed_rows
    rows.select(&:suppressed)
  end

  # True when an account that actually held a balance, or a flow that
  # feeds a figure, had no rate to the family currency. Scoped to contributing
  # accounts deliberately: an empty
  # foreign account a user has added but not yet synced contributes nothing to
  # any figure, and must not blank the whole portfolio's performance.
  def rate_missing?
    rows.any?(&:rate_missing)
  end

  def any?
    rows.any?
  end

  private
    def decimal(value)
      return BigDecimal(0) if value.nil?
      BigDecimal(value.to_s)
    end

    def raw_rows
      ActiveRecord::Base.connection.select_all(bind_and_splice(query)).to_a
    end

    # Only this class's own template goes through sanitize_sql_array. Rails
    # reads every `:word` in the string it is handed as a bind variable, so the
    # classifier's SQL -- already sanitized, and full of quoted labels -- would
    # raise there if a label or literal ever carried one (see
    # Portfolio::FlowClassifier#classify_ids). The template holds a marker
    # where each fragment belongs, and the fragment replaces it after the binds
    # are filled, so it is never scanned.
    def bind_and_splice(template)
      refuse_liabilities!

      ActiveRecord::Base.sanitize_sql_array([ template, query_binds ])
        .gsub(FRAGMENT_MARKER) { fragments.fetch(Regexp.last_match(1)) }
    end

    # Every query this class runs goes through #bind_and_splice, so checking
    # here covers each figure it can return. Once per instance.
    def refuse_liabilities!
      @liabilities_refused ||= begin
        if Account.where(id: account_ids, classification: "liability").exists?
          raise ArgumentError, "Portfolio::DailyReturns reads asset accounts only; liabilities are not supported"
        end
        true
      end
    end

    def fragment(name)
      "/* fragment #{name} */"
    end

    def fragments
      @fragments ||= {
        "flow_class_sql" => flow_classifier.sql_case,
        "flow_class_joins" => flow_classifier.sql_joins,
        "journal_predicate" => journal_predicate,
        "entry_custom_rate" => entry_custom_rate_sql
      }
    end

    def query_binds
      {
        account_ids: account_ids,
        target_currency: currency,
        start_date: period.start_date,
        end_date: period.end_date,
        active_until_json: active_until_dates.to_json
      }
    end

    # Mirrors Balance::ChartSeriesBuilder's structure deliberately: the same
    # LATERAL LOCF over balances, the same two-way LOCF over exchange_rates, and
    # the same active-until windowing. The FX half is why -- the older pattern in
    # InvestmentStatement#period_return_trend joins `er.date = b.date` and
    # COALESCEs a miss to 1, silently converting at parity on every weekend and
    # holiday.
    def query
      <<~SQL
        WITH dates AS (
          SELECT generate_series(DATE :start_date, DATE :end_date, '1 day'::interval)::date AS date
        ),
        account_windows AS (
          SELECT
            account_window.account_id::uuid AS account_id,
            account_window.active_until_date::date AS active_until_date
          FROM jsonb_each_text(CAST(:active_until_json AS jsonb))
            AS account_window(account_id, active_until_date)
        ),
        scoped_accounts AS (
          SELECT accounts.id, accounts.currency, account_windows.active_until_date
          FROM accounts
          LEFT JOIN account_windows ON account_windows.account_id = accounts.id
          WHERE accounts.id = ANY(array[:account_ids]::uuid[])
        ),
        -- The value an account carried OUT of the scope, keyed by the day
        -- after its cut-off -- the first day value_close excludes it while
        -- value_open still carries yesterday's close. It is a composition
        -- outflow on that day, so it is signed: its closing balance in family
        -- currency, converted at the cut-off date's rate, which is the previous
        -- day's rate relative to the departure day. An account holding
        -- nothing carries out zero and changes nothing.
        --
        -- Cut-offs before the period's first day are excluded: value_open is
        -- read from the query itself there, and it already excludes an account
        -- that was out of window before the period began, so nothing departs.
        --
        -- A departure whose rate is missing sums to NULL and reads as zero here.
        -- That is safe rather than silent: the account was in window the day
        -- before, so the same missing rate has already raised Row#rate_missing
        -- and Portfolio::Performance withholds every ratio.
        departures_by_date AS (
          SELECT
            (sa.active_until_date + 1)::date AS date,
            COALESCE(SUM(lb.end_balance * lb.flows_factor * er.rate), 0) AS departed_value
          FROM scoped_accounts sa
          LEFT JOIN LATERAL (
            SELECT b.end_balance, b.flows_factor
            FROM balances b
            WHERE b.account_id = sa.id
              AND b.currency = sa.currency
              AND b.date <= sa.active_until_date
            ORDER BY b.date DESC
            LIMIT 1
          ) lb ON TRUE
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('sa.currency', 'sa.active_until_date')} AS rate
          ) er ON TRUE
          WHERE sa.active_until_date IS NOT NULL
            AND sa.active_until_date >= DATE :start_date
          GROUP BY sa.active_until_date
        ),
        -- The value an account brought INTO the scope, keyed by the date of
        -- its first balance row. The balance calculators write that row with
        -- the opening position as its start_balance -- the forward calculator
        -- seeds from the opening anchor, the reverse calculator carries the
        -- anchor's total, and without an anchor derives the start backwards
        -- from the current balance -- so start_balance is the value that
        -- arrived. It joins the day's start-of-day capital, converted at the
        -- previous day's rate like every start-of-day flow.
        --
        -- Only a first row AFTER the period's first day is an arrival. A first
        -- row on the first day already reaches value_open through its own
        -- start_balance, and counting it here as well would double it. A first
        -- row after the account's cut-off never enters the scope.
        --
        -- A missing rate reads as zero here, safely: rate_lookup falls back to
        -- the earliest rate after the date, so NULL means the pair has no rate
        -- at all, and the arriving account's own balance has already raised
        -- Row#rate_missing, so Portfolio::Performance withholds every ratio.
        arrivals_by_date AS (
          SELECT
            fb.date,
            COALESCE(SUM(fb.start_balance * fb.flows_factor * ar.rate), 0) AS arrived_value
          FROM scoped_accounts sa
          JOIN LATERAL (
            SELECT b.date, b.start_balance, b.flows_factor
            FROM balances b
            WHERE b.account_id = sa.id
              AND b.currency = sa.currency
            ORDER BY b.date ASC
            LIMIT 1
          ) fb ON TRUE
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('sa.currency', 'fb.date - 1')} AS rate
          ) ar ON TRUE
          WHERE fb.date > DATE :start_date
            AND fb.date <= DATE :end_date
            AND (sa.active_until_date IS NULL OR fb.date <= sa.active_until_date)
          GROUP BY fb.date
        ),
        balances_by_date AS (
          SELECT
            d.date,
            -- flows_factor is +1 for assets and -1 for liabilities. The series
            -- refuses liabilities, so this is an identity here; it is applied
            -- anyway so the expression matches the chart series builder.
            COALESCE(SUM(lb.end_balance * lb.flows_factor * er.rate), 0) AS value_close,
            -- The opening level, which is only read for the FIRST day of the
            -- period (#rows carries the previous close afterwards).
            --
            -- A row dated on this day gives its own start_balance. A row
            -- CARRIED FORWARD from before the period is a level that was
            -- already reached, so its END balance is the opening value here.
            -- Reading its start_balance instead re-reported that historical
            -- day's change as a return on the period's first day, and left the
            -- difference in Row#unexplained.
            COALESCE(SUM(CASE WHEN lb.date < d.date THEN lb.end_balance ELSE lb.start_balance END
                         * lb.flows_factor * prev_er.rate), 0) AS value_open,
            -- Components come from a balance row dated EXACTLY on this day, not
            -- from the carried-forward one. LOCF is right for a level and wrong
            -- for a flow: re-reading yesterday's net_market_flows on every day
            -- of a gap would multiply the market driver by the gap's length.
            COALESCE(SUM(tb.net_market_flows * tb.flows_factor * prev_er.rate), 0) AS market,
            COALESCE(SUM((tb.cash_adjustments + tb.non_cash_adjustments)
                         * tb.flows_factor * prev_er.rate), 0) AS revaluations,
            -- The fx half of the identity in this class's header comment,
            -- measured rather than inferred: the closing local balance times the
            -- day's rate change. Zero when the account's currency is the
            -- family's, because both rates are then exactly 1.
            COALESCE(SUM(lb.end_balance * lb.flows_factor * (er.rate - prev_er.rate)), 0) AS fx_effect,
            -- Only a balance that is not zero needs converting: an account
            -- whose rows are all zero (an unfunded account with a zero opening
            -- anchor) contributes zero at any rate, so it cannot be short of
            -- one. start_balance is checked too, but only on a row dated this
            -- day, because that is the only start_balance value_open reads; a
            -- row carried forward opens at its end_balance (above).
            BOOL_OR((lb.end_balance <> 0 OR (lb.date = d.date AND lb.start_balance <> 0))
                    AND sa.currency <> :target_currency
                    AND er.rate IS NULL) AS rate_missing
          FROM dates d
          LEFT JOIN scoped_accounts sa
            ON sa.active_until_date IS NULL OR d.date <= sa.active_until_date
          LEFT JOIN LATERAL (
            SELECT b.date, b.end_balance, b.start_balance, b.flows_factor
            FROM balances b
            WHERE b.account_id = sa.id
              AND b.currency = sa.currency
              AND b.date <= d.date
            ORDER BY b.date DESC
            LIMIT 1
          ) lb ON TRUE
          LEFT JOIN LATERAL (
            SELECT b.net_market_flows, b.cash_adjustments, b.non_cash_adjustments, b.flows_factor
            FROM balances b
            WHERE b.account_id = sa.id
              AND b.currency = sa.currency
              AND b.date = d.date
            LIMIT 1
          ) tb ON TRUE
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('sa.currency', 'd.date')} AS rate
          ) er ON TRUE
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('sa.currency', "d.date - 1")} AS rate
          ) prev_er ON TRUE
          GROUP BY d.date
        ),
        flows_by_date AS (
          SELECT
            entries.date AS date,
            -- A security journalled in or out is an external flow whose
            -- magnitude is the POSITION's value, not the entry's cash amount.
            -- A journal is written with `amount: 0` (Questrade writes
            -- `price: 0, amount: 0`), so `-entries.amount` values it at nothing
            -- and the arriving position lands in the numerator with the
            -- denominator unchanged -- a position worth half the account read
            -- as a 50% day.
            --
            -- Valued as qty x the holding's price for that date, and NOT as
            -- `journal_holdings.amount`: `amount` is the whole position for
            -- that security in the account, including units already held, so it
            -- overstates the flow whenever a journal tops up a position the
            -- scope already had. qty is what arrived.
            --
            -- The price comes from the same `holdings` row that
            -- Balance::BaseCalculator#market_value_change_on_date reads, so the
            -- numerator and the denominator move by one number rather than two
            -- independently derived ones.
            COALESCE(SUM(CASE WHEN #{fragment(:flow_class_sql)} IN ('external_inflow', 'external_outflow')
                              THEN CASE WHEN #{fragment(:journal_predicate)}
                                        THEN COALESCE(trades.qty * journal_holdings.price * journal_fx.rate, 0)
                                        ELSE -entries.amount * entry_fx.rate * fx.rate
                                   END
                              ELSE 0 END), 0) AS external_flow,
            -- The SAME value is already in the balance row's
            -- net_market_flows: a journal carries `amount: 0`, so
            -- Balance::BaseCalculator books its whole arriving value as market
            -- movement. Counting it as an external flow as well would leave the
            -- identity short by exactly the journal, and `unexplained` would
            -- carry minus its value on every journal day. Reported separately
            -- here so the final SELECT can take it back out of `market`.
            COALESCE(SUM(CASE WHEN #{fragment(:journal_predicate)}
                              AND #{fragment(:flow_class_sql)} IN ('external_inflow', 'external_outflow')
                              THEN COALESCE(trades.qty * journal_holdings.price * journal_fx.rate, 0)
                              ELSE 0 END), 0) AS journal_flow,
            COALESCE(SUM(CASE WHEN #{fragment(:flow_class_sql)} = 'income'
                              THEN -entries.amount * entry_fx.rate * fx.rate ELSE 0 END), 0) AS income,
            COALESCE(SUM(CASE WHEN #{fragment(:flow_class_sql)} = 'fee'
                              THEN  entries.amount * entry_fx.rate * fx.rate ELSE 0 END), 0) AS fees,
            -- A missing rate applies to flows as it does to balances: a flow in a
            -- currency with no rate is flagged, never converted at parity. Only the
            -- classes that feed a figure count; an internal trade in an
            -- unconvertible currency moves nothing we sum. A zero amount
            -- converts to zero at any rate, so it cannot be short of one.
            --
            -- A journal converts from the HOLDING's currency, not the entry's,
            -- so a missing rate there is invisible to the check above. Without
            -- this a suppressed journal day would not report `rate_missing?`
            -- and a caller could not say which fact it was short of.
            --
            -- For the same reason the entry-currency check leaves journals out:
            -- a journal's entry carries a zero amount that converts nothing,
            -- so its rate cannot be what a figure is short of. COALESCE
            -- because the predicate compares `trades` columns, and a trade
            -- with no label makes it NULL; NOT NULL is NULL, which would
            -- drop the row from this check rather than keep it.
            COALESCE(BOOL_OR(((entry_fx.rate IS NULL OR fx.rate IS NULL)
                              AND entries.amount <> 0
                              AND NOT COALESCE((#{fragment(:journal_predicate)}), false)
                              AND #{fragment(:flow_class_sql)} IN ('external_inflow', 'external_outflow', 'income', 'fee'))
                             OR (journal_fx.rate IS NULL
                                 AND journal_holdings.currency IS NOT NULL
                                 AND #{fragment(:journal_predicate)}
                                 AND #{fragment(:flow_class_sql)} IN ('external_inflow', 'external_outflow'))), false) AS flow_rate_missing,
            -- The journal suppression condition, and it keys on the PRICE rather
            -- than on the row. Holding::PortfolioCache deliberately keeps zero-price
            -- journal trades (Holding::PortfolioCache#load_prices) and matches the exact
            -- date only, so on a journal date with no price for that date --
            -- a weekend, a holiday, an instance with no feed -- `build_holdings`
            -- still writes a row, valued at qty x 0. Keying on "no row exists"
            -- would never fire and the phantom gain would simply move to the
            -- day the price appears.
            --
            -- Keyed on the JOURNAL predicate, not on `entryable_type` alone:
            -- the flow classifier makes a Contribution or Withdrawal labelled
            -- trade external too, and one of those is valued from `-entries.amount` like any
            -- other external flow. It needs no holdings row, and a trade with
            -- qty 0 writes none, so keying on the type suppressed a day whose
            -- figures were complete.
            --
            -- A NULL quantity counts as unpriced too. `trades.qty` is nullable
            -- and only Trade's presence validation fills it; without it the
            -- COALESCE above values the journal at nothing, which is the
            -- phantom gain this suppression exists to stop.
            --
            -- Every journal leg, internal ones included. A position moved
            -- between two selected accounts on an unpriced day leaves the
            -- source at its value and lands in the destination at zero, so
            -- the day reads as a loss of the whole position.
            COALESCE(BOOL_OR(#{fragment(:journal_predicate)}
                             AND (trades.qty IS NULL
                                  OR journal_holdings.price IS NULL
                                  OR journal_holdings.price <= 0
                                  OR journal_fx.rate IS NULL)), false) AS journal_unpriced
          FROM entries
          JOIN accounts entry_accounts ON entry_accounts.id = entries.account_id
          -- The same active-until window the balances use: a flow dated after
          -- an account stopped contributing value must not enter the
          -- denominator of a day that account is no longer part of.
          LEFT JOIN account_windows flow_windows ON flow_windows.account_id = entries.account_id
          #{fragment(:flow_class_joins)}
          -- Two steps, the same two the balance takes. First into the
          -- ACCOUNT's currency on the entry's own date, preferring a rate the
          -- entry carries itself, exactly as Balance::SyncCache converts it
          -- before the calculators apply it -- so the flow is the amount the
          -- balance actually moved by.
          LEFT JOIN LATERAL (
            SELECT CASE
              WHEN COALESCE(entries.currency, entry_accounts.currency) = entry_accounts.currency THEN 1::numeric
              WHEN #{fragment(:entry_custom_rate)} IS NOT NULL
                THEN CASE WHEN #{fragment(:entry_custom_rate)} > 0 THEN #{fragment(:entry_custom_rate)} END
              ELSE #{rate_lookup('entries.currency', 'entries.date', to: 'entry_accounts.currency')}
            END AS rate
          ) entry_fx ON TRUE
          -- Then into the family's currency at the PREVIOUS day's rate,
          -- because a start-of-day flow joins the opening capital, which is
          -- itself valued at that rate. Mixing rates here is what would leave
          -- a residual in `unexplained`. NULL at either step when the pair has
          -- no rate: the amount then drops out of every sum and
          -- flow_rate_missing says so.
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('entry_accounts.currency', 'entries.date - 1')} AS rate
          ) fx ON TRUE
          -- The position this entry moved, on the day it moved, for valuing a
          -- journal. Absent for every non-trade entry and for a trade whose
          -- security the account holds no row for that date.
          --
          -- EXACTLY ONE ROW, which is why this is a LATERAL and not a plain
          -- join. `holdings` is unique on (account_id, security_id, date,
          -- CURRENCY), so one security can hold several rows for one day --
          -- Balance::SyncCache sums them all, converting each from its own
          -- currency. A join without the currency would match every one of
          -- them and value the journal once per row.
          --
          -- The row matching the entry's own currency is preferred, since that
          -- is the unit `trades.qty` is priced in; the ordering falls back to
          -- the alphabetically first currency so the choice is deterministic
          -- rather than whatever the planner returns.
          LEFT JOIN LATERAL (
            SELECT h.price, h.currency
            FROM holdings h
            WHERE entries.entryable_type = 'Trade'
              AND h.account_id = entries.account_id
              AND h.security_id = trades.security_id
              AND h.date = entries.date
            ORDER BY (h.currency = COALESCE(entries.currency, entry_accounts.currency)) DESC, h.currency
            LIMIT 1
          ) journal_holdings ON TRUE
          -- Converted from the HOLDING's currency, which is the one its price
          -- is quoted in, and at the previous day's rate for the same reason
          -- every other start-of-day flow is.
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('journal_holdings.currency', 'entries.date - 1')} AS rate
          ) journal_fx ON TRUE
          WHERE entries.account_id = ANY(array[:account_ids]::uuid[])
            AND entries.date BETWEEN :start_date AND :end_date
            AND (flow_windows.active_until_date IS NULL OR entries.date <= flow_windows.active_until_date)
            -- Excluded entries count: excluding one hides it from budgets, but
            -- Balance::SyncCache still applies it, so it moved the balance and
            -- belongs in the denominator (the classifier is built with
            -- include_excluded). A split parent is the exception: SyncCache
            -- skips it and its children carry the amount.
            AND NOT EXISTS (SELECT 1 FROM entries split_children WHERE split_children.parent_entry_id = entries.id)
          GROUP BY entries.date
        ),
        -- An inbound journal that could not be valued on its own date, carried
        -- to the first later day in the period on which the account's holding
        -- of that security has a price, and booked THERE.
        --
        -- Suppressing the journal day alone is not enough. Holding.gapfill
        -- carries the journal's zero price forward, so the position sits in
        -- the balance at nothing until a price arrives; on that first priced
        -- day it jumps from 0 to qty x price, and Balance::BaseCalculator books
        -- the jump as net_market_flows. That is the position arriving, not a
        -- return, so it joins that day's start-of-day capital and leaves
        -- `market`, exactly as a priced journal does on its own day.
        --
        -- Internal legs too: the matching outbound leg's loss sat on the
        -- suppressed journal day, so the destination's re-pricing is not a
        -- gain either. An outbound leg needs no carry; its position left.
        --
        -- Valued from the same holdings row the calculator read that day, in
        -- its currency, at the previous day's rate like every start-of-day
        -- flow.
        carried_journals_by_date AS (
          SELECT
            first_priced.date AS date,
            COALESCE(SUM(trades.qty * first_priced.price * carry_fx.rate), 0) AS carried_flow,
            BOOL_OR(carry_fx.rate IS NULL) AS carry_rate_missing
          FROM entries
          JOIN trades ON entries.entryable_type = 'Trade' AND trades.id = entries.entryable_id
          JOIN accounts entry_accounts ON entry_accounts.id = entries.account_id
          LEFT JOIN account_windows carry_windows ON carry_windows.account_id = entries.account_id
          LEFT JOIN LATERAL (
            SELECT h.price
            FROM holdings h
            WHERE h.account_id = entries.account_id
              AND h.security_id = trades.security_id
              AND h.date = entries.date
            ORDER BY (h.currency = COALESCE(entries.currency, entry_accounts.currency)) DESC, h.currency
            LIMIT 1
          ) journal_day ON TRUE
          JOIN LATERAL (
            SELECT h.date, h.price, h.currency
            FROM holdings h
            WHERE h.account_id = entries.account_id
              AND h.security_id = trades.security_id
              AND h.date > entries.date
              AND h.date <= DATE :end_date
              AND h.price > 0
            ORDER BY h.date, (h.currency = COALESCE(entries.currency, entry_accounts.currency)) DESC, h.currency
            LIMIT 1
          ) first_priced ON TRUE
          LEFT JOIN LATERAL (
            SELECT #{rate_lookup('first_priced.currency', 'first_priced.date - 1')} AS rate
          ) carry_fx ON TRUE
          WHERE entries.account_id = ANY(array[:account_ids]::uuid[])
            AND entries.date BETWEEN :start_date AND :end_date
            AND #{fragment(:journal_predicate)}
            AND trades.qty > 0
            AND (journal_day.price IS NULL OR journal_day.price <= 0)
            AND (carry_windows.active_until_date IS NULL OR first_priced.date <= carry_windows.active_until_date)
          GROUP BY first_priced.date
        )
        SELECT
          b.date,
          b.value_close,
          b.value_open,
          -- The journal is now an external flow, so it must stop being a
          -- market move. Same value, same row, taken out of the driver that
          -- double-counted it.
          b.market - COALESCE(f.journal_flow, 0) - COALESCE(cj.carried_flow, 0) AS market,
          b.revaluations,
          b.fx_effect,
          (b.rate_missing OR COALESCE(f.flow_rate_missing, false) OR COALESCE(cj.carry_rate_missing, false)) AS rate_missing,
          COALESCE(arr.arrived_value, 0) AS arrived_value,
          COALESCE(dep.departed_value, 0) AS departed_value,
          COALESCE(f.journal_unpriced, false) AS journal_unpriced,
          COALESCE(f.external_flow, 0) + COALESCE(cj.carried_flow, 0) AS external_flow,
          COALESCE(f.income, 0) AS income,
          COALESCE(f.fees, 0) AS fees
        FROM balances_by_date b
        LEFT JOIN flows_by_date f ON f.date = b.date
        LEFT JOIN carried_journals_by_date cj ON cj.date = b.date
        LEFT JOIN arrivals_by_date arr ON arr.date = b.date
        LEFT JOIN departures_by_date dep ON dep.date = b.date
        ORDER BY b.date
      SQL
    end

    # Carry the last known rate forward, then fall back to the earliest one
    # ahead. Both halves matter: without the first a weekend converts at parity,
    # and without the second an account that predates the family's rate history
    # does. Returns NULL when the pair has no rate at all, which is what
    # #rate_missing? surfaces.
    #
    # `to` defaults to the family's currency; the flows pass an account's.
    def rate_lookup(currency_expression, date_expression, to: ":target_currency")
      <<~SQL.squish
        CASE
          WHEN #{currency_expression} = #{to} THEN 1::numeric
          ELSE COALESCE(
            (SELECT r.rate FROM exchange_rates r
              WHERE r.from_currency = #{currency_expression}
                AND r.to_currency = #{to}
                AND r.date <= #{date_expression}
              ORDER BY r.date DESC LIMIT 1),
            (SELECT r.rate FROM exchange_rates r
              WHERE r.from_currency = #{currency_expression}
                AND r.to_currency = #{to}
                AND r.date > #{date_expression}
              ORDER BY r.date ASC LIMIT 1)
          )
        END
      SQL
    end

    # The rate an entry carries itself (extra["exchange_rate"] on its Trade or
    # Transaction), which Balance::SyncCache prefers to the table's. Stored as
    # a number by Trade#exchange_rate= and Transaction#exchange_rate=, but a
    # row written to `extra` directly can hold a decimal string, which
    # Money#exchange_to accepts too; anything else is not cast, so it cannot
    # fail the query. Spliced as a fragment because the POSIX class in the
    # pattern would read as a bind to sanitize_sql_array. Same expression as
    # Holding's average-cost rate.
    def entry_custom_rate_sql
      <<~SQL.squish
        (CASE jsonb_typeof(COALESCE(trades.extra, transactions.extra)->'exchange_rate')
          WHEN 'number' THEN (COALESCE(trades.extra, transactions.extra)->>'exchange_rate')::numeric
          WHEN 'string' THEN CASE WHEN COALESCE(trades.extra, transactions.extra)->>'exchange_rate' ~ '^[[:space:]]*[+-]?([0-9]{1,20}([.][0-9]{0,20})?|[.][0-9]{1,20})[[:space:]]*$'
                                  THEN (COALESCE(trades.extra, transactions.extra)->>'exchange_rate')::numeric END
        END)
      SQL
    end

    # One classifier for both fragments, built on the accounts this instance
    # values. Its table aliases are fixed rather than passed in; nothing in
    # the queries above joins `trades` or `transactions` itself, so there is
    # nothing to collide with.
    #
    # include_excluded, because an excluded entry still moved the balance
    # (see the flows' WHERE).
    #
    # A known limit: the classifier's scope is a static set of account ids and
    # knows nothing of active_until_dates. A transfer between a live account
    # and one past its cut-off still classifies as internal, while the
    # cut-off account's leg is dropped from the flows, so the live account's
    # leg leaves the denominator unchanged and its move reads as a return. No
    # caller passes active_until_dates yet; the change that first does must
    # make the classifier window-aware, with a test for that transfer.
    def flow_classifier
      @flow_classifier ||= Portfolio::FlowClassifier.new(scope_account_ids: account_ids, include_excluded: true)
    end

    # A security journal: a Transfer-labelled trade with no cash amount.
    #
    # Deliberately NOT every Trade classified external -- the flow classifier
    # makes a Contribution or Withdrawal labelled Trade external too, and those
    # carry a real cash amount that must keep flowing at its amount rather than
    # being revalued from a position.
    #
    # The amount is checked as well as the label, and it is not belt and braces.
    # A Transfer-labelled trade that carries `amount = qty x price` is ordinary
    # -- the onchain processor, the web edit form, the API update and any Buy
    # relabelled Transfer all write one -- and for those the balance calculator
    # has already booked a cash-settled purchase, so the close does not move and
    # there is no market flow to take the value out of. Valued from the position
    # anyway, a 500 purchase in a 1,000 account read as external_flow 500,
    # market -500, denominator 1,500 and a -33% day, with `unexplained` at 0:
    # a phantom loss that reconciles, which the drivers table cannot flag.
    def journal_predicate
      "entries.entryable_type = 'Trade' " \
        "AND trades.investment_activity_label = '#{Portfolio::FlowClassifier::TRANSFER_LABEL}' " \
        "AND entries.amount = 0"
    end
end
