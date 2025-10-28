class SimplefinEntry::Processor
  # simplefin_transaction is the raw hash fetched from SimpleFin API and converted to JSONB
  def initialize(simplefin_transaction, simplefin_account:)
    @simplefin_transaction = simplefin_transaction
    @simplefin_account = simplefin_account
  end

  def process
    SimplefinAccount.transaction do
      existing = find_existing_entry

      entry = existing || account.entries.find_or_initialize_by(plaid_id: external_key) do |e|
        e.entryable = Transaction.new
      end

      # If we matched an older pending/composite entry, upgrade its external key
      if entry.plaid_id != external_key && external_key.present?
        Rails.logger.info("SimpleFin duplicate merge: upgrading entry #{entry.id} key to #{external_key}")
        entry.plaid_id = external_key
        # Optional UI hint: note that we merged a pending into a posted item
        entry.enrich_attribute(:notes, "Merged pending transaction into posted", source: "simplefin")
      end

      entry.assign_attributes(
        amount: amount,
        currency: currency,
        date: date
      )

      entry.enrich_attribute(
        :name,
        name,
        source: "simplefin"
      )

      # Persist memo into notes when present (non-destructive)
      if data[:memo].present?
        entry.enrich_attribute(:notes, data[:memo].to_s, source: "simplefin")
      end

      # SimpleFin provides no category data - categories will be set by AI or rules

      if merchant
        entry.transaction.enrich_attribute(
          :merchant_id,
          merchant.id,
          source: "simplefin"
        )
      end

      entry.save!
    end
  end

  private
    attr_reader :simplefin_transaction, :simplefin_account

    def account
      simplefin_account.account
    end

    def data
      @data ||= simplefin_transaction.with_indifferent_access
    end

    # Prefer upstream id; fall back to fitid; otherwise leave nil (composite only)
    def external_key
      @external_key ||= begin
        if data[:id].present?
          "simplefin_#{data[:id]}"
        elsif data[:fitid].present?
          "simplefin_fitid_#{data[:fitid]}"
        else
          nil
        end
      end
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
      data[:currency] || account.currency
    end

    def date
      case data[:posted]
      when String
        Date.parse(data[:posted])
      when Integer, Float
        # Unix timestamp
        Time.at(data[:posted]).to_date
      when Time, DateTime
        data[:posted].to_date
      when Date
        data[:posted]
      else
        Rails.logger.error("SimpleFin transaction has invalid date value: #{data[:posted].inspect}")
        raise ArgumentError, "Invalid date format: #{data[:posted].inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse SimpleFin transaction date '#{data[:posted]}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{data[:posted].inspect}"
    end

    def merchant
      @merchant ||= SimplefinAccount::Transactions::MerchantDetector.new(data).detect_merchant
    end

    # Duplicate detection and pending→posted merge support
    def find_existing_entry
      # 1) Direct key match (by upstream id or fitid)
      if external_key.present?
        found = account.entries.find_by(plaid_id: external_key)
        return found if found
      end

      # 2) Composite match for pending→posted merge or id-less duplicates
      #    We look within a small window around the date for same account/currency.
      window_start = date - 7.days
      window_end = date + 7.days
      candidate_scope = account.entries.where(date: window_start..window_end)

      normalized_target = normalize_fields(data[:description], data[:memo], data[:payee])

      candidate_scope.find do |e|
        # Consider SimpleFin-sourced entries and early id-less pending entries (plaid_id blank)
        next unless e.plaid_id.blank? || e.plaid_id.to_s.start_with?("simplefin_")
        # Amount tolerance of 1 cent
        e_amount = (e.amount.is_a?(Numeric) ? BigDecimal(e.amount.to_s) : BigDecimal(e.amount_money.to_s))
        amounts_equal = (e_amount - amount).abs <= BigDecimal("0.01")
        next unless amounts_equal

        # Same-date fast path: if dates equal and amount equal, accept
        if e.date == date
          true
        else
          # Build normalized fields from the entry's current name to compare to description/payee
          entry_name_norm = normalize_string(e.name)
          # We allow match when entry name contains either normalized description or payee/memo tokens
          # for a conservative match; or exact match when both are blank.
          desc_norm, memo_norm, payee_norm = normalized_target
          [ desc_norm, payee_norm, memo_norm ].compact.any? { |tok| tok.present? && entry_name_norm.include?(tok) }
        end
      end
    end

    def normalize_fields(description, memo, payee)
      [ normalize_string(description), normalize_string(memo), normalize_string(payee) ]
    end

    def normalize_string(str)
      return nil if str.blank?
      s = str.to_s.downcase
      # Remove common noise tokens that don’t help identity matching
      noise = [ "visa", "mastercard", "discover", "debit", "credit", "purchase", "pos", "auth", "card", "payment" ]
      noise.each { |tok| s = s.gsub(/\b#{Regexp.escape(tok)}\b/, " ") }
      s.gsub(/\s+/, " ").strip
    end
end
