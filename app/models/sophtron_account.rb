class SophtronAccount < ApplicationRecord
  include CurrencyNormalizable

  belongs_to :sophtron_item

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Helper to get account using account_providers system
  def current_account
    account
  end

  def upsert_sophtron_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Map Sophtron field names to our field names
    assign_attributes(
      name: snapshot[:account_name],
      account_id: snapshot[:account_id],
      currency: parse_currency(snapshot[:balance_currency])|| "USD",
      balance: parse_balance(snapshot[:balance]),
      available_balance: parse_balance(snapshot[:"available-balance"]),
      account_type: snapshot["account_type"] || "unknown",
      account_sub_type: snapshot["sub_type"] || "unknown",
      last_updated: parse_balance_date(snapshot[:"last_updated"]),
      raw_payload: account_snapshot,
      customer_id: snapshot["customer_id"],
      member_id: snapshot["member_id"]
    )

    save!
  end

  def upsert_sophtron_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Sophtron account #{id}, defaulting to USD")
    end


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
      Rails.logger.warn("Invalid balance date for Sophtron account: #{balance_date_value}")
      nil
    end
    def has_balance
      return if balance.present? || available_balance.present?
      errors.add(:base, "Sophtron account must have either current or available balance")
    end
end
