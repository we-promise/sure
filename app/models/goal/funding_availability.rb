class Goal::FundingAvailability
  AVAILABLE = "available"
  WHOLE_ACCOUNT_CLAIMED = "whole_account_claimed"
  UNSUPPORTED_ACCOUNT_TYPE = "unsupported_account_type"

  Availability = Data.define(:status, :free_to_earmark)

  def self.for(family:, accounts:, excluding_goal: nil)
    accounts = accounts.to_a
    fundable_ids = accounts.select { |account| account.accountable_type.in?(Goal::FUNDABLE_ACCOUNT_TYPES) }.map(&:id)
    allocations = GoalAccount
      .joins(:goal)
      .where(account_id: fundable_ids, goals: { family_id: family.id })
      .where.not(goals: { state: Goal::RELEASED_STATES })
    allocations = allocations.where.not(goal_id: excluding_goal.id) if excluding_goal&.persisted?
    allocations = allocations.pluck(:account_id, :allocated_amount).group_by(&:first)

    accounts.to_h do |account|
      entry = if account.id.in?(fundable_ids)
        values = allocations.fetch(account.id, []).map(&:last)
        status = values.any?(&:nil?) ? WHOLE_ACCOUNT_CLAIMED : AVAILABLE
        fixed_total = values.compact.sum(&:to_d)
        Availability.new(status:, free_to_earmark: account.balance.to_d - fixed_total)
      else
        Availability.new(status: UNSUPPORTED_ACCOUNT_TYPE, free_to_earmark: nil)
      end

      [ account.id.to_s, entry ]
    end
  end
end
