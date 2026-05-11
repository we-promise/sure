class Savings::FundingAccountsBreakdownComponent < ApplicationComponent
  def initialize(goal:, rows:)
    @goal = goal
    @rows = rows
  end

  attr_reader :goal, :rows

  def total
    @total ||= rows.sum { |r| r[:amount].to_d }
  end

  def percent_for(amount)
    return 0 if total.zero?
    ((amount.to_d / total) * 100).round
  end
end
