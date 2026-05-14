class Goals::FundingAccountsBreakdownComponent < ApplicationComponent
  WINDOW_DAYS = 30
  TRAJECTORY_WINDOW_DAYS = 90
  TRAJECTORY_SAMPLES = 24

  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def rows
    @rows ||= goal.linked_accounts.sort_by { |a| -a.balance.to_d }.map do |account|
      {
        account: account,
        balance: account.balance.to_d,
        balance_money: Money.new(account.balance.to_d, goal.currency),
        last_30_money: Money.new(last_30_inflow_for(account), goal.currency),
        trajectory_points: trajectory_for(account)
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
    # Net 30-day inflow per account in one grouped query. Powers the right-hand
    # "$X last 30d" column.
    def last_30_inflow_for(account)
      last_30_inflow_map[account.id] || 0
    end

    def last_30_inflow_map
      @last_30_inflow_map ||= begin
        account_ids = goal.linked_accounts.map(&:id)
        return {} if account_ids.empty?

        Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account_ids, date: WINDOW_DAYS.days.ago.to_date..Date.current)
          .where(excluded: false)
          .group(:account_id)
          .sum(:amount)
          .transform_values { |v| (-v.to_d).clamp(0, Float::INFINITY) }
      end
    end

    # 24-sample balance trajectory per account over the last 90 days. Drives
    # the per-row filled-area chart — same conceptual shape as the projection
    # chart on goals#show, just per linked account. We pull every Balance row
    # in the window in one query and, for each anchor date in the sample grid,
    # carry-forward the most-recent balance at-or-before that anchor.
    def trajectory_for(account)
      trajectory_map[account.id] || Array.new(TRAJECTORY_SAMPLES, 0.0)
    end

    def trajectory_map
      @trajectory_map ||= begin
        account_ids = goal.linked_accounts.map(&:id)
        return {} if account_ids.empty?

        rows = Balance
          .where(account_id: account_ids, date: TRAJECTORY_WINDOW_DAYS.days.ago.to_date..Date.current)
          .order(account_id: :asc, date: :asc)
          .pluck(:account_id, :date, :balance)

        grouped = rows.group_by(&:first)
        account_ids.each_with_object({}) do |aid, h|
          h[aid] = sample_trajectory(grouped[aid] || [])
        end
      end
    rescue StandardError => e
      Rails.logger.error("Trajectory map for goal #{goal.id} failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      {}
    end

    # Walk forward through sorted rows once, advancing the cursor as the
    # anchor date passes each row's date. O(rows + samples) instead of
    # O(rows × samples) reverse-find.
    def sample_trajectory(rows)
      return Array.new(TRAJECTORY_SAMPLES, 0.0) if rows.empty?

      sorted = rows.sort_by { |r| r[1] }
      step = TRAJECTORY_WINDOW_DAYS / (TRAJECTORY_SAMPLES - 1).to_f
      cursor = 0
      last_balance = sorted.first[2].to_f

      Array.new(TRAJECTORY_SAMPLES) do |i|
        anchor = (TRAJECTORY_WINDOW_DAYS - (step * i)).days.ago.to_date

        while cursor < sorted.length && sorted[cursor][1] <= anchor
          last_balance = sorted[cursor][2].to_f
          cursor += 1
        end

        last_balance
      end
    end
end
