class BudgetPlanAccount < ApplicationRecord
  belongs_to :budget_plan
  belongs_to :account

  validates :account_id, uniqueness: { scope: :budget_plan_id }
end
