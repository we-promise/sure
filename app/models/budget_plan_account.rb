class BudgetPlanAccount < ApplicationRecord
  belongs_to :budget_plan
  belongs_to :account

  validates :account_id, uniqueness: { scope: :budget_plan_id }
  validate :account_must_belong_to_plan_family

  private
    def account_must_belong_to_plan_family
      return if budget_plan.nil? || account.nil?
      return if account.family_id == budget_plan.family_id

      errors.add(:account, :must_belong_to_family)
    end
end
