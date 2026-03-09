class Balance::ForwardCalculator < Balance::BaseCalculator
  def initialize(account, window_start_date: nil)
    super(account)
    @window_start_date = window_start_date
    @fell_back = nil  # unknown until calculate is called
  end

  # True only when we are actually running in incremental mode (i.e. window_start_date
  # was provided and we successfully found a valid prior balance to seed from).
  #
  # Must not be called before calculate — @fell_back is nil until resolve_starting_balances runs.
  def incremental?
    raise "incremental? must not be called before calculate" if @window_start_date.present? && @fell_back.nil?
    @window_start_date.present? && @fell_back == false
  end

  def calculate
    Rails.logger.tagged("Balance::ForwardCalculator") do
      start_cash_balance, start_non_cash_balance = resolve_starting_balances

      calc_start_date.upto(calc_end_date).map do |date|
        valuation = sync_cache.get_valuation(date)

        if valuation
          end_cash_balance = derive_cash_balance_on_date_from_total(
            total_balance: valuation.amount,
            date: date
          )
          end_non_cash_balance = valuation.amount - end_cash_balance
        else
          end_cash_balance = derive_end_cash_balance(start_cash_balance: start_cash_balance, date: date)
          end_non_cash_balance = derive_end_non_cash_balance(start_non_cash_balance: start_non_cash_balance, date: date)
        end

        flows = flows_for_date(date)
        market_value_change = market_value_change_on_date(date, flows)

        cash_adjustments = cash_adjustments_for_date(start_cash_balance, end_cash_balance, (flows[:cash_inflows] - flows[:cash_outflows]) * flows_factor)
        non_cash_adjustments = non_cash_adjustments_for_date(start_non_cash_balance, end_non_cash_balance, (flows[:non_cash_inflows] - flows[:non_cash_outflows]) * flows_factor)

        output_balance = build_balance(
          date: date,
          balance: end_cash_balance + end_non_cash_balance,
          cash_balance: end_cash_balance,
          start_cash_balance: start_cash_balance,
          start_non_cash_balance: start_non_cash_balance,
          cash_inflows: flows[:cash_inflows],
          cash_outflows: flows[:cash_outflows],
          non_cash_inflows: flows[:non_cash_inflows],
          non_cash_outflows: flows[:non_cash_outflows],
          cash_adjustments: cash_adjustments,
          non_cash_adjustments: non_cash_adjustments,
          net_market_flows: market_value_change
        )

        # Set values for the next iteration
        start_cash_balance = end_cash_balance
        start_non_cash_balance = end_non_cash_balance

        output_balance
      end
    end
  end

  private
    # Returns [start_cash_balance, start_non_cash_balance] for the first iteration.
    #
    # In incremental mode: load the persisted end-of-day balance for window_start_date - 1
    # from the DB and use that as the seed. Falls back to full recalculation when:
    #   - No prior balance record exists in the DB, or
    #   - The prior balance has a non-zero non-cash component (e.g. investment holdings)
    #     because Holding::Materializer always does a full recalc, which could make the
    #     persisted non-cash seed stale relative to freshly-computed holding prices.
    def resolve_starting_balances
      if @window_start_date.present?
        if multi_currency_account?
          Rails.logger.info("Account has multi-currency entries or is foreign, falling back to full recalculation")
          @fell_back = true
          return opening_starting_balances
        end

        prior = prior_balance

        if prior && (prior.end_non_cash_balance || 0).zero?
          Rails.logger.info("Incremental sync from #{@window_start_date}, seeding from persisted balance on #{prior.date}")
          @fell_back = false
          return [ prior.end_cash_balance, prior.end_non_cash_balance ]
        elsif prior
          Rails.logger.info("Prior balance has non-cash component, falling back to full recalculation")
        else
          Rails.logger.info("No persisted balance found for #{@window_start_date - 1}, falling back to full recalculation")
        end

        @fell_back = true
      end

      opening_starting_balances
    end

    # Returns true when the account has entries in currencies other than the
    # account currency, or when the account currency differs from the family
    # currency. In either case, balance calculations depend on exchange rates
    # that may have been missing (fallback_rate: 1) on a prior sync and later
    # imported — so we must do a full recalculation to pick them up.
    def multi_currency_account?
      account.entries.where.not(currency: account.currency).exists? ||
        account.currency != account.family.currency
    end

    def opening_starting_balances
      cash = derive_cash_balance_on_date_from_total(
        total_balance: account.opening_anchor_balance,
        date: account.opening_anchor_date
      )
      [ cash, account.opening_anchor_balance - cash ]
    end

    # The balance record for the day immediately before the incremental window.
    def prior_balance
      account.balances
        .where(currency: account.currency)
        .find_by(date: @window_start_date - 1)
    end

    def calc_start_date
      incremental? ? @window_start_date : account.opening_anchor_date
    end

    def calc_end_date
      [ account.entries.order(:date).last&.date, account.holdings.order(:date).last&.date ].compact.max || Date.current
    end

    # Negative entries amount on an "asset" account means, "account value has increased"
    # Negative entries amount on a "liability" account means, "account debt has decreased"
    # Positive entries amount on an "asset" account means, "account value has decreased"
    # Positive entries amount on a "liability" account means, "account debt has increased"
    def signed_entry_flows(entries)
      entry_flows = entries.sum(&:amount)
      account.asset? ? -entry_flows : entry_flows
    end

    # Derives cash balance, starting from the start-of-day, applying entries in forward to get the end-of-day balance
    def derive_end_cash_balance(start_cash_balance:, date:)
      derive_cash_balance(start_cash_balance, date)
    end

    # Derives non-cash balance, starting from the start-of-day, applying entries in forward to get the end-of-day balance
    def derive_end_non_cash_balance(start_non_cash_balance:, date:)
      derive_non_cash_balance(start_non_cash_balance, date, direction: :forward)
    end

    def flows_factor
      account.asset? ? 1 : -1
    end
end
