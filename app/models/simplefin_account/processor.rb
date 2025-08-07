class SimplefinAccount::Processor
  attr_reader :simplefin_account

  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    ensure_account_exists
    process_transactions
  end

  private

    def ensure_account_exists
      return if simplefin_account.account.present?

      # This should not happen in normal flow since accounts are created manually
      # during setup, but keeping as safety check
      Rails.logger.error("SimpleFin account #{simplefin_account.id} has no associated Account - this should not happen after manual setup")
    end

    def process_transactions
      return unless simplefin_account.raw_transactions_payload.present?

      account = simplefin_account.account
      transactions_data = simplefin_account.raw_transactions_payload

      transactions_data.each do |transaction_data|
        process_transaction(account, transaction_data)
      end
    end

    def process_transaction(account, transaction_data)
      # Convert SimpleFin transaction to internal Transaction format
      amount_cents = parse_amount(transaction_data[:amount], account.currency)
      posted_date = parse_date(transaction_data[:posted])

      transaction_attributes = {
        account: account,
        name: transaction_data[:description] || "Unknown transaction",
        amount: Money.new(amount_cents, account.currency),
        date: posted_date,
        currency: account.currency,
        raw_data: transaction_data
      }

      # Use external ID to prevent duplicates
      external_id = "simplefin_#{transaction_data[:id]}"

      Transaction.find_or_create_by(external_id: external_id) do |transaction|
        transaction.assign_attributes(transaction_attributes)
      end
    rescue => e
      Rails.logger.error("Failed to process SimpleFin transaction #{transaction_data[:id]}: #{e.message}")
      # Don't fail the entire sync for one bad transaction
    end

    def parse_amount(amount_value, currency)
      case amount_value
      when String
        (BigDecimal(amount_value) * 100).to_i
      when Numeric
        (amount_value * 100).to_i
      else
        0
      end
    rescue ArgumentError
      0
    end

    def parse_date(date_value)
      case date_value
      when String
        Date.parse(date_value)
      when Integer
        # Unix timestamp
        Time.at(date_value).to_date
      else
        Rails.logger.error("SimpleFin transaction has invalid date value: #{date_value.inspect}")
        raise ArgumentError, "Invalid date format: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse SimpleFin transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end
end
