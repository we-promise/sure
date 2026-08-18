require "digest/md5"

class OpenBankingIoEntry::Processor
  include CurrencyNormalizable

  SOURCE = "open_banking_io".freeze
  # ISO 20022 credit/debit indicators. Amounts arrive as an UNSIGNED magnitude,
  # so the indicator is what determines the sign.
  DEBIT_INDICATOR = "DBIT".freeze
  CREDIT_INDICATOR = "CRDT".freeze
  VALID_INDICATORS = [ DEBIT_INDICATOR, CREDIT_INDICATOR ].freeze
  # ISO 20022 entry status, mirroring the service's own vocabulary
  # (BankingSyncService.NonBookedStatuses / PendingStatuses).
  #
  # Unknown MUST mean booked, never pending. BOOK and OTHR are both booked upstream, and a
  # bank that does not stamp status at all (PayPal DE, Belfius BE, BPER Banca) sends none --
  # treating those as pending made every transaction eligible for the stale-pending prune,
  # which destroys the entry and every user edit attached to it.
  BOOKED_STATUS = "BOOK".freeze
  PENDING_STATUSES = %w[PDNG PENDING HOLD].freeze
  # Cancelled and rejected entries are money that never moved; scheduled ones have not
  # happened yet. None of them belong in the ledger.
  SKIPPED_STATUSES = %w[CNCL RJCT SCHD].freeze

  def self.canonical_external_id(open_banking_io_transaction)
    data = open_banking_io_transaction.with_indifferent_access
    id = data[:id].presence
    return "open_banking_io_#{id}" if id.present?

    # Some ISO-20022 (PSD2) pending entries omit `id` entirely. Derive a stable
    # content-based external_id so they can still be imported idempotently.
    "open_banking_io_pending_#{content_hash_for(data)}"
  end

  # Stable fingerprint for id-less transactions. Kept in sync with the importer's
  # storage key so the same row hashes identically in both places.
  def self.content_hash_for(open_banking_io_transaction)
    data = open_banking_io_transaction.with_indifferent_access
    attributes = [
      data[:booking_date],
      data[:amount],
      data[:currency],
      data[:credit_debit_indicator],
      data[:remittance_information],
      data[:creditor_name],
      data[:debtor_name],
      data[:reference_number],
      data[:bank_transaction_code]
    ].map { |value| value.to_s.strip }.join("|")

    Digest::MD5.hexdigest(attributes)
  end

  def self.pending?(open_banking_io_transaction)
    PENDING_STATUSES.include?(normalized_status(open_banking_io_transaction))
  end

  # Entries that must not be imported at all. The service filters non-booked rows out before
  # persistence (CollectBookedAsync), so in practice the API only returns BOOK/OTHR/none --
  # but classify defensively in case that ever changes.
  def self.skip?(open_banking_io_transaction)
    SKIPPED_STATUSES.include?(normalized_status(open_banking_io_transaction))
  end

  def self.normalized_status(open_banking_io_transaction)
    open_banking_io_transaction.with_indifferent_access[:status].to_s.strip.upcase
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

    # Never guess the sign: the amount arrives as an unsigned magnitude and the
    # credit/debit indicator is the only thing that determines expense vs income.
    # A blank/garbled indicator would otherwise be treated as credit and silently
    # flip an expense into income, so skip the transaction instead.
    unless valid_indicator?
      Rails.logger.warn "OpenBankingIoEntry::Processor - Skipping transaction #{external_id} with unrecognized credit_debit_indicator #{data[:credit_debit_indicator].inspect}"
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

    def indicator
      data[:credit_debit_indicator].to_s.strip.upcase
    end

    def valid_indicator?
      VALID_INDICATORS.include?(indicator)
    end

    def debit?
      indicator == DEBIT_INDICATOR
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
      when nil
        # A missing amount must not become a zero-amount transaction -- a skipped row is
        # recoverable on the next sync, a silently-zeroed one is not.
        raise ArgumentError, "Missing transaction amount"
      else
        BigDecimal(data[:amount].to_s)
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
      metadata = {
        "pending" => pending?,
        "credit_debit_indicator" => data[:credit_debit_indicator],
        "status" => data[:status],
        "bank_transaction_code" => data[:bank_transaction_code],
        "reference_number" => data[:reference_number],
        "reference_number_schema" => data[:reference_number_schema],
        "merchant_category_code" => data[:merchant_category_code],
        # Counterparty identifiers. Decrypted from the envelope and previously discarded,
        # which left transfer matching and support with nothing but a display name.
        "creditor_iban" => data[:creditor_iban],
        "creditor_bban" => data[:creditor_bban],
        "creditor_agent_bic" => data[:creditor_agent_bic],
        "debtor_iban" => data[:debtor_iban],
        "debtor_bban" => data[:debtor_bban],
        "debtor_agent_bic" => data[:debtor_agent_bic],
        "balance_after" => data[:balance_after_transaction],
        "balance_after_computed" => data[:balance_after_computed],
        "balance_after_currency" => data[:balance_after_currency]
      }.merge(fx_metadata).compact

      { "open_banking_io" => metadata }
    end

    # The original pre-conversion amount, mirroring EnableBankingEntry::Processor -- the
    # same ISO-20022 data, which open-banking.io flattens to instructedAmount/Currency.
    #
    # fx_date deliberately prefers value_date (when the money moved) over booking_date
    # (when it settled) -- the reverse of the coalesce in #date, which wants the settlement
    # date for the ledger. Matches SimpleFIN preferring transacted over posted.
    def fx_metadata
      original_currency = parse_currency(data[:instructed_currency])
      return {} if original_currency.blank? || original_currency == currency

      {
        "fx_from" => original_currency,
        "fx_amount" => data[:instructed_amount],
        "fx_rate" => data[:exchange_rate],
        "fx_date" => (data[:value_date].presence || data[:transaction_date].presence || data[:booking_date].presence)&.to_s
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
