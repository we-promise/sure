# frozen_string_literal: true

require "digest/md5"

# Maps one Fio movement onto a Sure entry.
#
# Fio returns each movement as a bag of numbered columns
# (`{"column22" => {"value" => 1147608196, "name" => "ID pohybu", "id" => 22}}`), the same
# ids the CSV and XML exports use. `COLUMNS` is that mapping; `.normalize` flattens a raw
# movement into named fields, and the raw form is what gets stored so a later change of
# mapping can be replayed against it.
class FioEntry::Processor
  include CurrencyNormalizable

  COLUMNS = {
    id: "column22",                  # ID pohybu
    date: "column0",                 # Datum
    amount: "column1",               # Objem
    currency: "column14",            # Měna
    counter_account: "column2",      # Protiúčet
    counter_account_name: "column10", # Název protiúčtu
    counter_bank_id: "column3",      # Kód banky
    counter_bank_name: "column12",   # Název banky
    constant_symbol: "column4",      # KS
    variable_symbol: "column5",      # VS
    specific_symbol: "column6",      # SS
    user_identification: "column7",  # Uživatelská identifikace
    message: "column16",             # Zpráva pro příjemce
    operation_type: "column8",       # Typ
    executed_by: "column9",          # Provedl
    specification: "column18",       # Upřesnění
    comment: "column25",             # Komentář
    counter_bic: "column26",         # BIC
    instruction_id: "column17",      # ID pokynu
    payer_reference: "column27"      # Reference plátce
  }.freeze

  # Fio books every movement on a Prague banking day and serialises that day as epoch
  # milliseconds at local midnight. Reading it in the family's timezone would shift a
  # transaction to the previous day for anyone west of Prague.
  BANK_TIME_ZONE = "Europe/Prague".freeze

  # Card acceptor strings look like "Nákup: PENNY MARKET s.r.o., Jaromer, CZ".
  CARD_PURCHASE_PREFIX = /\A(?:nákup|platba)\s*:\s*/i
  CARD_ACCEPTOR_LOCATION = /,\s*[^,]+,\s*[A-Z]{2}\.?\z/
  # Operation types covering card use ("Platba kartou", "Poplatek - platební karta").
  CARD_OPERATION = /kart/i

  # Original amount and currency of a converted payment, e.g. "15.90 EUR".
  FOREIGN_AMOUNT = /\A(?<amount>-?[\d\s.,]+)\s*(?<currency>[A-Z]{3})\z/

  # Flattens a raw movement into the fields named by COLUMNS, dropping blanks. Fio pads
  # empty columns with a single space in some formats, hence the strip.
  def self.normalize(fio_transaction)
    raw = fio_transaction.to_h.with_indifferent_access

    COLUMNS.each_with_object({}.with_indifferent_access) do |(field, column), normalized|
      value = raw.dig(column, :value)
      value = value.strip if value.is_a?(String)
      normalized[field] = value unless value.nil? || value == ""
    end
  end

  # Stable external id for a movement. Fio guarantees "ID pohybu" is unique per account
  # and never reused, including for a reversal, which gets its own id.
  def self.canonical_external_id(fio_transaction)
    id = normalize(fio_transaction)[:id]
    return nil if id.blank?

    "fio_#{id}"
  end

  def initialize(fio_transaction, fio_account:)
    @fio_transaction = fio_transaction
    @fio_account = fio_account
  end

  # Import the movement into the linked Sure account via the import adapter.
  # Returns nil when the account isn't linked or the movement is unusable.
  def process
    unless account.present?
      Rails.logger.warn "FioEntry::Processor - No linked account for fio_account #{fio_account.id}, skipping movement"
      return nil
    end

    return nil if external_id.blank? || amount.nil? || date.nil?

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "fio",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  rescue ArgumentError => e
    Rails.logger.error "FioEntry::Processor - Validation error for movement #{external_id}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "FioEntry::Processor - Failed to save movement #{external_id}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  end

  private

    attr_reader :fio_transaction, :fio_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= fio_account.current_account
    end

    def data
      @data ||= self.class.normalize(fio_transaction)
    end

    def external_id
      @external_id ||= self.class.canonical_external_id(fio_transaction)
    end

    # Fio signs outgoing movements negative; Sure stores an expense positive.
    def amount
      return @amount if defined?(@amount)

      raw = data[:amount]
      @amount = raw.nil? ? nil : -BigDecimal(raw.to_s)
    rescue ArgumentError
      @amount = nil
    end

    def currency
      @currency ||= parse_currency(data[:currency]) || account.currency
    end

    def date
      return @date if defined?(@date)

      @date = case (raw = data[:date])
      when Integer, Float
        Time.at(raw / 1000.0).in_time_zone(BANK_TIME_ZONE).to_date
      when String
        Date.parse(raw)
      else
        nil
      end
    rescue ArgumentError, TypeError
      @date = nil
    end

    # Best available description. A transfer names the counterparty; a card payment has
    # no counterparty but carries the acceptor in "Uživatelská identifikace"; standing
    # fees and interest have neither and fall back to the operation type.
    def name
      value = data[:counter_account_name].presence ||
        card_acceptor ||
        data[:user_identification].presence ||
        data[:message].presence ||
        data[:comment].presence ||
        data[:operation_type].presence ||
        I18n.t("transactions.unknown_name")

      value.to_s.truncate(255)
    end

    # Whatever payment detail did not become the name, so the reference the counterparty
    # sent is not lost. "Uživatelská identifikace" is skipped once the name came out of
    # it: repeating the acceptor string verbatim under a cleaned-up name is noise on
    # every single card payment.
    def notes
      candidates = [ data[:message], data[:comment] ]
      candidates << data[:user_identification] if card_acceptor.blank?
      candidates.compact_blank.reject { |value| value.to_s == name }.first&.to_s&.truncate(255)
    end

    def merchant
      merchant_name = card_acceptor
      return nil if merchant_name.blank?

      import_adapter.find_or_create_merchant(
        provider_merchant_id: "fio_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}",
        name: merchant_name,
        source: "fio"
      )
    end

    # Card acceptor name, without Fio's "Nákup: " prefix and trailing ", city, country".
    def card_acceptor
      return @card_acceptor if defined?(@card_acceptor)

      identification = data[:user_identification]
      unless identification.present? && data[:operation_type].to_s.match?(CARD_OPERATION)
        return @card_acceptor = nil
      end

      @card_acceptor = identification
        .sub(CARD_PURCHASE_PREFIX, "")
        .sub(CARD_ACCEPTOR_LOCATION, "")
        .strip
        .presence
    end

    def extra_metadata
      fio = {
        "id" => data[:id],
        "instruction_id" => data[:instruction_id],
        "operation_type" => data[:operation_type],
        "variable_symbol" => data[:variable_symbol],
        "constant_symbol" => data[:constant_symbol],
        "specific_symbol" => data[:specific_symbol],
        "counter_account" => counter_account_number,
        "counter_account_name" => data[:counter_account_name],
        "counter_bic" => data[:counter_bic],
        "payer_reference" => data[:payer_reference],
        "executed_by" => data[:executed_by],
        "specification" => data[:specification]
      }.merge(foreign_amount_metadata).compact

      { "fio" => fio }
    end

    # "Upřesnění" carries the original amount of a converted payment. Recorded under the
    # cross-provider FX keys so the entry shows what was actually charged abroad.
    def foreign_amount_metadata
      specification = data[:specification]
      return {} if specification.blank?

      match = FOREIGN_AMOUNT.match(specification.to_s.strip)
      return {} unless match

      foreign_currency = parse_currency(match[:currency])
      return {} if foreign_currency.blank? || foreign_currency == currency

      foreign_amount = BigDecimal(match[:amount].gsub(/\s/, "").tr(",", "."))

      { "fx_from" => foreign_currency, "fx_amount" => foreign_amount.to_s }
    rescue ArgumentError
      {}
    end

    # Fio writes a counter account as "2212-2000000699" (prefix-number) or bare digits.
    # Joined with the bank code so the pair is usable without reading two fields.
    def counter_account_number
      account_number = data[:counter_account]
      return nil if account_number.blank?

      bank_id = data[:counter_bank_id]
      bank_id.present? ? "#{account_number}/#{bank_id}" : account_number.to_s
    end
end
