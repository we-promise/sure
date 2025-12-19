require "digest/md5"

class EnableBankingEntry::Processor
  include CurrencyNormalizable

  # enable_banking_transaction is the raw hash fetched from Enable Banking API
  # Transaction structure from Enable Banking:
  # {
  #   transaction_id, entry_reference, booking_date, value_date,
  #   transaction_amount: { amount, currency },
  #   creditor_name, debtor_name, remittance_information, ...
  # }
  def initialize(enable_banking_transaction, enable_banking_account:)
    @enable_banking_transaction = enable_banking_transaction
    @enable_banking_account = enable_banking_account
  end

  def process
    unless account.present?
      Rails.logger.warn "EnableBankingEntry::Processor - No linked account for enable_banking_account #{enable_banking_account.id}, skipping transaction #{external_id}"
      return nil
    end

    begin
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "enable_banking",
        merchant: merchant,
        notes: notes
      )
    rescue ArgumentError => e
      Rails.logger.error "EnableBankingEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error "EnableBankingEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      Rails.logger.error "EnableBankingEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private

    attr_reader :enable_banking_transaction, :enable_banking_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= enable_banking_account.current_account
    end

    def data
      @data ||= enable_banking_transaction.with_indifferent_access
    end

    def external_id
      id = data[:transaction_id].presence || data[:entry_reference].presence
      raise ArgumentError, "Enable Banking transaction missing required field 'transaction_id'" unless id
      "enable_banking_#{id}"
    end

    def name
      # Build name from available Enable Banking transaction fields
      # Priority: counterparty name > bank_transaction_code description > remittance_information

      # Determine counterparty based on transaction direction
      # For outgoing payments (DBIT), counterparty is the creditor (who we paid)
      # For incoming payments (CRDT), counterparty is the debtor (who paid us)
      counterparty = if credit_debit_indicator == "CRDT"
        data.dig(:debtor, :name) || data[:debtor_name]
      else
        data.dig(:creditor, :name) || data[:creditor_name]
      end

      return counterparty if counterparty.present?

      # Fall back to bank_transaction_code description
      bank_tx_description = data.dig(:bank_transaction_code, :description)
      return bank_tx_description if bank_tx_description.present?

      # Fall back to remittance_information
      remittance = data[:remittance_information]
      return remittance.first.truncate(100) if remittance.is_a?(Array) && remittance.first.present?

      # Final fallback: use transaction type indicator
      credit_debit_indicator == "CRDT" ? "Incoming Transfer" : "Outgoing Transfer"
    end

    def merchant
      # For outgoing payments (DBIT), merchant is the creditor (who we paid)
      # For incoming payments (CRDT), merchant is the debtor (who paid us)
      merchant_name = if credit_debit_indicator == "CRDT"
        data.dig(:debtor, :name) || data[:debtor_name]
      else
        data.dig(:creditor, :name) || data[:creditor_name]
      end

      return nil unless merchant_name.present?

      merchant_name = merchant_name.to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "enable_banking_merchant_#{merchant_id}",
          name: merchant_name,
          source: "enable_banking"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "EnableBankingEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
      end
    end

    def notes
      remittance = data[:remittance_information]
      return nil unless remittance.is_a?(Array) && remittance.any?

      remittance.join("\n")
    end

    def amount_value
      @amount_value ||= begin
        tx_amount = data[:transaction_amount] || {}
        raw_amount = tx_amount[:amount] || data[:amount] || "0"

        absolute_amount = case raw_amount
        when String
          BigDecimal(raw_amount).abs
        when Numeric
          BigDecimal(raw_amount.to_s).abs
        else
          BigDecimal("0")
        end

        # CRDT (credit) = money coming in = positive
        # DBIT (debit) = money going out = negative
        credit_debit_indicator == "CRDT" ? -absolute_amount : absolute_amount
      rescue ArgumentError => e
        Rails.logger.error "Failed to parse Enable Banking transaction amount: #{raw_amount.inspect} - #{e.message}"
        raise
      end
    end

    def credit_debit_indicator
      data[:credit_debit_indicator]
    end

    def amount
      # Enable Banking uses PSD2 Berlin Group convention: negative = debit (outflow), positive = credit (inflow)
      # Sure uses the same convention: negative = expense, positive = income
      # Therefore, use the amount as-is from the API without inversion
      amount_value
    end

    def currency
      tx_amount = data[:transaction_amount] || {}
      parse_currency(tx_amount[:currency]) || parse_currency(data[:currency]) || account&.currency || "EUR"
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Enable Banking transaction #{external_id}, falling back to account currency")
    end

    def date
      # Prefer booking_date, fall back to value_date
      date_value = data[:booking_date] || data[:value_date]

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
        Rails.logger.error("Enable Banking transaction has invalid date value: #{date_value.inspect}")
        raise ArgumentError, "Invalid date format: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Enable Banking transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end
end
