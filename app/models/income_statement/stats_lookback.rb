module IncomeStatement::StatsLookback
  STATS_LOOKBACK_MONTHS = 6

  private

    def lookback_start_date
      STATS_LOOKBACK_MONTHS.months.ago.beginning_of_month.to_date
    end

    # Always ends at the last completed month, regardless of how far back the
    # window extends — STATS_LOOKBACK_MONTHS only controls the start date.
    def lookback_end_date
      1.month.ago.end_of_month.to_date
    end

    # Derives visible statuses from Account.visible scope to avoid duplication.
    def visible_account_statuses
      Account.visible.where_values_hash["status"]
    end
end
