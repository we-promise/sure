class IbkrAccount::HistoricalBalancesSync
  include IbkrAccount::DataHelpers

  attr_reader :ibkr_account

  def initialize(ibkr_account)
    @ibkr_account = ibkr_account
  end

  def sync!
    return unless account.present?
    return if normalized_rows.empty?

    account.balances.upsert_all(
      balance_rows,
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
            next unless total&.positive?

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
    def fill_gaps(rows, existing_balances)
      return rows if rows.size < 2

      by_date    = rows.index_by { |r| r[:date] }
      first_date = rows.first[:date]
      last_date  = rows.last[:date]

      last_total = nil
      (first_date..last_date).filter_map do |date|
        if by_date[date]
          last_total = by_date[date][:total]
          by_date[date]
        else
          next unless last_total
          cash     = existing_balances[date]&.cash_balance || BigDecimal("0")
          { date: date, total: last_total, cash: cash, non_cash: last_total - cash }
        end
      end
    end

    def balance_rows
      current_time = Time.current

      normalized_rows.each_with_index.map do |row, index|
        previous_row = index.zero? ? nil : normalized_rows[index - 1]
        start_cash_balance     = previous_row ? previous_row[:cash]     : row[:cash]
        start_non_cash_balance = previous_row ? previous_row[:non_cash] : row[:non_cash]

        {
          account_id:             account.id,
          date:                   row[:date],
          balance:                row[:total],
          cash_balance:           row[:cash],
          currency:               account.currency,
          start_cash_balance:     start_cash_balance,
          start_non_cash_balance: start_non_cash_balance,
          cash_inflows:           0,
          cash_outflows:          0,
          non_cash_inflows:       0,
          non_cash_outflows:      0,
          net_market_flows:       0,
          cash_adjustments:       row[:cash]     - start_cash_balance,
          non_cash_adjustments:   row[:non_cash] - start_non_cash_balance,
          flows_factor:           1,
          created_at:             current_time,
          updated_at:             current_time
        }
      end
    end
end
