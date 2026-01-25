class EnableBankingAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :enable_banking_item

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :uid, presence: true, uniqueness: { scope: :enable_banking_item_id }

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Returns the API account ID (UUID) for Enable Banking API calls
  # The Enable Banking API requires a valid UUID for balance/transaction endpoints
  # Falls back to raw_payload["uid"] for existing accounts that have the wrong account_id stored
  def api_account_id
    # Check if account_id looks like a valid UUID (not an identification_hash)
    if account_id.present? && account_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
      account_id
    else
      # Fall back to raw_payload for existing accounts with incorrect account_id
      raw_payload&.dig("uid") || account_id || uid
    end
  end

  # Map PSD2 cash_account_type codes to user-friendly names
  # Based on ISO 20022 External Cash Account Type codes
  def account_type_display
    return nil unless account_type.present?

    type_mappings = {
      "CACC" => "Current/Checking Account",
      "SVGS" => "Savings Account",
      "CARD" => "Card Account",
      "CRCD" => "Credit Card",
      "LOAN" => "Loan Account",
      "MORT" => "Mortgage Account",
      "ODFT" => "Overdraft Account",
      "CASH" => "Cash Account",
      "TRAN" => "Transacting Account",
      "SALA" => "Salary Account",
      "MOMA" => "Money Market Account",
      "NREX" => "Non-Resident External Account",
      "TAXE" => "Tax Account",
      "TRAS" => "Cash Trading Account",
      "ONDP" => "Overnight Deposit"
    }

    type_mappings[account_type.upcase] || account_type.titleize
  end

  def upsert_enable_banking_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Map Enable Banking field names to our field names
    # Enable Banking API returns: { uid, iban, account_id: { iban }, currency, cash_account_type, ... }
    # account_id can be a hash with iban, or an array of account identifiers
    raw_account_id = snapshot[:account_id]
    account_id_data = if raw_account_id.is_a?(Hash)
      raw_account_id
    elsif raw_account_id.is_a?(Array) && raw_account_id.first.is_a?(Hash)
      # If it's an array of hashes, find the one with iban
      raw_account_id.find { |item| item[:iban].present? } || {}
    else
      {}
    end

    update!(
      current_balance: nil, # Balance fetched separately via /accounts/{uid}/balances
      currency: parse_currency(snapshot[:currency]) || "EUR",
      name: build_account_name(snapshot),
      # account_id stores the API UUID for fetching balances/transactions
      account_id: snapshot[:uid],
      # uid is the stable identifier (identification_hash) for matching accounts across sessions
      uid: snapshot[:identification_hash] || snapshot[:uid],
      iban: account_id_data[:iban] || snapshot[:iban],
      account_type: snapshot[:cash_account_type] || snapshot[:account_type],
      account_status: "active",
      provider: "enable_banking",
      institution_metadata: {
        name: enable_banking_item&.aspsp_name,
        aspsp_name: enable_banking_item&.aspsp_name
      }.compact,
      raw_payload: account_snapshot
    )
  end

  def upsert_enable_banking_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def build_account_name(snapshot)
      # Try to build a meaningful name from the account data
      raw_account_id = snapshot[:account_id]
      account_id_data = if raw_account_id.is_a?(Hash)
        raw_account_id
      elsif raw_account_id.is_a?(Array) && raw_account_id.first.is_a?(Hash)
        raw_account_id.find { |item| item[:iban].present? } || {}
      else
        {}
      end
      iban = account_id_data[:iban] || snapshot[:iban]

      if snapshot[:name].present?
        snapshot[:name]
      elsif iban.present?
        # Use last 4 digits of IBAN for privacy
        "Account ...#{iban[-4..]}"
      else
        "Enable Banking Account"
      end
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for EnableBanking account #{id}, defaulting to EUR")
    end
end
