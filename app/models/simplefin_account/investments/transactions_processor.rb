# SimpleFin Investment transactions processor
# Processes investment-specific transactions like trades, dividends, etc.
class SimplefinAccount::Investments::TransactionsProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return unless simplefin_account.current_account&.accountable_type == "Investment"
    return unless simplefin_account.raw_transactions_payload.present?

    transactions_data = simplefin_account.raw_transactions_payload

    transactions_data.each do |transaction_data|
      process_investment_transaction(transaction_data)
    end
  end

  private
    attr_reader :simplefin_account

    def account
      simplefin_account.current_account
    end

    def process_investment_transaction(transaction_data)
      data = transaction_data.with_indifferent_access

      amount = parse_amount(data[:amount])
      posted_date = parse_date(data[:posted])
      external_id = "simplefin_#{data[:id]}"

      # Use the unified import adapter for consistent handling
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: account.currency,
        date: posted_date,
        name: data[:description] || "Investment transaction",
        source: "simplefin"
      )
    rescue => e
      Rails.logger.error("Failed to process SimpleFin investment transaction #{data[:id]}: #{e.message}")
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def parse_amount(amount_value)
      parsed_amount = case amount_value
      when String
        BigDecimal(amount_value)
      when Numeric
        BigDecimal(amount_value.to_s)
      else
        BigDecimal("0")
      end

      # SimpleFin uses banking convention, Maybe expects opposite
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin investment transaction amount: #{amount_value.inspect} - #{e.message}"
      BigDecimal("0")
    end

    def parse_date(date_value)
      case date_value
      when String
        Date.parse(date_value)
      when Integer, Float
        Time.at(date_value).to_date
      when Time, DateTime
        date_value.to_date
      when Date
        date_value
      else
        Rails.logger.error("SimpleFin investment transaction has invalid date value: #{date_value.inspect}")
        raise ArgumentError, "Invalid date format: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse SimpleFin investment transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end
end
