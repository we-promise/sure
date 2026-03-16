class MercuryAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :mercury_item

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Helper to get account using account_providers system
  def current_account
    account
  end

  def upsert_mercury_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Map Mercury field names to our field names
    # Mercury API fields: id, name, currentBalance, availableBalance, status, type, kind,
    #                     legalBusinessName, nickname, routingNumber, accountNumber, etc.
    account_name = snapshot[:nickname].presence || snapshot[:name].presence || snapshot[:legalBusinessName].presence

    update!(
      current_balance: snapshot[:currentBalance] || snapshot[:current_balance] || 0,
      currency: "USD",  # Mercury is US-only, always USD
      name: account_name,
      account_id: snapshot[:id]&.to_s,
      account_status: snapshot[:status],
      provider: "mercury",
      institution_metadata: {
        name: "Mercury",
        domain: "mercury.com",
        url: "https://mercury.com",
        account_type: snapshot[:type],
        account_kind: snapshot[:kind],
        legal_business_name: snapshot[:legalBusinessName],
        available_balance: snapshot[:availableBalance]
      }.compact,
      raw_payload: account_snapshot
    )
  end

  def upsert_mercury_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Mercury account #{id}, defaulting to USD")
    end
end
