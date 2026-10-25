class Balance::ReverseCalculator < Balance::BaseCalculator
  def calculate
    Rails.logger.tagged("Balance::ReverseCalculator") do
      # Since it's a reverse sync, we're starting with the "end of day" balance components and
      # calculating backwards to derive the "start of day" balance components.
      end_cash_balance = derive_cash_balance_on_date_from_total(
        total_balance: account.current_anchor_balance,
        date: account.current_anchor_date
      )
      end_non_cash_balance = account.current_anchor_balance - end_cash_balance

      # Calculates in reverse-chronological order (End of day -> Start of day).
      # Bound on calculation_start_date (not opening_anchor_date) so entries
      # backfilled with a date earlier than the opening anchor are still
      # materialized. Reconciliation waypoints below the anchor reset the
      # balance on their own dates; use_opening_anchor_for_date? still keys off
      # the anchor's real date, so the anchor's own treatment is unchanged.
      account.current_anchor_date.downto(calculation_start_date).map do |date|
        flows = flows_for_date(date)
        valuation = sync_cache.get_valuation(date)
        cash_adjustments = 0
        non_cash_adjustments = 0

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

        if use_opening_boundary_adjustment_for_date?(date)
          boundary_adjustment = opening_boundary_adjustment(
            end_cash_balance: end_cash_balance,
            end_non_cash_balance: end_non_cash_balance,
            flows: flows,
            market_value_change: market_value_change
          )

          start_cash_balance = boundary_adjustment[:start_cash_balance]
          start_non_cash_balance = boundary_adjustment[:start_non_cash_balance]
          cash_adjustments = boundary_adjustment[:cash_adjustments]
          non_cash_adjustments = boundary_adjustment[:non_cash_adjustments]
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
          cash_adjustments: cash_adjustments,
          non_cash_adjustments: non_cash_adjustments,
          net_market_flows: market_value_change
        )

        end_cash_balance = start_cash_balance
        end_non_cash_balance = start_non_cash_balance

        output_balance
      end
    end
  end

  private

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

    # Applies the one-day bridge from the opening anchor to the first derived day.
    def use_opening_boundary_adjustment_for_date?(date)
      account.has_opening_anchor? && date == account.opening_anchor_date.next_day
    end

    # Builds explicit adjustments that make the opening-boundary row auditably reconcile.
    def opening_boundary_adjustment(end_cash_balance:, end_non_cash_balance:, flows:, market_value_change:)
      opening_cash_balance, opening_non_cash_balance = opening_balance_components

      {
        start_cash_balance: opening_cash_balance,
        start_non_cash_balance: opening_non_cash_balance,
        cash_adjustments: cash_adjustments_for_date(opening_cash_balance, end_cash_balance, cash_flows_total(flows)),
        non_cash_adjustments: opening_boundary_non_cash_adjustments(
          opening_non_cash_balance: opening_non_cash_balance,
          end_non_cash_balance: end_non_cash_balance,
          flows: flows,
          market_value_change: market_value_change
        )
      }
    end

    # Splits the opening anchor total into the calculator's persisted components.
    def opening_balance_components
      opening_cash_balance = derive_cash_balance_on_date_from_total(
        total_balance: account.opening_anchor_balance,
        date: account.opening_anchor_date
      )

      [ opening_cash_balance, account.opening_anchor_balance - opening_cash_balance ]
    end

    # Converts same-day cash flow columns into their signed balance impact.
    def cash_flows_total(flows)
      (flows[:cash_inflows] - flows[:cash_outflows]) * flows_factor
    end

    # Converts same-day non-cash flow columns into their signed balance impact.
    def non_cash_flows_total(flows)
      (flows[:non_cash_inflows] - flows[:non_cash_outflows]) * flows_factor
    end

    # Keeps boundary non-cash math market-value-aware for investment accounts.
    def opening_boundary_non_cash_adjustments(opening_non_cash_balance:, end_non_cash_balance:, flows:, market_value_change:)
      end_non_cash_balance - opening_non_cash_balance - non_cash_flows_total(flows) - market_value_change
    end
end
