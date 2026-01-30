class SavingContribution < ApplicationRecord
  include Monetizable

  belongs_to :saving_goal
  belongs_to :budget, optional: true

  monetize :amount

  enum :source, { manual: "manual", auto: "auto", initial_balance: "initial_balance" }, default: :manual

  validates :amount, numericality: { greater_than: 0 }
  validates :month, presence: true
  validates :currency, presence: true

  validate :currency_matches_goal

  after_create :update_goal_current_amount
  after_destroy :update_goal_current_amount
  after_update :update_goal_current_amount

  private

    def currency_matches_goal
      return if currency.blank? || saving_goal.nil?

      if currency != saving_goal.currency
        errors.add(:currency, "must match saving goal currency")
      end
    end

    def update_goal_current_amount
      return if saving_goal.nil? || saving_goal.destroyed?

      total_amount = saving_goal.saving_contributions.sum do |contribution|
        contribution.amount_money.exchange_to(saving_goal.currency)
      end

      saving_goal.update!(current_amount: total_amount.amount)
    end
end
