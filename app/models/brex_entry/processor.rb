# frozen_string_literal: true

require "digest/md5"

class BrexEntry::Processor
  include CurrencyNormalizable

  def initialize(brex_transaction, brex_account:)
    @brex_transaction = brex_transaction
    @brex_account = brex_account
  end

  def process
    cached_external_id = nil
    cached_external_id = external_id

    unless account.present?
      Rails.logger.warn "BrexEntry::Processor - No linked account for brex_account #{brex_account.id}, skipping transaction #{cached_external_id}"
      return :skipped
    end

    import_adapter.import_transaction(
      external_id: cached_external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "brex",
      merchant: merchant,
      notes: notes,
      extra: extra
    )
  rescue ArgumentError => e
    Rails.logger.error "BrexEntry::Processor - Validation error for transaction #{cached_external_id || safe_external_id}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "BrexEntry::Processor - Failed to save transaction #{cached_external_id || safe_external_id}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  rescue => e
    Rails.logger.error "BrexEntry::Processor - Unexpected error processing transaction #{cached_external_id || safe_external_id}: #{e.class} - #{e.message}"
    Rails.logger.error Array(e.backtrace).join("\n")
    raise StandardError.new("Unexpected error importing transaction: #{e.message}")
  end

  private
    attr_reader :brex_transaction, :brex_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= brex_account.current_account
    end

    def data
      @data ||= brex_transaction.with_indifferent_access
    end

    def external_id
      id = data[:id].presence
      raise ArgumentError, "Brex transaction missing required field 'id'" unless id

      "brex_#{id}"
    end

    def safe_external_id
      external_id
    rescue ArgumentError
      "brex_unknown"
    end

    def name
      data[:description].presence ||
        merchant_payload[:raw_descriptor].presence ||
        merchant_payload[:name].presence ||
        I18n.t("brex_items.entries.default_name")
    end

    def notes
      note_parts = []
      note_parts << data[:type] if data[:type].present?
      note_parts << data[:expense_id] if data[:expense_id].present?
      note_parts.any? ? note_parts.join(" - ") : nil
    end

    def merchant
      merchant_name = merchant_payload[:raw_descriptor].presence || merchant_payload[:name].presence
      return @merchant if instance_variable_defined?(:@merchant)
      return @merchant = nil if merchant_name.blank?

      merchant_name = merchant_name.to_s.strip
      return @merchant = nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant = import_adapter.find_or_create_merchant(
        provider_merchant_id: "brex_merchant_#{merchant_id}",
        name: merchant_name,
        source: "brex"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "BrexEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      @merchant = nil
    end

    def merchant_payload
      @merchant_payload ||= begin
        payload = data[:merchant]
        payload.is_a?(Hash) ? payload.with_indifferent_access : {}
      end
    end

    def amount
      BrexAccount.money_to_decimal(data[:amount]) || BigDecimal("0")
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Brex transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      amount_currency = transaction_amount_currency
      log_invalid_currency(amount_currency) if amount_currency.blank? && data[:amount].present?

      parse_currency(amount_currency) ||
        parse_currency(brex_account.currency) ||
        "USD"
    end

    def transaction_amount_currency
      amount_payload = data[:amount]
      return nil unless amount_payload.is_a?(Hash)

      amount_payload.with_indifferent_access[:currency]
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn(
        "Invalid Brex currency #{currency_value.inspect} for transaction #{data[:id].presence || 'unknown'} " \
        "on brex_account #{brex_account.id} amount=#{data[:amount].inspect} account_currency=#{brex_account.currency.inspect}; defaulting to fallback"
      )
    end

    def date
      date_value = data[:posted_at_date].presence || data[:initiated_at_date].presence

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
        raise ArgumentError, "Invalid date format: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Brex transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end

    def extra
      {
        brex: {
          transaction_id: data[:id],
          account_kind: brex_account.account_kind,
          type: data[:type],
          card_id: data[:card_id],
          transfer_id: data[:transfer_id],
          expense_id: data[:expense_id],
          card_transaction_operation_reference_id: data[:card_transaction_operation_reference_id],
          initiated_at_date: data[:initiated_at_date],
          posted_at_date: data[:posted_at_date],
          merchant: BrexAccount.sanitize_payload(data[:merchant])
        }.compact
      }
    end
end
