class TradeRepublicAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include TradeRepublicAccount::DataHelpers

  if encryption_ready?
    encrypts :raw_positions_payload
    encrypts :raw_timeline_payload
  end

  belongs_to :trade_republic_item

  # The provider model can be loaded while Rails is booting before the
  # development schema cache has refreshed after a migration. Declaring the
  # type explicitly keeps the enum valid in that reload window as well.
  attribute :kind, :string, default: "portfolio"
  enum :kind, { portfolio: "portfolio", cash: "cash" }, default: :portfolio

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :trade_republic_account_id, uniqueness: { scope: :trade_republic_item_id, allow_nil: true }

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
      .find_or_initialize_by(provider_type: "TradeRepublicAccount", provider_id: id)
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
      message: "TradeRepublicAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "trade_republic",
      family: trade_republic_item.family,
      provider_key: "trade_republic"
    )
    nil
  end
end
