class FinecoAccount < ApplicationRecord
  EXTERNAL_ID = "fineco-investment".freeze

  include Encryptable

  encrypts :raw_position_metadata

  belongs_to :fineco_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :external_id, :name, :currency, presence: true
  validates :external_id, uniqueness: { scope: :fineco_item_id }
  validates :currency, inclusion: { in: [ "EUR" ] }

  def current_account
    account
  end

  def usable_account
    linked_account = current_account
    provider_link = account_provider
    return unless linked_account.present? && provider_link.present?
    return unless linked_account.family_id == fineco_item.family_id && linked_account.owner_id == fineco_item.owner_id
    return unless linked_account.accountable_type == "Investment" && linked_account.currency == "EUR"
    return unless linked_account.status == "active" && !linked_account.disabled? && !linked_account.pending_deletion?
    return unless linked_account.account_providers.where.not(id: provider_link.id).none?

    linked_account
  end

  def linkable_to?(account)
    account.accountable_type == "Investment"
  end

  def ensure_account_provider!(allow_bootstrap: false)
    existing = account_provider
    return existing if existing.present? && existing.account.present?

    if existing.present? || !allow_bootstrap
      raise FinecoItem::PortfolioImportError.new(:account_conflict)
    end

    FinecoAccount.transaction do
      account = fineco_item.family.accounts.create!(
        accountable: Investment.new,
        name: name,
        balance: 0,
        cash_balance: 0,
        currency: currency,
        institution_name: "FinecoBank",
        institution_domain: "finecobank.com",
        owner: fineco_item.owner
      )
      AccountProvider.create!(account: account, provider: self)
    end

    reload.account_provider
  end
end
