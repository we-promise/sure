class Trading212Account < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include Trading212Account::DataHelpers

  if encryption_ready?
    encrypts :raw_positions_payload
    encrypts :raw_orders_payload
    encrypts :raw_dividends_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :trading212_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :trading212_account_id, uniqueness: { scope: :trading212_item_id, allow_nil: true }

  def current_account
    account || linked_account
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "Trading212Account", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "Trading212Account##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "trading212",
      family: trading212_item.family,
      provider_key: "trading212"
    )
    nil
  end

  def instruments_map
    trading212_item.instruments_map
  end
end
