class SharesightAccount < ApplicationRecord
  include Encryptable
  include SharesightAccount::DataHelpers

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_holdings_payload
    encrypts :raw_trades_payload
    encrypts :raw_payouts_payload
    encrypts :raw_cash_transactions_payload
  end

  belongs_to :sharesight_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :sharesight_account_id, uniqueness: { scope: :sharesight_item_id, allow_nil: true }

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
      .find_or_initialize_by(provider_type: "SharesightAccount", provider_id: id)
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
      message: "SharesightAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "sharesight",
      family: sharesight_item.family,
      provider_key: "sharesight"
    )
    nil
  end

  # Holding id => the currency it trades in, for trades and payouts that only
  # give the holding. Crypto's left out because Sharesight treats the coin as
  # its own currency (Bitcoin is priced at 1 BTC), so we book it in the
  # portfolio's currency instead.
  def holding_currencies
    @holding_currencies ||= Array(raw_holdings_payload).each_with_object({}) do |holding, map|
      code = holding.dig("instrument_currency", "code").presence || holding.dig("instrument", "currency_code")
      next if code.to_s.casecmp?(holding.dig("instrument", "code").to_s)

      currency = parse_currency(code)
      map[holding["id"].to_s] = currency if currency
    end
  end
end
