require "set"

class Assistant::Function::GetGoals < Assistant::Function
  class << self
    def name = "get_goals"
    def description = "Lists family goals with stable IDs and their complete funding allocation for update_goal and delete_goal."
  end

  def call(_params = {})
    accessible_ids = Set.new(user.accessible_accounts.visible.ids)
    goals = family.goals.includes(goal_accounts: :account).alphabetically.map do |goal|
      funding_accounts = goal.goal_accounts.filter_map do |link|
        next unless accessible_ids.include?(link.account_id)

        allocation = if link.allocated_amount.nil?
          { mode: "whole_account" }
        else
          { mode: "fixed_amount", amount: link.allocated_amount }
        end
        {
          account_id: link.account_id,
          name: link.account.name,
          currency: link.account.currency,
          allocation:
        }
      end

      {
        id: goal.id,
        name: goal.name,
        target_amount: goal.target_amount,
        currency: goal.currency,
        target_date: goal.target_date&.iso8601,
        notes: goal.notes,
        state: goal.state,
        funding_accounts:
      }
    end

    { goals: }
  end
end
