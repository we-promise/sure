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
      description = data[:description] || data[:transaction_description]
      remittance_name = remittance_name_candidate

      if description.present?
        return remittance_name if prefer_remittance_name?(description, remittance_name)
        return description
      end

      # Determine counterparty based on transaction direction
      # For outgoing payments (DBIT), counterparty is the creditor (who we paid)
      # For incoming payments (CRDT), counterparty is the debtor (who paid us)
      counterparty = if credit_debit_indicator == "CRDT"
        data.dig(:debtor, :name) || data[:debtor_name]
      else
        data.dig(:creditor, :name) || data[:creditor_name]
      end

      if counterparty.present? && !counterparty.match?(/\ACARD-\d+\z/i)
        return counterparty
      end

      # Fall back to bank_transaction_code description
      bank_tx_description = data.dig(:bank_transaction_code, :description)
      return remittance_name if prefer_remittance_name?(bank_tx_description, remittance_name)
      return bank_tx_description if bank_tx_description.present?

      return remittance_name if remittance_name.present?

      # Final fallback: use transaction type indicator
      credit_debit_indicator == "CRDT" ? "Incoming Transfer" : "Outgoing Transfer"
    end

    def remittance_name_candidate
      candidates = remittance_lines.map { |line| cleanup_remittance_line(line) }.compact
      return nil if candidates.empty?

      candidates.each do |cleaned|
        return cleaned unless reference_like?(cleaned) || technicality_score(cleaned) >= 7
      end

      candidates.first
    end

    def cleanup_remittance_line(line)
      return nil if line.blank?

      issued_by_match = line.to_s.match(/issued by\s+(.+)\z/i)
      cleaned = (issued_by_match ? issued_by_match[1] : line).to_s.strip
      cleaned = cleaned.gsub(/\s+/, " ")
      cleaned = cleaned.sub(/\s+CARTE\s+\d+\z/i, "")
      cleaned.presence&.truncate(100)
    end

    def prefer_remittance_name?(description, remittance_name)
      return false if description.blank? || remittance_name.blank?

      normalized_description = description.to_s.strip
      normalized_remittance = remittance_name.to_s.strip
      return false if normalized_description.blank? || normalized_remittance.blank?
      return false if normalized_description.casecmp?(normalized_remittance)

      reference_like?(normalized_description) ||
        (
          significantly_more_informative?(normalized_remittance, normalized_description) &&
          !more_technical_than?(normalized_remittance, normalized_description)
        )
    end

    def reference_like?(value)
      normalized = value.to_s.strip
      return false if normalized.blank?

      normalized.match?(/\ACARD-\d{6,}\z/i) ||
        normalized.match?(/\A[A-Z0-9]{10,}\z/) ||
        normalized.match?(/\A[A-Z0-9]+(?:[-_][A-Z0-9]+){2,}\z/)
    end

    def significantly_more_informative?(candidate, baseline)
      informativeness_score(candidate) >= informativeness_score(baseline) + 4
    end

    def more_technical_than?(candidate, baseline)
      technicality_score(candidate) > technicality_score(baseline)
    end

    def informativeness_score(value)
      text = value.to_s.strip
      return 0 if text.blank?

      words = text.split(/\s+/)
      alpha_words = words.select { |word| word.match?(/[[:alpha:]]/) }
      alpha_word_count = alpha_words.size
      unique_alpha_word_count = alpha_words.map { |word| word.downcase.gsub(/[^[:alpha:]]/, "") }.reject(&:blank?).uniq.size

      alpha_count = text.scan(/[[:alpha:]]/).size
      digit_count = text.scan(/\d/).size
      symbol_count = text.scan(/[^\p{Alnum}\s]/).size
      mixed_case_bonus = text.match?(/[[:upper:]]/) && text.match?(/[[:lower:]]/) ? 2 : 0

      (alpha_word_count * 2) + unique_alpha_word_count + mixed_case_bonus - digit_count - (symbol_count / 2)
    end

    def technicality_score(value)
      text = value.to_s.strip
      return 0 if text.blank?

      words = text.split(/\s+/)
      uppercase_words = words.count { |word| word.match?(/\A[[:upper:]\d\W]+\z/) }
      uppercase_ratio = words.empty? ? 0.0 : (uppercase_words.to_f / words.size)

      digit_count = text.scan(/\d/).size
      symbol_count = text.scan(/[^\p{Alnum}\s]/).size
      date_token_count = text.scan(/\b\d{1,4}[\/-]\d{1,4}(?:[\/-]\d{1,4})?\b/).size

      score = 0
      score += 3 if reference_like?(text)
      score += 2 if uppercase_ratio >= 0.8 && words.size >= 3
      score += digit_count
      score += (symbol_count / 2)
      score += (date_token_count * 2)
      score
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
      return nil if remittance_lines.empty?

      remittance_lines.join("\n")
    end

    def remittance_lines
      remittance = data[:remittance_information]
      return [ remittance.to_s.strip ].reject(&:blank?) if remittance.is_a?(String)
      return [] unless remittance.is_a?(Array)

      remittance.map(&:to_s).map(&:strip).reject(&:blank?)
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
