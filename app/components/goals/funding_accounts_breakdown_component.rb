class Goals::FundingAccountsBreakdownComponent < ApplicationComponent
  COLUMN_WINDOW_DAYS = 30
  TREND_WINDOW_DAYS = 90

  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def rows
    @rows ||= goal.linked_accounts.sort_by { |a| -a.balance.to_d }.map do |account|
      totals = inflow_totals_for(account)
      {
        account: account,
        balance: account.balance.to_d,
        balance_money: Money.new(account.balance.to_d, goal.currency),
        last_30_money: Money.new(totals[:last_30], goal.currency),
        last_90_money: Money.new(totals[:last_90], goal.currency)
      }
    end
  end

  def total
    @total ||= rows.sum { |r| r[:balance].to_d }
  end

  def percent_for(balance)
    return 0 if total.zero?
    ((balance.to_d / total) * 100).round
  end

  # Pull from the goal's per-goal account color map so the colors here
  # (distribution bar, row avatars) match the AccountStackComponent on the
  # index card. Stable + collision-free within the goal up to PALETTE size.
  def color_for(account)
    goal.account_color_map[account.id] || Goals::AvatarComponent.color_for(account.name)
  end

  # Label shown beneath the account name. Prefers the depository subtype
  # ("Savings", "HSA"…) over the bare accountable_type ("Depository") so the
  # subline carries useful signal. Falls back to the accountable type's i18n
  # entry (`accounts.types.*`), and finally to a `titleize` so the row is
  # never blank if a string is missing.
  def accountable_label(account)
    if account.subtype.present?
      I18n.t("goals.form.subtypes.#{account.subtype}", default: account.subtype.titleize)
    else
      type = account.accountable_type.to_s
      I18n.t("accounts.types.#{type.underscore}", default: type.titleize)
    end
  end

  private
    # Per-account net inflow for both windows in one pass over the 90-day
    # entries set. Entry amount sign in Sure: inflow is negative; flip and
    # clamp ≥ 0.
    def inflow_totals_for(account)
      inflow_totals_map[account.id] || { last_30: 0.to_d, last_90: 0.to_d }
    end

    def inflow_totals_map
      @inflow_totals_map ||= begin
        account_ids = goal.linked_accounts.map(&:id)
        return {} if account_ids.empty?

        cutoff_30 = COLUMN_WINDOW_DAYS.days.ago.to_date

        rows = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account_ids, date: TREND_WINDOW_DAYS.days.ago.to_date..Date.current)
          .where(excluded: false)
          .merge(Transaction.excluding_pending)
          .pluck(:account_id, :date, :amount)

        result = Hash.new { |h, k| h[k] = { last_30: 0.to_d, last_90: 0.to_d } }
        rows.each do |aid, date, amount|
          inflow = (-amount.to_d).clamp(0..)
          result[aid][:last_90] += inflow
          result[aid][:last_30] += inflow if date >= cutoff_30
        end
        result
      end
    rescue StandardError => e
      Rails.logger.error("Inflow totals map for goal #{goal.id} failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      {}
    end
end
