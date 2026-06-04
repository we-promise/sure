class Balance::ReverseCalculator < Balance::BaseCalculator
  def initialize(account, window_start_date: nil)
    super(account)
    @window_start_date = window_start_date
    @fell_back = nil
  end

  # True when a window was provided and we successfully limited recalculation to that range.
  def incremental?
    raise "incremental? must not be called before calculate" if @window_start_date.present? && @fell_back.nil?
    @window_start_date.present? && @fell_back == false
  end

  def calculate
    Rails.logger.tagged("Balance::ReverseCalculator") do
      # Since it's a reverse sync, we're starting with the "end of day" balance components and
      # calculating backwards to derive the "start of day" balance components.
      end_cash_balance = derive_cash_balance_on_date_from_total(
        total_balance: account.current_anchor_balance,
        date: account.current_anchor_date
      )
      end_non_cash_balance = account.current_anchor_balance - end_cash_balance

      calc_start_date = resolve_calc_start_date

      # Calculates in reverse-chronological order (End of day -> Start of day)
      account.current_anchor_date.downto(calc_start_date).map do |date|
        flows = flows_for_date(date)
        valuation = sync_cache.get_valuation(date)

        if use_opening_anchor_for_date?(date)
          end_cash_balance = derive_cash_balance_on_date_from_total(
            total_balance: account.opening_anchor_balance,
            date: date
          )
          end_non_cash_balance = account.opening_anchor_balance - end_cash_balance

          start_cash_balance = end_cash_balance
          start_non_cash_balance = end_non_cash_balance
          market_value_change = 0
        elsif valuation && valuation.entryable.reconciliation?
          # Reconciliation waypoint: hard-reset the END-of-day balance to the
          # API-reported value, neutralizing any drift accumulated from missing
          # transactions between here and the next anchor. The START is still
          # derived from this day's own flows, so a same-day transaction is
          # attributed exactly once (and not added on top of the waypoint).
          end_cash_balance = derive_cash_balance_on_date_from_total(
            total_balance: valuation.amount,
            date: date
          )
          end_non_cash_balance = valuation.amount - end_cash_balance

          start_cash_balance = derive_start_cash_balance(end_cash_balance: end_cash_balance, date: date)
          start_non_cash_balance = derive_start_non_cash_balance(end_non_cash_balance: end_non_cash_balance, date: date)
          market_value_change = market_value_change_on_date(date, flows)
        else
          start_cash_balance = derive_start_cash_balance(end_cash_balance: end_cash_balance, date: date)
          start_non_cash_balance = derive_start_non_cash_balance(end_non_cash_balance: end_non_cash_balance, date: date)
          market_value_change = market_value_change_on_date(date, flows)
        end

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
          net_market_flows: market_value_change
        )

        end_cash_balance = start_cash_balance
        end_non_cash_balance = start_non_cash_balance

        output_balance
      end
    end
  end

  private

    def resolve_calc_start_date
      if @window_start_date.present?
        if multi_currency_account?
          Rails.logger.info("Account has multi-currency entries or is foreign, falling back to full reverse recalculation")
          @fell_back = true
          return account.opening_anchor_date
        end

        prior = prior_balance

        if prior
          Rails.logger.info("Incremental reverse sync from #{@window_start_date}, preserving balances before #{@window_start_date}")
          @fell_back = false
          return [ @window_start_date, account.opening_anchor_date ].max
        else
          Rails.logger.info("No persisted balance found for #{@window_start_date - 1}, falling back to full reverse recalculation")
          @fell_back = true
        end
      end

      account.opening_anchor_date
    end

    def multi_currency_account?
      account.entries.where.not(currency: account.currency).exists? ||
        account.currency != account.family.currency
    end

    def prior_balance
      account.balances
        .where(currency: account.currency)
        .find_by(date: @window_start_date - 1)
    end

    # Negative entries amount on an "asset" account means, "account value has increased"
    # Negative entries amount on a "liability" account means, "account debt has decreased"
    # Positive entries amount on an "asset" account means, "account value has decreased"
    # Positive entries amount on a "liability" account means, "account debt has increased"
    def signed_entry_flows(entries)
      entry_flows = entries.sum(&:amount)
      account.asset? ? entry_flows : -entry_flows
    end

    # Alias method, for algorithmic clarity
    # Derives cash balance, starting from the end-of-day, applying entries in reverse to get the start-of-day balance
    def derive_start_cash_balance(end_cash_balance:, date:)
      derive_cash_balance(end_cash_balance, date)
    end

    # Alias method, for algorithmic clarity
    # Derives non-cash balance, starting from the end-of-day, applying entries in reverse to get the start-of-day balance
    def derive_start_non_cash_balance(end_non_cash_balance:, date:)
      derive_non_cash_balance(end_non_cash_balance, date, direction: :reverse)
    end

    # Checks if this date should use the opening anchor balance instead of deriving it.
    # Only the opening_anchor_date itself gets this treatment — reconciliation waypoints
    # are handled separately in the calculate loop above.
    def use_opening_anchor_for_date?(date)
      account.has_opening_anchor? && date == account.opening_anchor_date
    end
end
