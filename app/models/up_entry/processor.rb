require "digest/md5"

class UpEntry::Processor
  include CurrencyNormalizable

  def self.canonical_external_id(up_transaction)
    data = up_transaction.with_indifferent_access
    id = data[:id].presence
    return "up_#{id}" if id.present?

    "up_pending_#{content_hash_for(data)}"
  end

  # Up marks unsettled transactions with status "HELD"; settled ones are "SETTLED".
  def self.pending?(up_transaction)
    data = up_transaction.with_indifferent_access
    data[:status].to_s.upcase == "HELD"
  end

  def self.content_hash_for(data)
    amount = data[:amount].is_a?(Hash) ? data[:amount].with_indifferent_access : {}
    attributes = [
      data[:account_id],
      data[:createdAt],
      amount[:value],
      data[:description]
    ].compact.join("|")

    Digest::MD5.hexdigest(attributes)
  end

  def initialize(up_transaction, up_account:)
    @up_transaction = up_transaction
    @up_account = up_account
  end

  def process
    unless account.present?
      Rails.logger.warn "UpEntry::Processor - No linked account for up_account #{up_account.id}, skipping transaction #{external_id}"
      return nil
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "up",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  rescue ArgumentError => e
    Rails.logger.error "UpEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "UpEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  rescue => e
    Rails.logger.error "UpEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise StandardError.new("Unexpected error importing transaction: #{e.message}")
  end

  private

    attr_reader :up_transaction, :up_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= up_account.current_account
    end

    def data
      @data ||= up_transaction.with_indifferent_access
    end

    def external_id
      @external_id ||= self.class.canonical_external_id(data)
    end

    def name
      data[:description].presence || I18n.t("transactions.unknown_name")
    end

    def notes
      data[:message].presence
    end

    def merchant
      merchant_name = data[:description].to_s.strip.presence
      return nil unless merchant_name

      provider_merchant_id = "up_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}"

      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: provider_merchant_id,
        name: merchant_name,
        source: "up"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "UpEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    # Up amounts use banking convention: negative is money out, positive is money in.
    # Sure stores expenses as positive and income as negative, so the sign is flipped.
    def amount
      raw_value = amount_data[:value]
      parsed_amount = case raw_value
      when String
        BigDecimal(raw_value)
      when Numeric
        BigDecimal(raw_value.to_s)
      else
        BigDecimal("0")
      end

      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Up transaction amount: #{e.class}"
      raise ArgumentError, "Invalid transaction amount"
    end

    def currency
      parse_currency(amount_data[:currencyCode]) || up_account.currency || account&.currency || "AUD"
    end

    def date
      value = data[:settledAt].presence || data[:createdAt].presence
      case value
      when String
        Time.parse(value).to_date
      when Time, DateTime
        value.to_date
      when Date
        value
      else
        Rails.logger.error("Up transaction has no usable date value")
        raise ArgumentError, "Invalid date format"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Up transaction date: #{e.class}")
      raise ArgumentError, "Unable to parse transaction date"
    end

    def extra_metadata
      {
        "up" => {
          "pending" => pending?,
          "status" => data[:status],
          "category_id" => data[:category_id],
          "raw_text" => data[:rawText],
          "fx_from" => foreign_amount_data[:currencyCode],
          "fx_amount" => foreign_amount_data[:value]
        }.compact
      }
    end

    def pending?
      self.class.pending?(data)
    end

    def amount_data
      @amount_data ||= data[:amount].is_a?(Hash) ? data[:amount].with_indifferent_access : {}
    end

    def foreign_amount_data
      @foreign_amount_data ||= data[:foreignAmount].is_a?(Hash) ? data[:foreignAmount].with_indifferent_access : {}
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Up transaction #{external_id}, falling back to account currency")
    end
end
