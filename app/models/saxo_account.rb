class SaxoAccount < ApplicationRecord
  include Encryptable

  belongs_to :saxo_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  serialize :raw_payload, coder: JSON
  serialize :raw_holdings_payload, coder: JSON
  serialize :raw_transactions_payload, coder: JSON
  encrypts :raw_payload
  encrypts :raw_holdings_payload
  encrypts :raw_transactions_payload

  validates :account_id, :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :saxo_item_id }

  def subtype
    %w[PEA PEA_PME].include?(account_type) ? "pea" : "brokerage"
  end

  def current_account
    account
  end

  def link!(target = nil)
    with_lock do
      raise ArgumentError, "Account is already linked" if account_provider.present?
      target ||= saxo_item.family.accounts.create!(
        name: name,
        currency: currency,
        balance: current_balance || 0,
        cash_balance: cash_balance || 0,
        accountable: Investment.new(subtype: subtype)
      )
      target.with_lock do
        unless target.family_id == saxo_item.family_id && target.accountable_type == "Investment" &&
            target.currency == currency && target.account_providers.empty?
          raise ArgumentError, "Select an unlinked investment account in the same currency and family"
        end
        create_account_provider!(account: target)
        update!(history_synced_on: nil)
      end
      target
    end
  end
end
