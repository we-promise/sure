class BinanceAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    encrypts :raw_holdings_payload
  end

  belongs_to :binance_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :binance_item_id, allow_nil: true }

  def current_account
    account
  end

  def ensure_account_provider!(linked_account = nil)
    acct = linked_account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "BinanceAccount", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload
    provider
  rescue => e
    Rails.logger.warn("BinanceAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}")
    nil
  end

  def upsert_from_binance!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    update!(
      current_balance: snapshot[:current_balance],
      cash_balance: snapshot[:cash_balance],
      currency: parse_currency(snapshot[:currency]) || "USD",
      name: snapshot[:name],
      account_id: snapshot[:account_id]&.to_s,
      account_status: snapshot[:status],
      account_type: snapshot[:account_type],
      provider: snapshot[:provider],
      institution_metadata: snapshot[:institution_metadata] || {},
      raw_payload: snapshot[:raw_payload] || account_snapshot,
      raw_holdings_payload: snapshot[:raw_holdings_payload] || raw_holdings_payload,
      last_holdings_sync: Time.current
    )
  end

  def upsert_transactions_snapshot!(transactions_snapshot)
    update!(raw_transactions_payload: transactions_snapshot)
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Binance account #{id}, defaulting to USD")
    end
end
