require "digest/md5"

module Provider::AccountData::EnableBanking::TransactionNormalization
  PAYMENT_PROCESSOR_PREFIX = /\A(SUMUP|SQ|IZETTLE|ZETTLE|PAYPAL)\s*\*\s*/i
  WALLET_PREFIX = /\A(?:apple|google|samsung)\s+pay\s*:\s*/i

  def normalize_transaction(raw, account:)
    data = raw.with_indifferent_access
    normalize_transaction_data(data, account: account, external_id: transaction_external_id(data))
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Enable Banking transaction", cause: nil
  end

  def normalize_legacy_transaction(raw, account:)
    data = raw.with_indifferent_access.deep_dup
    # Fingerprint the historical representation before converting cached Float
    # monetary values. A conversion must not change an ID-less legacy identity.
    external_id = transaction_external_id(data)
    data[:amount] = legacy_float_decimal(data[:amount]) if data.key?(:amount)
    if data[:transaction_amount].is_a?(Hash)
      data[:transaction_amount][:amount] = legacy_float_decimal(data[:transaction_amount][:amount])
    end
    if data[:exchange_rate].is_a?(Hash)
      data[:exchange_rate][:exchange_rate] = legacy_float_decimal(data[:exchange_rate][:exchange_rate])
      if data[:exchange_rate][:instructed_amount].is_a?(Hash)
        data[:exchange_rate][:instructed_amount][:amount] = legacy_float_decimal(data[:exchange_rate][:instructed_amount][:amount])
      end
    end
    normalize_transaction_data(data, account: account, external_id: external_id)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid legacy Enable Banking transaction", cause: nil
  end

  private
    def normalize_transaction_data(data, account:, external_id:)
      direction = data[:credit_debit_indicator]
      amount = decimal(data.dig(:transaction_amount, :amount) || data[:amount]).abs
      amount = -amount if direction == "CRDT"
      counterparty = direction == "CRDT" ? data.dig(:debtor, :name).presence || data[:debtor_name].presence : data.dig(:creditor, :name).presence || data[:creditor_name].presence
      technical = counterparty.to_s.strip.match?(/\ACARD-\d+\z/i)
      remittance = primary_remittance(data)
      merchant_name = if counterparty.to_s.strip.present? && !technical
        counterparty.to_s.strip
      elsif technical && remittance.present?
        remittance.truncate(100, omission: "")
      elsif @known_merchant_names.include?(remittance)
        remittance
      end
      name = if counterparty.present? && !technical
        counterparty
      elsif technical && remittance.present?
        remittance.truncate(100)
      else
        data.dig(:bank_transaction_code, :description).presence || remittance&.truncate(100).presence ||
          (direction == "CRDT" ? "Incoming Transfer" : "Outgoing Transfer")
      end
      notes = []
      raw_remittance = data[:remittance_information]
      notes << raw_remittance.join("\n") if raw_remittance.is_a?(Array) && raw_remittance.any?
      notes << raw_remittance if raw_remittance.is_a?(String) && raw_remittance.present?
      notes << data[:note] if data[:note].present?
      pending = data[:_pending] == true || data[:status] == "PDNG"
      extra = { pending: pending }
      if data[:exchange_rate].present?
        fx = data[:exchange_rate]
        # Native FX monetary values are validated just like the posting amount.
        decimal(fx[:exchange_rate]) unless fx[:exchange_rate].nil?
        extra[:fx_rate] = fx[:exchange_rate]
        extra[:fx_unit_currency] = fx[:unit_currency]
        instructed = fx.dig(:instructed_amount, :amount)
        decimal(instructed) unless instructed.nil?
        extra[:fx_instructed_amount] = instructed
      end
      extra[:merchant_category_code] = data[:merchant_category_code] if data[:merchant_category_code].present?
      pending_id = data[:transaction_id].present? && data[:entry_reference].present? && !pending ? "enable_banking_#{data[:entry_reference]}" : nil
      Ingestion::Record.transaction(external_id: external_id, amount: amount,
        currency: known_currency(data.dig(:transaction_amount, :currency)) || known_currency(data[:currency]) || account[:currency] || "EUR",
        date: date_in_zone(data[:booking_date] || data[:value_date] || data[:transaction_date]), name: name,
        pending: pending, pending_external_id: pending_id,
        metadata: { notes: notes.join("\n\n").presence,
          merchant: merchant_name && { external_id: "enable_banking_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}", name: merchant_name },
          extra: { enable_banking: extra.compact } })
    end

    def primary_remittance(data)
      lines = Array.wrap(data[:remittance_information]).filter_map { |value| value.to_s.strip.sub(WALLET_PREFIX, "").strip.presence }
      descriptive = lines.find { |line| !line.match?(/\A(?:POS|ATM)\s+\d+[.,]\d{2}\b.*\d{2}\.\d{2}\.\s+\d{2}:\d{2}\z/i) } || lines.first
      return descriptive if descriptive.blank?
      matches = @known_merchant_names.select do |name|
        name.length >= 3 && descriptive.match?(/(?<![[:alnum:]_])#{Regexp.escape(name)}(?![[:alnum:]_])/i)
      end
      matches.max_by(&:length) || descriptive.sub(PAYMENT_PROCESSOR_PREFIX, "").strip
    end

    def transaction_external_id(data)
      id = data[:transaction_id].presence || data[:entry_reference].presence
      return "enable_banking_#{normalized_id(id)}" if id
      values = transaction_content_fields(data)
      content = [ *values.first(3), data[:credit_debit_indicator], *values.last(3) ].map { |value| identity_text(value) }.join("\x1F")
      raise ArgumentError if content.delete("\x1F").blank?
      "enable_banking_content_#{Digest::MD5.hexdigest(content)}"
    end

    def transaction_content_digest(data)
      values = transaction_content_fields(data) + [ data[:transaction_id], data[:credit_debit_indicator] ]
      Digest::SHA256.hexdigest(values.map { |value| identity_text(value) }.join("\x1F"))
    end

    def transaction_content_fields(data)
      remittance = data[:remittance_information]
      [ data[:booking_date].presence || data[:value_date].presence || data[:transaction_date],
        data.dig(:transaction_amount, :amount).presence || data[:amount],
        data.dig(:transaction_amount, :currency).presence || data[:currency],
        data.dig(:creditor, :name).presence || data[:creditor_name],
        data.dig(:debtor, :name).presence || data[:debtor_name],
        remittance.is_a?(Array) ? remittance.compact.map(&:to_s).sort.join("|") : remittance.to_s ]
    end

    def legacy_float_decimal(value)
      return value unless value.is_a?(Float)
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    end

    def identity_text(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
    end
end
