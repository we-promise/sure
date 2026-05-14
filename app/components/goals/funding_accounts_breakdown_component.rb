class Goals::FundingAccountsBreakdownComponent < ApplicationComponent
  WINDOW_DAYS = 30
  TRAJECTORY_SAMPLES = WINDOW_DAYS + 1 # 31 points: 30 days ago … today

  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def rows
    @rows ||= goal.linked_accounts.sort_by { |a| -a.balance.to_d }.map do |account|
      cumulative = cumulative_inflow_for(account)
      {
        account: account,
        balance: account.balance.to_d,
        balance_money: Money.new(account.balance.to_d, goal.currency),
        last_30_money: Money.new(cumulative.last.to_d, goal.currency),
        trajectory_points: cumulative
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

  # Label shown beneath the account name. Prefers the depository subtype
  # ("Savings", "HSA"…) over the bare accountable_type ("Depository") so the
  # subline carries useful signal. Falls back to the accountable type's i18n
  # entry (`accounts.types.*`), and finally to a `titleize` so the row is
  # never blank if a string is missing.
  def accountable_label(account)
    if account.subtype.present?
      I18n.t("goals.form_stepper.step1.subtypes.#{account.subtype}", default: account.subtype.titleize)
    else
      type = account.accountable_type.to_s
      I18n.t("accounts.types.#{type.underscore}", default: type.titleize)
    end
  end

  private
    # 31 daily points (30 days ago … today) of cumulative inflow into this
    # account, scoped to the same 30-day window the right-hand "$X last 30d"
    # column reports — the chart's rightmost point exactly equals that column
    # by construction.
    def cumulative_inflow_for(account)
      cumulative_inflow_map[account.id] || Array.new(TRAJECTORY_SAMPLES, 0.0)
    end

    # Single grouped query: every (account_id, date) inflow row over the 30-day
    # window. Then walk per-account to materialize a 31-point cumulative array.
    # Entry amount sign in Sure: inflow is negative; flip and clamp ≥ 0 so the
    # cumulative is monotonic non-decreasing.
    def cumulative_inflow_map
      @cumulative_inflow_map ||= begin
        account_ids = goal.linked_accounts.map(&:id)
        return {} if account_ids.empty?

        per_day = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account_ids, date: WINDOW_DAYS.days.ago.to_date..Date.current)
          .where(excluded: false)
          .group(:account_id, :date)
          .sum(:amount)

        today = Date.current
        result = {}

        account_ids.each do |aid|
          running = 0.0
          result[aid] = (0..WINDOW_DAYS).map do |offset|
            date = today - (WINDOW_DAYS - offset).days
            raw = per_day[[ aid, date ]] || 0
            inflow = (-raw.to_d).clamp(0, Float::INFINITY).to_f
            running += inflow
            running
          end
        end

        result
      end
    rescue StandardError => e
      Rails.logger.error("Cumulative inflow map for goal #{goal.id} failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      {}
    end
end
