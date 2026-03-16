class CoinbaseAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :coinbase_item

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Create or update the AccountProvider link for this coinbase_account
  def ensure_account_provider!(linked_account = nil)
    acct = linked_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: "CoinbaseAccount", provider_id: id)
      .tap do |provider|
        provider.account = acct
        provider.save!
      end
  rescue => e
    Rails.logger.warn("Coinbase provider link ensure failed for #{id}: #{e.class} - #{e.message}")
    nil
  end

  def upsert_coinbase_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Map Coinbase field names to our field names
    update!(
      current_balance: snapshot[:balance] || snapshot[:current_balance],
      currency: parse_currency(snapshot[:currency]) || "USD",
      name: snapshot[:name],
      account_id: snapshot[:id]&.to_s,
      account_status: snapshot[:status],
      provider: snapshot[:provider],
      institution_metadata: {
        name: snapshot[:institution_name],
        logo: snapshot[:institution_logo]
      }.compact,
      raw_payload: account_snapshot
    )
  end

  def upsert_coinbase_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Coinbase account #{id}, defaulting to USD")
    end
end
