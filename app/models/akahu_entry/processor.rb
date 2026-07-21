require "digest/md5"

class AkahuEntry::Processor
  include CurrencyNormalizable

  def self.canonical_external_id(akahu_transaction)
    data = akahu_transaction.with_indifferent_access
    id = data[:_id].presence || data[:id].presence
    return "akahu_#{id}" if id.present?

    "akahu_pending_#{content_hash_for(data)}"
  end

  def self.pending?(akahu_transaction)
    data = akahu_transaction.with_indifferent_access
    ActiveModel::Type::Boolean.new.cast(data[:_pending]) == true ||
      ActiveModel::Type::Boolean.new.cast(data[:pending]) == true
  end

  def self.content_hash_for(data)
    merchant = data[:merchant].is_a?(Hash) ? data[:merchant].with_indifferent_access : {}
    attributes = [
      data[:_account],
      data[:account],
      data[:date],
      data[:amount],
      data[:description],
      merchant[:name].to_s.strip.presence,
      data[:type]
    ].compact.join("|")

    Digest::MD5.hexdigest(attributes)
  end

  def initialize(akahu_transaction, akahu_account:)
    @akahu_transaction = akahu_transaction
    @akahu_account = akahu_account
  end

  def process
    unless account.present?
      Rails.logger.warn "AkahuEntry::Processor - No linked account for akahu_account #{akahu_account.id}, skipping transaction #{external_id}"
      return nil
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "akahu",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  rescue ArgumentError => e
    Rails.logger.error "AkahuEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error "AkahuEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
    raise StandardError.new("Failed to import transaction: #{e.message}")
  rescue => e
    Rails.logger.error "AkahuEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise StandardError.new("Unexpected error importing transaction: #{e.message}")
  end

  private

    attr_reader :akahu_transaction, :akahu_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= akahu_account.current_account
    end

    def data
      @data ||= akahu_transaction.with_indifferent_access
    end

    def external_id
      @external_id ||= begin
        id = data[:_id].presence || data[:id].presence
        if id.present?
          "akahu_#{id}"
        else
          base_id = self.class.canonical_external_id(data)
          if existing_pending_entry?(base_id)
            base_id
          else
            final_id = base_id
            counter = 1
            while entry_exists_with_external_id?(final_id)
              final_id = "#{base_id}_#{counter}"
              counter += 1
            end

            final_id
          end
        end
      end
    end

    def existing_pending_entry?(external_id)
      existing_entry = account&.entries&.find_by(external_id: external_id, source: "akahu")
      existing_entry&.entryable.is_a?(Transaction) && existing_entry.entryable.pending?
    end

    def entry_exists_with_external_id?(external_id)
      account.present? && account.entries.exists?(external_id: external_id, source: "akahu")
    end

    def name
      merchant_name.presence || data[:description].presence || I18n.t("transactions.unknown_name")
    end

    def notes
      meta = meta_data
      parts = []
      parts << data[:description] if data[:description].present? && data[:description] != name
      parts << "#{t('akahu_entry.notes.reference')}: #{meta[:reference]}" if meta[:reference].present?
      parts << "#{t('akahu_entry.notes.particulars')}: #{meta[:particulars]}" if meta[:particulars].present?
      parts << "#{t('akahu_entry.notes.code')}: #{meta[:code]}" if meta[:code].present?
      parts << "#{t('akahu_entry.notes.other_account')}: #{meta[:other_account]}" if meta[:other_account].present?
      parts.presence&.join(" | ")
    end

    def merchant
      return nil unless merchant_name.present?

      provider_merchant_id = merchant_data[:_id].presence || merchant_data[:id].presence
      provider_merchant_id ||= "akahu_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}"

      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: provider_merchant_id,
        name: merchant_name,
        source: "akahu",
        website_url: merchant_data[:website]
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "AkahuEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    def amount
      parsed_amount = case data[:amount]
      when String
        BigDecimal(data[:amount])
      when Numeric
        BigDecimal(data[:amount].to_s)
      else
        BigDecimal("0")
      end

      # Akahu uses banking convention: negative is money out, positive is money in.
      # Sure stores expenses as positive and income as negative.
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Akahu transaction amount: #{e.class}"
      raise ArgumentError, "Invalid transaction amount"
    end

    def currency
      parse_currency(data[:currency]) || akahu_account.currency || account&.currency || "NZD"
    end

    def date
      value = data[:date]
      case value
      when String
        Date.parse(value)
      when Integer, Float
        Time.at(value).in_time_zone(account&.family&.timezone).to_date
      when Time, DateTime
        value.in_time_zone(account&.family&.timezone).to_date
      when Date
        value
      else
        Rails.logger.error("Akahu transaction has invalid date value")
        raise ArgumentError, "Invalid date format"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Akahu transaction date: #{e.class}")
      raise ArgumentError, "Unable to parse transaction date"
    end

    def extra_metadata
      {
        "akahu" => {
          "pending" => pending?,
          "type" => data[:type],
          "category" => category_data[:name],
          "category_id" => category_data[:_id].presence || category_data[:id],
          "category_group" => category_group_name,
          "reference" => meta_data[:reference],
          "particulars" => meta_data[:particulars],
          "code" => meta_data[:code],
          "other_account" => meta_data[:other_account]
        }.compact
      }
    end

    def pending?
      self.class.pending?(data)
    end

    def merchant_data
      @merchant_data ||= data[:merchant].is_a?(Hash) ? data[:merchant].with_indifferent_access : {}
    end

    def merchant_name
      merchant_data[:name].to_s.strip.presence
    end

    def category_data
      @category_data ||= data[:category].is_a?(Hash) ? data[:category].with_indifferent_access : {}
    end

    def category_group_name
      groups = category_data[:groups]
      return nil unless groups.is_a?(Hash)

      groups.with_indifferent_access.dig(:personal_finance, :name)
    end

    def meta_data
      @meta_data ||= data[:meta].is_a?(Hash) ? data[:meta].with_indifferent_access : {}
    end

    def t(key, **options)
      I18n.t(key, **options)
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Akahu transaction #{external_id}, falling back to account currency")
    end
end
