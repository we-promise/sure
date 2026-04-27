class GocardlessEntry::Processor
  # gocardless_transaction is a raw Hash from the GoCardless Nordigen API:
  # {
  #   "transactionId", "internalTransactionId",
  #   "bookingDate", "valueDate",
  #   "transactionAmount" => { "amount", "currency" },
  #   "creditorName", "debtorName",
  #   "remittanceInformationUnstructured", "remittanceInformationStructured",
  #   "bankTransactionCode",              # ISO 20022 domain code (e.g. "PMNT")
  #   "proprietaryBankTransactionCode",   # Bank-specific label (e.g. "PURCHASE", "SALARY")
  #   "_pending" => true                  # added by Importer for pending transactions
  # }
  def initialize(gocardless_transaction, gocardless_account:, import_adapter: nil)
    @gocardless_transaction = gocardless_transaction
    @gocardless_account     = gocardless_account
    @import_adapter         = import_adapter
  end

  def process
    unless account.present?
      txn_id = data[:internalTransactionId].presence || data[:transactionId].presence || "(unknown)"
      Rails.logger.warn "GocardlessEntry::Processor - No linked account for gocardless_account #{gocardless_account.id}, skipping transaction #{txn_id}"
      return nil
    end

    begin
      import_adapter.import_transaction(
        external_id: external_id,
        amount:      amount,
        currency:    currency,
        date:        date,
        name:        name,
        source:      "gocardless",
        extra:       extra
      )
    rescue ArgumentError => e
      Rails.logger.error "GocardlessEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error "GocardlessEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError, "Failed to import transaction: #{e.message}"
    rescue => e
      Rails.logger.error "GocardlessEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      raise StandardError, "Unexpected error importing transaction: #{e.message}"
    end
  end

  private

    attr_reader :gocardless_transaction, :gocardless_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= gocardless_account.current_account
    end

    def data
      @data ||= gocardless_transaction.with_indifferent_access
    end

    def pending?
      data[:_pending] == true
    end

    def proprietary_transaction_code
      data[:proprietaryBankTransactionCode].presence
    end

    def external_id
      # internalTransactionId is always unique; transactionId can collide across accounts
      id = data[:internalTransactionId].presence || data[:transactionId].presence
      raise ArgumentError, "GoCardless transaction missing required identifier (transactionId or internalTransactionId)" unless id
      "gocardless_#{id}"
    end

    def amount
      raw = data.dig(:transactionAmount, :amount).to_s
      # GoCardless (Nordigen) uses banking convention: negative = debit/expense (outflow),
      # positive = credit/income (inflow). App convention is the opposite.
      # Identical to SimpleFIN: simply negate the signed value.
      -BigDecimal(raw)
    rescue ArgumentError => e
      Rails.logger.error "GocardlessEntry::Processor - Failed to parse amount '#{raw}': #{e.message}"
      raise
    end

    def currency
      data.dig(:transactionAmount, :currency).presence || gocardless_account.currency || "GBP"
    end

    def date
      # Pending transactions may not have a bookingDate yet — fall back to valueDate
      date_str = (pending? ? data[:valueDate].presence || data[:bookingDate] : data[:bookingDate].presence || data[:valueDate])
      raise ArgumentError, "GoCardless transaction missing date" if date_str.blank?
      Date.parse(date_str.to_s)
    rescue ArgumentError, TypeError => e
      Rails.logger.error "GocardlessEntry::Processor - Failed to parse date '#{date_str}': #{e.message}"
      raise ArgumentError, "Unable to parse transaction date: #{date_str.inspect}"
    end

    def name
      data[:remittanceInformationUnstructured].presence ||
        data[:remittanceInformationStructured].presence ||
        data[:creditorName].presence ||
        data[:debtorName].presence ||
        proprietary_transaction_code.presence ||
        "GoCardless transaction"
    end

    def extra
      gc = {}
      gc[:pending]                      = true                                    if pending?
      gc[:transaction_code]             = data[:bankTransactionCode]              if data[:bankTransactionCode].present?
      gc[:proprietary_transaction_code] = data[:proprietaryBankTransactionCode]   if data[:proprietaryBankTransactionCode].present?
      gc.empty? ? nil : { gocardless: gc }
    end
end
