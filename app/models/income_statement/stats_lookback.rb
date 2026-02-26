module IncomeStatement::StatsLookback
  STATS_LOOKBACK_MONTHS = 6

  # Matches Account.visible scope: where(status: ["draft", "active"])
  VISIBLE_ACCOUNT_STATUSES = %w[draft active].freeze

  private

    def lookback_start_date
      STATS_LOOKBACK_MONTHS.months.ago.beginning_of_month.to_date
    end

    # Always ends at the last completed month, regardless of how far back the
    # window extends — STATS_LOOKBACK_MONTHS only controls the start date.
    def lookback_end_date
      1.month.ago.end_of_month.to_date
    end

    def visible_account_statuses_sql
      @visible_account_statuses_sql ||= VISIBLE_ACCOUNT_STATUSES.map { |s| "'#{s}'" }.join(", ")
    end
end
