# frozen_string_literal: true

class WiseAccount < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  belongs_to :wise_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  scope :with_linked,    -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered,        -> { order(created_at: :desc) }

  def current_account
    account
  end

  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    reload_account_provider
    account_provider
  end

  # Creates a new family Account, links it to this WiseAccount via AccountProvider,
  # and returns the created account. Wrapped in a transaction so a linking failure
  # never leaves an orphan manual account behind.
  def provision_account!(family:, accountable_type:, balance: nil)
    raise ArgumentError, "Invalid accountable type: #{accountable_type}" unless ALLOWED_ACCOUNTABLE_TYPES.include?(accountable_type)

    ActiveRecord::Base.transaction do
      account = family.accounts.create!(
        name:        name,
        balance:     balance.presence || current_balance || 0,
        currency:    currency || "USD",
        accountable: accountable_type.constantize.new
      )
      ensure_account_provider!(account)
      account
    end
  end
end
