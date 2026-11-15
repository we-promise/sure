class FinancekitAccountLineage < ApplicationRecord
  ACCOUNT_ORIGINS = %w[created linked].freeze
  DISCARDED = "discarded".freeze

  belongs_to :family
  belongs_to :account, optional: true
  has_many :financekit_accounts, dependent: :restrict_with_error
  has_many :financekit_transactions, dependent: :destroy
  has_many :financekit_balance_observations, dependent: :destroy
  has_one :account_provider, as: :provider, dependent: :destroy

  scope :discarded, -> { where(status: DISCARDED) }

  # Only an account FinanceKit brought into existence is FinanceKit's to destroy.
  # A NULL origin predates the column and cannot be reclassified after the fact,
  # so it reads as linked: emptying an account the family created themselves is
  # recoverable, destroying it is not.
  def account_created_by_provider?
    account_origin == "created"
  end

  def discarded?
    status == DISCARDED
  end

  # A lineage outlives the connection that mapped it, so more than one item can
  # reference it -- a replacement device and the device it replaces, during the
  # window before the old one is revoked. Releasing links or purging data for one
  # of them must not touch a lineage another connection is still publishing into.
  def other_active_writer_than?(item)
    FinancekitAccount.joins(:financekit_item)
      .where(financekit_account_lineage_id: id, financekit_items: { status: "active" })
      .where.not(financekit_item_id: item.id).exists?
  end

  # A publisher credential covers every account in its connection. Fence its
  # queued uploads before releasing links, retaining identities for re-enrollment.
  #
  # Retain-only on purpose. This is the path the web unlink flow takes, where
  # unlinking an account has always meant keeping its history -- and where the
  # person is acting on one account, not consenting to delete everything the
  # connection imported into the others it covers. A discard comes from the
  # connection itself, through FinancekitItem#disconnect!.
  def disconnect!
    family.with_lock do
      family.financekit_items.where(id: financekit_accounts.select(:financekit_item_id))
        .where.not(status: "revoked").order(:id).each(&:disconnect!)
    end
  end
end
