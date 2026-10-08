# An account the user has picked to fund their retirement plan.
# With none picked, the plan uses the default set: the cash, investment and
# crypto accounts the user counts in their finances.
class RetirementPlan::FundingAccount < ApplicationRecord
  self.table_name = "retirement_plan_accounts"

  belongs_to :retirement_plan
  belongs_to :account

  validates :account_id, uniqueness: { scope: :retirement_plan_id }
  validate :account_is_in_the_users_finances

  private
    # Only accounts the plan's user counts in their own finances, so a link
    # can never pull another member's unshared balance into a projection.
    def account_is_in_the_users_finances
      return if account.nil? || retirement_plan.nil?
      return if retirement_plan.eligible_funding_accounts.exists?(id: account.id)

      errors.add(:account, :invalid)
    end
end
