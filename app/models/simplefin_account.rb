class SimplefinAccount < ApplicationRecord
  belongs_to :simplefin_item

  has_one :account, dependent: :destroy

  validates :name, :account_type, :currency, presence: true
  validate :has_balance

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
      return "USD" if currency_value.nil?

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
