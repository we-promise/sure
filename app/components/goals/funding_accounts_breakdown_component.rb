class Goals::FundingAccountsBreakdownComponent < ApplicationComponent
  WINDOW_DAYS = 30
  SPARK_WINDOW_DAYS = 90

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
        sparkline_points: sparkline_for(account)
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
    def last_30_inflow_for(account)
      @inflow_cache ||= {}
      @inflow_cache[account.id] ||= begin
        net = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account.id, date: WINDOW_DAYS.days.ago.to_date..Date.current)
          .where(excluded: false)
          .sum(:amount)
        (-net.to_d).clamp(0, Float::INFINITY)
      end
    end

    # 12-bucket weekly sparkline of net inflow over 90 days. Uses the same
    # transfer-inclusive semantics as Goal#pace — transfers between linked
    # accounts wash out across the goal but show on each account's sparkline.
    def sparkline_for(account)
      buckets = 12
      bucket_days = (SPARK_WINDOW_DAYS / buckets.to_f).ceil

      buckets.times.map do |i|
        start_at = (SPARK_WINDOW_DAYS - (i + 1) * bucket_days).days.ago.to_date
        end_at = (SPARK_WINDOW_DAYS - i * bucket_days).days.ago.to_date
        net = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account.id, date: start_at..end_at)
          .where(excluded: false)
          .sum(:amount)
        (-net.to_d).clamp(0, Float::INFINITY).to_f
      end
    rescue StandardError => e
      Rails.logger.warn("Sparkline for account #{account.id} failed: #{e.message}")
      Array.new(buckets, 0.0)
    end
end
