require "digest/md5"

class SimplefinEntry::Processor
  include CurrencyNormalizable
  # simplefin_transaction is the raw hash fetched from SimpleFin API and converted to JSONB
  def initialize(simplefin_transaction, simplefin_account:)
    @simplefin_transaction = simplefin_transaction
    @simplefin_account = simplefin_account
  end

  def process
    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "simplefin",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  end

  private
    attr_reader :simplefin_transaction, :simplefin_account

    def extra_metadata
      sf = {}
      # Preserve raw strings from provider so nothing is lost
      sf["payee"] = data[:payee] if data.key?(:payee)
      sf["memo"] = data[:memo] if data.key?(:memo)
      sf["description"] = data[:description] if data.key?(:description)
      # Include provider-supplied extra hash if present
      sf["extra"] = data[:extra] if data[:extra].is_a?(Hash)

      return nil if sf.empty?
      { "simplefin" => sf }
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      simplefin_account.current_account
    end

    def data
      @data ||= simplefin_transaction.with_indifferent_access
    end

    def external_id
      id = data[:id].presence
      raise ArgumentError, "SimpleFin transaction missing id: #{data.inspect}" unless id
      "simplefin_#{id}"
    end

    def name
      # Use SimpleFin's rich, clean data to create informative transaction names
      payee = data[:payee]
      description = data[:description]

      # Combine payee + description when both are present and different
      if payee.present? && description.present? && payee != description
        "#{payee} - #{description}"
      elsif payee.present?
        payee
      elsif description.present?
        description
      else
        data[:memo] || "Unknown transaction"
      end
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

      # SimpleFin uses banking convention (expenses negative, income positive)
      # Maybe expects opposite convention (expenses positive, income negative)
      # So we negate the amount to convert from SimpleFin to Maybe format
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      parse_currency(data[:currency]) || account.currency
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in SimpleFIN transaction #{external_id}, falling back to account currency")
    end

    # UI/entry date selection by account type:
    # - Credit cards/loans: prefer transaction date (matches statements), then posted
    # - Others: prefer posted date, then transaction date
    # Epochs parsed as UTC timestamps via DateUtils
    def date
      # Prefer transaction date for revolving debt (credit cards/loans); otherwise prefer posted date
      acct_type = simplefin_account&.account_type.to_s.strip.downcase.tr(" ", "_")
      if %w[credit_card credit loan mortgage].include?(acct_type)
        t = transacted_date
        return t if t
        p = posted_date
        return p if p
      else
        p = posted_date
        return p if p
        t = transacted_date
        return t if t
      end
      Rails.logger.error("SimpleFin transaction missing posted/transacted date: #{data.inspect}")
      raise ArgumentError, "Invalid date format: #{data[:posted].inspect} / #{data[:transacted_at].inspect}"
    end

    def posted_date
      val = data[:posted]
      Simplefin::DateUtils.parse_provider_date(val)
    end

    def transacted_date
      val = data[:transacted_at]
      Simplefin::DateUtils.parse_provider_date(val)
    end

    def merchant
      # Use SimpleFin's clean payee data for merchant detection
      payee = data[:payee]&.strip
      return nil unless payee.present?

      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: generate_merchant_id(payee),
        name: payee,
        source: "simplefin"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "SimplefinEntry::Processor - Failed to create merchant '#{payee}': #{e.message}"
      nil
    end

    def generate_merchant_id(merchant_name)
      # Generate a consistent ID for merchants without explicit IDs
      "simplefin_#{Digest::MD5.hexdigest(merchant_name.downcase)}"
    end

    def notes
      # Prefer memo if present; include payee when it differs from description for richer context
      memo = data[:memo].to_s.strip
      payee = data[:payee].to_s.strip
      description = data[:description].to_s.strip

      parts = []
      parts << memo if memo.present?
      if payee.present? && payee != description
        parts << "Payee: #{payee}"
      end
      parts.presence&.join(" | ")
    end
end
