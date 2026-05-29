class RetirementBucketEntry < ApplicationRecord
  belongs_to :goal_retirement, class_name: "Goal::Retirement", foreign_key: :goal_retirement_id
  belongs_to :account

  validates :account_id, uniqueness: { scope: :goal_retirement_id }
  validate :account_belongs_to_family

  private
    def account_belongs_to_family
      return if account.nil? || goal_retirement.nil?
      errors.add(:account, :must_belong_to_family) unless account.family_id == goal_retirement.family_id
    end
end
