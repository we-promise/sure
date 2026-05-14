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
        sparkline_points: sparkline_points_for(account)
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
    SPARK_BUCKETS = 12

    # Single grouped query across every linked account for the last-30-day
    # inflow column. The V2 implementation hit one query per account in
    # the row loop; this collapses to one.
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

    # 12-bucket weekly sparkline of net inflow over 90 days per account, all
    # in one grouped query. Bucket index counts back from today
    # (`(CURRENT_DATE - entries.date) / bucket_days`); bucket 0 is the
    # newest 8-day window, bucket 11 is the oldest. Each row in the
    # returned per-account array is in oldest → newest order so the SVG
    # path reads left → right naturally. Uses the same transfer-inclusive
    # semantics as Goal#pace.
    def sparkline_points_for(account)
      sparkline_map[account.id] || Array.new(SPARK_BUCKETS, 0.0)
    end

    def sparkline_map
      @sparkline_map ||= begin
        account_ids = goal.linked_accounts.map(&:id)
        return {} if account_ids.empty?

        bucket_days = (SPARK_WINDOW_DAYS / SPARK_BUCKETS.to_f).ceil

        bucket_expr = Arel.sql(
          "LEAST(GREATEST((CURRENT_DATE - entries.date) / #{bucket_days.to_i}, 0), #{SPARK_BUCKETS - 1})"
        )

        rows = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account_ids, date: SPARK_WINDOW_DAYS.days.ago.to_date..Date.current)
          .where(excluded: false)
          .group(:account_id, bucket_expr)
          .sum(:amount)

        result = Hash.new { |h, k| h[k] = Array.new(SPARK_BUCKETS, 0.0) }
        rows.each do |(account_id, sql_idx), net|
          idx = (SPARK_BUCKETS - 1) - sql_idx.to_i
          result[account_id][idx] = (-net.to_d).clamp(0, Float::INFINITY).to_f
        end
        result
      end
    rescue StandardError => e
      Rails.logger.error("Sparkline map for goal #{goal.id} failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      {}
    end
end
