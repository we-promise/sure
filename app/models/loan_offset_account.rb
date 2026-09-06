class LoanOffsetAccount < ApplicationRecord
  belongs_to :loan
  belongs_to :account

  validates :account_id, uniqueness: { scope: :loan_id }
  validate :account_is_asset
  validate :account_matches_loan_currency
  validate :account_belongs_to_loan_family
  validate :account_is_not_loan_account
  validate :account_is_visible_to_every_loan_viewer

  after_commit :clear_loan_projection_cache, on: %i[create destroy]

  class << self
    def eligible_accounts_for(loan, viewer:)
      return Account.none unless loan.account && viewer

      Account.accessible_by(viewer)
        .where(family_id: loan.account.family_id, classification: "asset", currency: loan.account.currency)
        .where.not(id: loan.account.id)
        .select { |account| new(loan: loan, account: account).valid? }
    end

    def invalidate_for_sharing_change!(account)
      return if account.nil?

      loan_ids = Account.where(id: account.id, accountable_type: "Loan").select(:accountable_id)
      where(account_id: account.id).or(where(loan_id: loan_ids)).find_each(&:destroy!)
    end
  end

  private

    def account_is_asset
      return unless account
      errors.add(:account, "must be an asset account") unless account.asset?
    end

    def account_matches_loan_currency
      return unless account && loan_account
      return if account.currency == loan_account.currency

      errors.add(:account, "must use the same currency as the loan")
    end

    def account_belongs_to_loan_family
      return unless account && loan_account
      return if account.family_id == loan_account.family_id

      errors.add(:account, "must belong to the same family as the loan")
    end

    def account_is_not_loan_account
      return unless account && loan_account
      return unless account.id == loan_account.id

      errors.add(:account, "cannot be the loan account")
    end

    def account_is_visible_to_every_loan_viewer
      return unless account && loan_account

      inaccessible_users = loan_viewers.reject { |user| account.shared_with?(user) }
      return if inaccessible_users.empty?

      names = inaccessible_users.map(&:display_name).join(", ")
      errors.add(:account, "must be visible to every loan viewer (missing: #{names})")
    end

    def loan_account
      loan&.account
    end

    def loan_viewers
      loan_account.family.users.select { |user| loan_account.shared_with?(user) }
    end

    def clear_loan_projection_cache
      loan&.invalidate_offset_cache!
    end
end
