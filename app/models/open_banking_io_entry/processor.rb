class OpenBankingIoEntry::Processor
  include CurrencyNormalizable

  SOURCE = "open_banking_io".freeze
  # ISO 20022 credit/debit indicators. Amounts arrive as an UNSIGNED magnitude,
  # so the indicator is what determines the sign.
  DEBIT_INDICATOR = "DBIT".freeze
  CREDIT_INDICATOR = "CRDT".freeze
  # ISO 20022 entry status. Anything other than BOOK (booked) is treated as pending.
  BOOKED_STATUS = "BOOK".freeze

  def self.canonical_external_id(open_banking_io_transaction)
    data = open_banking_io_transaction.with_indifferent_access
    "open_banking_io_#{data[:id]}"
  end

  def self.pending?(open_banking_io_transaction)
    data = open_banking_io_transaction.with_indifferent_access
    data[:status].to_s.upcase != BOOKED_STATUS
  end

  def initialize(open_banking_io_transaction, open_banking_io_account:)
    @open_banking_io_transaction = open_banking_io_transaction
    @open_banking_io_account = open_banking_io_account
  end

  def process
    unless account.present?
      Rails.logger.warn "OpenBankingIoEntry::Processor - No linked account for open_banking_io_account #{open_banking_io_account.id}, skipping transaction #{external_id}"
      return nil
    end

    date_value = date
    return nil if date_value.nil?

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date_value,
      name: name,
      source: SOURCE,
      notes: notes,
      extra: extra_metadata
    )
  rescue ArgumentError => e
    Rails.logger.error "OpenBankingIoEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "OpenBankingIoEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  rescue => e
    Rails.logger.error "OpenBankingIoEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise StandardError.new("Unexpected error importing transaction: #{e.message}")
  end

  private

    attr_reader :open_banking_io_transaction, :open_banking_io_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= open_banking_io_account.current_account
    end

    def data
      @data ||= open_banking_io_transaction.with_indifferent_access
    end

    def external_id
      @external_id ||= self.class.canonical_external_id(data)
    end

    def debit?
      data[:credit_debit_indicator].to_s.upcase == DEBIT_INDICATOR
    end

    # open-banking.io reports amounts as an UNSIGNED magnitude plus a credit/debit
    # indicator. Sure stores expenses (money out / debit) as POSITIVE and income
    # (money in / credit) as NEGATIVE, so we sign the magnitude off the indicator.
    def amount
      magnitude = case data[:amount]
      when String
        BigDecimal(data[:amount])
      when Numeric
        BigDecimal(data[:amount].to_s)
      else
        BigDecimal("0")
      end.abs

      debit? ? magnitude : -magnitude
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse open-banking.io transaction amount: #{e.class}"
      raise ArgumentError, "Invalid transaction amount"
    end

    def date
      raw = data[:booking_date].presence || data[:value_date].presence || data[:transaction_date].presence
      return nil if raw.blank?

      case raw
      when Date
        raw
      when Time, DateTime
        raw.to_date
      else
        Date.parse(raw.to_s)
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse open-banking.io transaction date: #{e.class}")
      raise ArgumentError, "Unable to parse transaction date"
    end

    def name
      counterparty = debit? ? data[:creditor_name] : data[:debtor_name]
      counterparty.presence || data[:remittance_information].presence || I18n.t("transactions.unknown_name")
    end

    def notes
      parts = []
      remittance = data[:remittance_information].to_s.strip.presence
      parts << remittance if remittance.present? && remittance != name
      note = data[:note].to_s.strip.presence
      parts << note if note.present?
      reference = data[:reference_number].to_s.strip.presence
      parts << "#{t('open_banking_io_entry.notes.reference')}: #{reference}" if reference.present?
      parts.presence&.join(" | ")
    end

    def currency
      parse_currency(data[:currency]) || open_banking_io_account.currency || account&.currency || "EUR"
    end

    def extra_metadata
      {
        "open_banking_io" => {
          "pending" => pending?,
          "credit_debit_indicator" => data[:credit_debit_indicator],
          "status" => data[:status],
          "bank_transaction_code" => data[:bank_transaction_code],
          "reference_number" => data[:reference_number],
          "merchant_category_code" => data[:merchant_category_code]
        }.compact
      }
    end

    def pending?
      self.class.pending?(data)
    end

    def t(key, **options)
      I18n.t(key, **options)
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in open-banking.io transaction #{external_id}, falling back to account currency")
    end
end
