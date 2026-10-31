require "digest/md5"

class LunchflowEntry::Processor
  include CurrencyNormalizable
  include LunchflowTransactionHash
  include CardAuthorizationHold

  # True when the transaction lacks a provider ID and its merchant or description
  # matches a masked card authorization descriptor without identifying a real payee.
  # Certain institutions expose unfinalized card holds with blank IDs, masked card
  # numbers instead of merchant names, and sometimes with inverted signs.
  #
  # @return [Boolean]
  def self.unidentified_hold?(raw_transaction_data)
    data = raw_transaction_data.with_indifferent_access
    return false if data[:id].present?

    merchant_name = data[:merchant].to_s.strip
    description = data[:description].to_s.strip

    fields = [ merchant_name, description ].reject(&:blank?)
    return false if fields.empty?

    fields.all? { |field| masked_card_text?(field) }
  end

  # lunchflow_transaction is the raw hash fetched from Lunchflow API and converted to JSONB
  # Transaction structure: { id, accountId, amount, currency, date, merchant, description, isPending }
  def initialize(lunchflow_transaction, lunchflow_account:)
    @lunchflow_transaction = lunchflow_transaction
    @lunchflow_account = lunchflow_account
  end

  def process
    # Validate that we have a linked account before processing
    unless account.present?
      Rails.logger.warn "LunchflowEntry::Processor - No linked account for lunchflow_account #{lunchflow_account.id}, skipping transaction #{external_id}"
      return nil
    end

    # If this is a pending transaction with a temporary ID, check if a posted version already exists.
    # This prevents duplicate entries when posted transactions arrive before pending ones, or when
    # a stored hold snapshot is re-processed after a posted transaction has claimed it.
    if is_pending? && external_id.start_with?("lunchflow_pending_")
      existing_posted = find_existing_posted_version
      if existing_posted
        Rails.logger.info "LunchflowEntry::Processor - Skipping pending transaction (posted version already exists): pending=#{external_id}, posted=#{existing_posted.external_id}"
        return existing_posted
      end
    end

    first_hold_import = unidentified_hold? &&
      !account.entries.exists?(source: "lunchflow", external_id: external_id)

    # Wrap import in error handling to catch validation and save errors
    entry = begin
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "lunchflow",
        merchant: merchant,
        notes: notes,
        extra: extra_metadata
      )
    rescue ArgumentError => e
      # Re-raise validation errors (missing required fields, invalid data)
      Rails.logger.error "LunchflowEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      # Handle database save errors
      Rails.logger.error "LunchflowEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      # Catch unexpected errors with full context
      Rails.logger.error "LunchflowEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end

    capture_unidentified_hold_diagnostic(entry) if first_hold_import && entry

    entry
  end

  private
    attr_reader :lunchflow_transaction, :lunchflow_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= lunchflow_account.current_account
    end

    def data
      @data ||= lunchflow_transaction.with_indifferent_access
    end

    def external_id
      @external_id ||= calculate_external_id
    end

    def calculate_external_id
      id = data[:id].presence

      # For pending transactions, Lunchflow may return blank/nil IDs
      # Generate a stable temporary ID based on transaction attributes
      if id.blank?
        # Create a deterministic hash from key transaction attributes
        # This ensures the same pending transaction gets the same ID across syncs
        base_temp_id = content_hash_for_transaction(data)
        temp_id_with_prefix = "lunchflow_pending_#{base_temp_id}"

        # Check if entry with this external_id already exists
        # If it does AND it's still pending, reuse the same ID for re-sync.
        # The import adapter's skip logic will handle user edits correctly.
        # We DON'T check if attributes match - user edits should not cause duplicates.
        if entry_exists_with_external_id?(temp_id_with_prefix)
          existing_entry = account.entries.find_by(external_id: temp_id_with_prefix, source: "lunchflow")
          if existing_entry && existing_entry.entryable.is_a?(Transaction) && existing_entry.entryable.pending?
            Rails.logger.debug "Lunchflow: Reusing ID #{temp_id_with_prefix} for re-synced pending transaction"
            return temp_id_with_prefix
          end
        end

        # Handle true collisions: multiple different transactions with same attributes
        # (e.g., two Uber rides on the same day for the same amount within the same sync)
        final_id = temp_id_with_prefix
        counter = 1

        while entry_exists_with_external_id?(final_id)
          final_id = "#{temp_id_with_prefix}_#{counter}"
          counter += 1
        end

        if counter > 1
          Rails.logger.debug "Lunchflow: Collision detected, using #{final_id} for pending transaction: #{data[:merchant]} #{data[:amount]} #{data[:currency]}"
        else
          Rails.logger.debug "Lunchflow: Generated temporary ID #{final_id} for pending transaction: #{data[:merchant]} #{data[:amount]} #{data[:currency]}"
        end

        final_id
      else
        "lunchflow_#{id}"
      end
    end

    def entry_exists_with_external_id?(external_id)
      return false unless account.present?

      # Check if an entry with this external_id already exists in the account
      account.entries.exists?(external_id: external_id, source: "lunchflow")
    end

    def name
      if unidentified_hold?
        HOLD_TRANSACTION_NAME
      elsif masked_card_text?(data[:merchant]) && data[:description].present?
        data[:description].to_s.strip
      else
        data[:merchant].presence || "Unknown transaction"
      end
    end

    def notes
      if masked_card_text?(data[:merchant]) && data[:description].present?
        data[:merchant].presence
      else
        data[:description].presence || (data[:merchant].presence if unidentified_hold?)
      end
    end

    def merchant
      return nil if unidentified_hold?
      return nil if masked_card_text?(data[:merchant])
      return nil unless data[:merchant].present?

      # Create a stable merchant ID from the merchant name
      # Using digest to ensure uniqueness while keeping it deterministic
      merchant_name = data[:merchant].to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "lunchflow_merchant_#{merchant_id}",
          name: merchant_name,
          source: "lunchflow"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
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

      # Lunchflow likely uses standard convention where negative is expense, positive is income
      # Sure expects opposite convention (expenses positive, income negative)
      # So we negate the amount to convert from Lunchflow to Sure format.
      #
      # For unidentified card authorization holds, the ASPSP
      # erroneously reports the authorization hold as positive credit (inflow).
      # Force these holds to positive (outflow/expense in Sure) so they appear as pending expenses
      # and match the settled expense when it arrives.
      if unidentified_hold?
        parsed_amount.abs
      else
        -parsed_amount
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Lunchflow transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      parse_currency(data[:currency]) || account&.currency || "USD"
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in LunchFlow transaction #{external_id}, falling back to account currency")
    end

    def date
      case data[:date]
      when String
        if data[:date].include?("T") || data[:date].include?(":")
          Time.parse(data[:date]).in_time_zone(account&.family&.timezone).to_date
        else
          Date.parse(data[:date])
        end
      when Integer, Float
        Time.at(data[:date]).in_time_zone(account&.family&.timezone).to_date
      when Time, DateTime
        data[:date].in_time_zone(account&.family&.timezone).to_date
      when Date
        data[:date]
      else
        Rails.logger.error("Lunchflow transaction has invalid date value: #{data[:date].inspect}")
        raise ArgumentError, "Invalid date format: #{data[:date].inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Lunchflow transaction date '#{data[:date]}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{data[:date].inspect}"
    end

    # Build extra metadata hash with pending status
    # Lunchflow API field: isPending (boolean)
    def extra_metadata
      metadata = {}

      # Store pending status from Lunchflow API when present or when an unidentified hold
      if data.key?(:isPending) || unidentified_hold?
        metadata[:lunchflow] = { pending: is_pending? }
      end

      metadata
    end

    # Check if this transaction is marked as pending
    def is_pending?
      unidentified_hold? || ActiveModel::Type::Boolean.new.cast(data[:isPending])
    end

    # Find an existing posted version of this pending transaction
    # Matches by: exact amount, currency, merchant name (if present), and date window
    # Uses same 8-day window as Account::ProviderImportAdapter reconciliation logic
    def find_existing_posted_version
      return nil unless account.present?

      query = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "lunchflow")
        .where(amount: amount)
        .where(currency: currency)
        .where("entries.date BETWEEN ? AND ?", date, date + 8)
        .where("entries.external_id NOT LIKE 'lunchflow_pending_%'")
        .where("entries.external_id IS NOT NULL")
        .where.not(external_id: external_id)
        .where(Transaction.not_pending_sql("transactions", providers: "lunchflow"))
        .order("entries.date ASC") # Closest date first (prefer same-day posted, then next day, etc.)

      if unidentified_hold?
        # An unidentified hold has a masked-card descriptor instead of the real merchant name.
        # Only match a posted entry if it explicitly claimed this hold's external_id during
        # pending→posted reconciliation, preventing unrelated same-amount purchases from
        # suppressing an active hold.
        query = query.where(
          "transactions.extra -> 'auto_claimed_pending_ids' @> ?",
          [ external_id ].to_json
        )
      elsif data[:merchant].present?
        # Add merchant name matching for better precision when merchant name is present
        query = query.where(name: name)
      end

      query.first
    end

    # Called only after a successful first import of a hold.
    def capture_unidentified_hold_diagnostic(entry)
      raw_amount = begin
        BigDecimal(data[:amount].to_s)
      rescue ArgumentError, TypeError
        nil
      end

      # In Lunchflow convention, negative = expense, positive = income.
      # Unidentified holds on expenses often arrive erroneously as positive credit (inflow),
      # which LunchflowEntry::Processor normalizes to positive outflow in Sure (via parsed_amount.abs).
      # If raw amount was positive, the sign was inverted upstream.
      sign_inverted = raw_amount ? raw_amount > 0 : false

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: HOLD_DIAGNOSTIC_MESSAGE,
        source: self.class.name,
        provider_key: "lunchflow",
        family: account.family,
        account: account,
        account_provider: lunchflow_account.account_provider,
        metadata: {
          external_id: external_id,
          entry_id: entry.id,
          raw_amount: data[:amount].to_s,
          sign_inverted: sign_inverted,
          amount: amount.to_s,
          currency: currency,
          merchant: data[:merchant],
          description: data[:description]
        }
      )
    end
end
