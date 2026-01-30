class SavingContribution < ApplicationRecord
  include Monetizable

  belongs_to :saving_goal
  belongs_to :budget, optional: true

  monetize :amount

  enum :source, { manual: "manual", auto: "auto", initial_balance: "initial_balance" }, default: :manual

  validates :amount, numericality: { greater_than: 0 }
  validates :month, presence: true
  validates :currency, presence: true

  after_create :update_goal_current_amount
  after_destroy :update_goal_current_amount
  after_update :update_goal_current_amount

  private

    def update_goal_current_amount
      saving_goal.update!(current_amount: saving_goal.saving_contributions.sum(:amount))
    end
end
