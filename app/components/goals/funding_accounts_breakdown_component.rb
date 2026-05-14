class Goals::FundingAccountsBreakdownComponent < ApplicationComponent
  WINDOW_DAYS = 30
  SPARK_WINDOW_DAYS = 90

  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def rows
    @rows ||= goal.linked_accounts.sort_by { |a| -last_30_inflow_for(a) }.map do |account|
      inflow = last_30_inflow_for(account)
      {
        account: account,
        balance_money: Money.new(account.balance.to_d, goal.currency),
        last_30_money: Money.new(inflow, goal.currency),
        last_30_amount: inflow,
        sparkline_points: sparkline_for(account)
      }
    end
  end

  private
    def last_30_inflow_for(account)
      @inflow_cache ||= {}
      @inflow_cache[account.id] ||= begin
        net = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account.id, date: WINDOW_DAYS.days.ago.to_date..Date.current)
          .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
          .where(excluded: false)
          .sum(:amount)
        (-net.to_d).clamp(0, Float::INFINITY)
      end
    end

    # 12-bucket weekly sparkline of net non-transfer inflow over 90 days.
    def sparkline_for(account)
      buckets = 12
      bucket_days = (SPARK_WINDOW_DAYS / buckets.to_f).ceil

      buckets.times.map do |i|
        start_at = (SPARK_WINDOW_DAYS - (i + 1) * bucket_days).days.ago.to_date
        end_at = (SPARK_WINDOW_DAYS - i * bucket_days).days.ago.to_date
        net = Entry
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where(account_id: account.id, date: start_at..end_at)
          .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
          .where(excluded: false)
          .sum(:amount)
        (-net.to_d).clamp(0, Float::INFINITY).to_f
      end
    rescue StandardError => e
      Rails.logger.warn("Sparkline for account #{account.id} failed: #{e.message}")
      Array.new(buckets, 0.0)
    end
end
