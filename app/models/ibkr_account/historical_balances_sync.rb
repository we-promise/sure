class IbkrAccount::HistoricalBalancesSync
  include IbkrAccount::DataHelpers

  attr_reader :ibkr_account

  def initialize(ibkr_account)
    @ibkr_account = ibkr_account
  end

  def sync!
    return unless account.present?
    return if normalized_rows.empty?

    rows = balance_rows
    return if rows.empty?

    account.balances.upsert_all(
      rows,
      unique_by: %i[account_id date currency]
    )
  end

  private

    def account
      ibkr_account.current_account
    end

    def account_currency
      ibkr_account.currency.to_s.upcase
    end

    def normalized_rows
      @normalized_rows ||= begin
        # Batch-load the materializer's already-computed balances so we can
        # preserve its cash split rather than reading cash from the equity summary.
        # Real IBKR Flex exports do not reliably include a cash/stock breakdown in
        # EquitySummaryByReportDateInBase — only the total is consistently present.
        existing_balances = account.balances
          .where(currency: account.currency)
          .index_by(&:date)

        trading_day_rows = Array(ibkr_account.raw_equity_summary_payload)
          .filter_map do |row|
            next unless row.is_a?(Hash)

            data = row.with_indifferent_access
            currency = data[:currency].presence&.upcase

            # BASE_SUMMARY rows aggregate across all currencies — not a per-date balance
            next if currency == "BASE_SUMMARY"
            # Reject rows with an explicit wrong currency; absent currency is accepted
            # (some Flex configurations omit it and the row is implicitly in base currency)
            next if currency.present? && currency != account_currency

            date = parse_date(data[:report_date])
            next unless date

            total = parse_decimal(data[:total])
            if total.nil?
              Rails.logger.warn(
                "IbkrAccount::HistoricalBalancesSync - Skipping equity summary row with missing or unparseable total " \
                "for date=#{data[:report_date].inspect} account=#{account.id}"
              )
              next
            end

            # Use the materializer's cash_balance as ground truth for the cash split.
            # This is consistent with how the reverse calculator handles present-day
            # weekends and holidays — derive cash from holdings, not from IBKR's field.
            cash = existing_balances[date]&.cash_balance || BigDecimal("0")

            { date: date, total: total, cash: cash, non_cash: total - cash }
          end
          .sort_by { |r| r[:date] }

        fill_gaps(trading_day_rows, existing_balances)
      end
    end

    # IBKR does not emit rows for weekends and some holidays. The reverse
    # calculator fills those dates using only imported holdings — which only
    # cover the current snapshot — so it cannot reconstruct the correct
    # non-cash value for historical gap dates. We carry the most recent
    # IBKR total forward to every missing calendar day and pair it with the
    # materializer's already-correct cash for that date.
    #
    # The range is extended to the account's current anchor date so that days
    # after the last equity summary row (e.g. a Saturday sync where the payload
    # ends on Friday) are also covered and not left with the materializer's
    # stale total=cash value.
    def fill_gaps(rows, existing_balances)
      return [] if rows.empty?

      by_date    = rows.index_by { |r| r[:date] }
      first_date = rows.first[:date]
      anchor_date = [ account.current_anchor_date || Date.current, Date.current ].min
      last_date   = [ rows.last[:date], anchor_date ].max

      last_total = nil
      (first_date..last_date).filter_map do |date|
        if by_date[date]
          last_total = by_date[date][:total]
          by_date[date]
        else
          next unless last_total
          cash = existing_balances[date]&.cash_balance || BigDecimal("0")
          { date: date, total: last_total, cash: cash, non_cash: last_total - cash }
        end
      end
    end

    def balance_rows
      current_time = Time.current
      trade_flows_by_date  # ensure @failed_fx_dates is populated before iterating

      normalized_rows.each_with_index.filter_map do |row, index|
        next if @failed_fx_dates.include?(row[:date])
        previous_row = index.zero? ? nil : normalized_rows[index - 1]
        start_cash_balance     = previous_row ? previous_row[:cash]     : row[:cash]
        start_non_cash_balance = previous_row ? previous_row[:non_cash] : row[:non_cash]

        # Derive market return directly from IBKR's equity data so Period Return
        # matches IBKR without requiring third-party security price providers.
        #
        # nmf = Δnon_cash - net_buy_sell
        #   Δnon_cash  : change in holdings value per IBKR equity summary (exact)
        #   net_buy_sell: sum of trade entry amounts converted to base currency
        #                 (positive = buy, negative = sell; IBKR fx_rate_to_base applied)
        #
        # non_cash_adjustments absorbs net_buy_sell so the virtual column
        # end_non_cash_balance = start + nmf + adjustments stays equal to row[:non_cash].
        if previous_row
          net_buy_sell = trade_flows_by_date[row[:date]] || 0
          nmf          = row[:non_cash] - start_non_cash_balance - net_buy_sell
          non_cash_adj = net_buy_sell
        else
          # First-day row has no prior period to diff against, so both values are
          # intentionally zero — not a bug, just an unavoidable bootstrap constraint.
          nmf          = 0
          non_cash_adj = 0
        end

        {
          account_id: account.id,
          date: row[:date],
          balance: row[:total],
          cash_balance: row[:cash],
          currency: account.currency,
          start_cash_balance: start_cash_balance,
          start_non_cash_balance: start_non_cash_balance,
          cash_inflows: 0,
          cash_outflows: 0,
          non_cash_inflows: 0,
          non_cash_outflows: 0,
          net_market_flows: nmf,
          cash_adjustments: row[:cash] - start_cash_balance,
          non_cash_adjustments: non_cash_adj,
          flows_factor: 1,
          created_at: current_time,
          updated_at: current_time
        }
      end
    end

    # Net value of all trades on each date, in account base currency.
    # Uses the IBKR-provided fx_rate_to_base stored on each Trade entry so the
    # conversion is exact and consistent with IBKR's own calculations.
    # Positive = net buy (cash out), negative = net sell (cash in).
    def trade_flows_by_date
      @trade_flows_by_date ||= begin
        @failed_fx_dates = []
        if account
          account.entries
            .joins("INNER JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
            .where.not(trades: { qty: 0 })
            .includes(:entryable)
            .each_with_object(Hash.new(0)) do |entry, flows|
              custom_rate = entry.entryable.exchange_rate
              base_amount = Money.new(entry.amount, entry.currency)
                .exchange_to(account_currency, custom_rate: custom_rate, date: entry.date)
                .amount
              flows[entry.date] += base_amount
            rescue Money::ConversionError
              Rails.logger.warn(
                "IbkrAccount::HistoricalBalancesSync - No FX rate for #{entry.currency}→#{account_currency} " \
                "on #{entry.date}; balance row for this date will not be persisted"
              )
              @failed_fx_dates << entry.date
            end
        else
          {}
        end
      end
    end
end
