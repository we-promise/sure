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
      # Handle both string and symbol keys
      data = transaction_data.with_indifferent_access


      # Convert SimpleFin transaction to internal Transaction format
      amount = parse_amount(data[:amount], account.currency)
      posted_date = parse_date(data[:posted])

      # Use plaid_id field for external ID (works for both Plaid and SimpleFin)
      external_id = "simplefin_#{data[:id]}"

      # Check if entry already exists
      existing_entry = Entry.find_by(plaid_id: external_id)

      unless existing_entry
        # Create the transaction (entryable)
        transaction = Transaction.new(
          external_id: external_id
        )

        # Create the entry with the transaction
        Entry.create!(
          account: account,
          name: data[:description] || "Unknown transaction",
          amount: amount,
          date: posted_date,
          currency: account.currency,
          entryable: transaction,
          plaid_id: external_id
        )
      end
    rescue => e
      Rails.logger.error("Failed to process SimpleFin transaction #{data[:id]}: #{e.message}")
      # Don't fail the entire sync for one bad transaction
    end

    def parse_amount(amount_value, currency)
      parsed_amount = case amount_value
      when String
        BigDecimal(amount_value)
      when Numeric
        BigDecimal(amount_value.to_s)
      else
        BigDecimal("0")
      end

      # SimpleFin uses banking convention (expenses negative, income positive)
      # Sure expects opposite convention (expenses positive, income negative)
      # So we negate the amount to convert from SimpleFin to Sure format
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin transaction amount: #{amount_value.inspect} - #{e.message}"
      BigDecimal("0")
    end

    def parse_date(date_value)
      case date_value
      when String
        Date.parse(date_value)
      when Integer, Float
        # Unix timestamp
        Time.at(date_value).to_date
      when Time, DateTime
        date_value.to_date
      when Date
        date_value
      else
        Rails.logger.error("SimpleFin transaction has invalid date value: #{date_value.inspect}")
        raise ArgumentError, "Invalid date format: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse SimpleFin transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end
end
