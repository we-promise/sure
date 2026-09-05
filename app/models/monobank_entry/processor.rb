require "digest/md5"

class MonobankEntry::Processor
  include CurrencyNormalizable, IsoNumericCurrency

  # Stable external id for a transaction: its Monobank id when present, else a content
  # hash so an id-less record still deduplicates across syncs.
  def self.canonical_external_id(monobank_transaction)
    data = monobank_transaction.with_indifferent_access
    id = data[:id].presence
    return "monobank_#{id}" if id.present?

    "monobank_pending_#{content_hash_for(data)}"
  end

  # Monobank flags an authorization that has not settled yet with hold: true.
  #
  # A hold and the settled record that replaces it do not necessarily share an id, so
  # pending entries are pruned when they drop out of the latest statement window rather
  # than being matched up by id (see MonobankAccount::Transactions::Processor).
  def self.pending?(monobank_transaction)
    data = monobank_transaction.with_indifferent_access

    ActiveModel::Type::Boolean.new.cast(data[:hold]) || false
  end

  # MD5 of account/time/amount/description, used to identify id-less records.
  def self.content_hash_for(data)
    attributes = [
      data[:account_id],
      data[:time],
      data[:amount],
      data[:description]
    ].compact.join("|")

    Digest::MD5.hexdigest(attributes)
  end

  # Build a processor for a single raw Monobank transaction tied to +monobank_account+.
  #
  # category_matcher (optional) maps the transaction's MCC onto one of the family's
  # existing Sure categories. It is injected by MonobankAccount::Transactions::Processor
  # so a single matcher (built once per account) is reused across the account's
  # transactions.
  def initialize(monobank_transaction, monobank_account:, category_matcher: nil)
    @monobank_transaction = monobank_transaction
    @monobank_account = monobank_account
    @category_matcher = category_matcher
  end

  # Import the transaction into the linked Sure account via the import adapter.
  # Returns nil when the account isn't linked; re-raises on validation/save errors.
  def process
    unless account.present?
      Rails.logger.warn "MonobankEntry::Processor - No linked account for monobank_account #{monobank_account.id}, skipping transaction #{external_id}"
      return nil
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "monobank",
      category_id: matched_category_id,
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  rescue ArgumentError => e
    Rails.logger.error "MonobankEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "MonobankEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  rescue => e
    Rails.logger.error "MonobankEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise StandardError.new("Unexpected error importing transaction: #{e.message}")
  end

  private

    attr_reader :monobank_transaction, :monobank_account

    # Memoized adapter that writes provider transactions into the Sure account.
    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # The linked Sure account for this transaction, if any.
    def account
      @account ||= monobank_account.current_account
    end

    # The raw transaction as an indifferent-access hash.
    def data
      @data ||= monobank_transaction.with_indifferent_access
    end

    # Canonical external id for this transaction (see .canonical_external_id).
    def external_id
      @external_id ||= self.class.canonical_external_id(data)
    end

    # Display name: Monobank's description (merchant or counterparty), or a fallback.
    def name
      data[:description].presence || I18n.t("transactions.unknown_name")
    end

    # The id of the Sure category the transaction's MCC maps to, or nil when no matcher
    # was injected, the MCC is missing, or it has no confident equivalent among the
    # family's categories. The import adapter applies this via enrich_attribute, so it
    # never overwrites a category the user has set or locked.
    def matched_category_id
      return nil unless @category_matcher

      @category_matcher.match(data[:mcc])&.id
    end

    # The user's own note on the transaction, if any.
    def notes
      data[:comment].presence
    end

    # Find or create the merchant for this transaction's description, or nil.
    def merchant
      merchant_name = data[:description].to_s.strip.presence
      return nil unless merchant_name

      provider_merchant_id = "monobank_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}"

      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: provider_merchant_id,
        name: merchant_name,
        source: "monobank"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "MonobankEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    # Monobank reports `amount` in the account currency's minor units, using banking
    # convention: negative is money out, positive is money in. Sure stores expenses as
    # positive and income as negative, so the sign is flipped.
    def amount
      -(minor_units(data[:amount]) / account_minor_unit_divisor)
    end

    # Entries are recorded in the account currency, which is what `amount` is expressed
    # in. Monobank's `currencyCode` on a statement item is documented as the *account*
    # currency ("Код валюти рахунку"), so it is preferred here and the stored account
    # currency is the fallback.
    def currency
      parse_currency(alpha_currency_code(data[:currencyCode])) ||
        parse_currency(monobank_account.currency) ||
        account&.currency ||
        "UAH"
    end

    # Settlement/authorization timestamp as a Date, in the family's zone.
    def date
      value = data[:time]
      raise ArgumentError, "Invalid date format" if value.blank?

      case value
      when Integer, Float
        Time.at(value).in_time_zone(account&.family&.timezone).to_date
      when String
        parse_string_date(value)
      when Time, DateTime
        value.in_time_zone(account&.family&.timezone).to_date
      when Date
        value
      else
        Rails.logger.error("Monobank transaction has no usable date value")
        raise ArgumentError, "Invalid date format"
      end
    rescue ArgumentError, TypeError
      Rails.logger.error("Failed to parse Monobank transaction date")
      raise ArgumentError, "Unable to parse transaction date"
    end

    # Monobank sends Unix seconds; a string is tolerated in case a caller (a webhook
    # relay, a fixture) hands the epoch over as text.
    def parse_string_date(value)
      return Time.at(Integer(value)).in_time_zone(account&.family&.timezone).to_date if value.match?(/\A-?\d+\z/)

      Time.parse(value).in_time_zone(account&.family&.timezone).to_date
    end

    # Provider metadata persisted on Transaction#extra.
    #
    # `pending` is the flag Sure's pending scopes read (Transaction::PENDING_PROVIDERS).
    # `balance_after` is Monobank's running account balance at the time of the
    # transaction, which is useful when reconciling a drifted balance by hand.
    def extra_metadata
      {
        "monobank" => {
          "pending" => pending?,
          "mcc" => data[:mcc],
          "original_mcc" => data[:originalMcc],
          "cashback_amount" => major_amount(data[:cashbackAmount]),
          "commission_amount" => major_amount(data[:commissionRate]),
          "balance_after" => major_amount(data[:balance]),
          "operation_amount" => foreign_operation_amount,
          "counter_name" => data[:counterName],
          "counter_iban" => data[:counterIban],
          "counter_edrpou" => data[:counterEdrpou],
          "receipt_id" => data[:receiptId],
          "invoice_id" => data[:invoiceId]
        }.compact
      }
    end

    # Whether this transaction is still an unsettled hold on Monobank.
    def pending?
      self.class.pending?(data)
    end

    # Monobank's `operationAmount` is the amount in the currency the transaction was
    # actually made in, but the statement never reports *which* currency that was — only
    # the account currency is given. So an FX purchase can be detected (the two amounts
    # differ) without being described: the raw operation amount is recorded for
    # reference and Sure's fx_from/fx_amount convention is deliberately left unset
    # rather than filled in with a guessed currency.
    def foreign_operation_amount
      operation_amount = data[:operationAmount]
      return nil if operation_amount.blank?
      return nil if operation_amount.to_s == data[:amount].to_s

      operation_amount
    end

    # Minor units of the account currency per major unit (100 for UAH).
    def account_minor_unit_divisor
      @account_minor_unit_divisor ||= BigDecimal(minor_unit_divisor(monobank_account.currency).to_s)
    end

    # Parse an integer minor-unit value into a BigDecimal.
    def minor_units(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      Rails.logger.error "Failed to parse Monobank transaction amount"
      raise ArgumentError, "Invalid transaction amount"
    end

    # Convert a minor-unit value into a plain decimal string in major units, or nil when
    # absent. Stored as a string rather than a BigDecimal because BigDecimal serializes
    # into JSON in engineering notation ("0.1005e4"), which is unreadable in the
    # transaction's extra payload.
    def major_amount(value)
      return nil if value.blank?

      (minor_units(value) / account_minor_unit_divisor).to_s("F")
    rescue ArgumentError
      nil
    end

    # CurrencyNormalizable hook: warn when a Monobank currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Monobank transaction #{external_id}, falling back to account currency")
    end
end
