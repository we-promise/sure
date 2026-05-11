class SavingsGoalAccount < ApplicationRecord
  belongs_to :savings_goal
  belongs_to :account

  validates :account_id, uniqueness: { scope: :savings_goal_id }
end
