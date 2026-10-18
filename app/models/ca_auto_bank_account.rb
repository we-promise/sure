class CaAutoBankAccount < ApplicationRecord
  encrypts :deposit_metadata

  belongs_to :ca_auto_bank_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :uid, uniqueness: { scope: :ca_auto_bank_item_id }
  validates :uid, :report_uid, :name, presence: true
  validates :kind, inclusion: { in: %w[libero time_deposit] }
  validates :current_balance, numericality: { greater_than_or_equal_to: 0 }

  def currency
    "EUR"
  end

  def expected_subtype
    kind == "libero" ? "savings" : "cd"
  end

  def usable_account
    linked = account
    owner = ca_auto_bank_item.owner
    return unless linked && owner&.active? && owner.family_id == ca_auto_bank_item.family_id
    return unless linked.family_id == ca_auto_bank_item.family_id && linked.owner_id == owner.id
    return unless linked.depository? && linked.accountable.subtype == expected_subtype && linked.currency == "EUR"
    return unless linked.active? && !linked.disabled? && !linked.pending_deletion?
    return unless linked.account_providers.where.not(id: account_provider.id).none?

    linked
  end

  def ensure_link!(bootstrap:)
    return account_provider if account_provider && usable_account
    raise Provider::CaAutoBank::Error.new(:account_conflict) if account_provider || !bootstrap

    linked = ca_auto_bank_item.family.accounts.create!(
      accountable: Depository.new(subtype: expected_subtype), name: name, balance: 0, currency: "EUR",
      institution_name: "CA Auto Bank", institution_domain: "ca-autobank.it", owner: ca_auto_bank_item.owner
    )
    create_account_provider!(account: linked)
  end

  def linkable_to?(_account)
    false
  end
end
