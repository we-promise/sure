class SimplefinAccount < ApplicationRecord
  include Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    encrypts :raw_holdings_payload
  end

  belongs_to :simplefin_item

  # Legacy association via foreign key (will be removed after migration)
  has_one :account, dependent: :nullify, foreign_key: :simplefin_account_id

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :account_type, :currency, presence: true
  validates :account_id, uniqueness: { scope: :simplefin_item_id, allow_nil: true }
  validate :has_balance

  # Helper to get account using new system first, falling back to legacy
  def current_account
    linked_account || account
  end

  # Ensure there is an AccountProvider link for this SimpleFin account and its current Account.
  # Safe and idempotent; returns the AccountProvider or nil if no account is associated yet.
  def ensure_account_provider!
    acct = current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "SimplefinAccount", provider_id: id)
      .tap do |p|
        p.account = acct
        p.save!
      end

    # Reload the association so future accesses don't return stale/nil value
    reload_account_provider

    provider
  rescue => e
    Rails.logger.warn("SimplefinAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}")
    nil
  end

  def upsert_simplefin_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Map SimpleFin field names to our field names
    update!(
      current_balance: parse_balance(snapshot[:balance]),
      available_balance: parse_balance(snapshot[:"available-balance"]),
      currency: parse_currency(snapshot[:currency]),
      account_type: snapshot["type"] || "unknown",
      account_subtype: snapshot["subtype"],
      name: snapshot[:name],
      account_id: snapshot[:id],
      balance_date: parse_balance_date(snapshot[:"balance-date"]),
      extra: snapshot[:extra],
      org_data: snapshot[:org],
      raw_payload: account_snapshot
    )
  end

  def upsert_simplefin_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def parse_balance(balance_value)
      return nil if balance_value.nil?

      case balance_value
      when String
        BigDecimal(balance_value)
      when Numeric
        BigDecimal(balance_value.to_s)
      else
        nil
      end
    rescue ArgumentError
      nil
    end

    def parse_currency(currency_value)
      return "USD" if currency_value.blank?

      # SimpleFin currency can be a 3-letter code or a URL for custom currencies
      if currency_value.start_with?("http")
        # For custom currency URLs, we'll just use the last part as currency code
        # This is a simplification - in production you might want to fetch the currency info
        begin
          URI.parse(currency_value).path.split("/").last.upcase
        rescue URI::InvalidURIError => e
          Rails.logger.warn("Invalid currency URI for SimpleFin account: #{currency_value}, error: #{e.message}")
          "USD"
        end
      else
        currency_value.upcase
      end
    end

    def parse_balance_date(balance_date_value)
      return nil if balance_date_value.nil?

      case balance_date_value
      when String
        Time.parse(balance_date_value)
      when Numeric
        Time.at(balance_date_value)
      when Time, DateTime
        balance_date_value
      else
        nil
      end
    rescue ArgumentError, TypeError
      Rails.logger.warn("Invalid balance date for SimpleFin account: #{balance_date_value}")
      nil
    end
    def has_balance
      return if current_balance.present? || available_balance.present?
      errors.add(:base, "SimpleFin account must have either current or available balance")
    end
end
