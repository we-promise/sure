require "digest/md5"

class UpEntry::Processor
  include CurrencyNormalizable

  # Stable external id for a transaction: its Up id when present, else a content
  # hash so pending entries lacking an id stay deduplicated across syncs.
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

  # MD5 of account/date/amount/description, used to identify id-less pendings.
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

  # Build a processor for a single raw Up transaction tied to +up_account+.
  def initialize(up_transaction, up_account:)
    @up_transaction = up_transaction
    @up_account = up_account
  end

  # Import the transaction into the linked Sure account via the import adapter.
  # Returns nil when the account isn't linked; re-raises on validation/save errors.
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
      kind: kind,
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

    # Memoized adapter that writes provider transactions into the Sure account.
    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # The linked Sure account for this transaction, if any.
    def account
      @account ||= up_account.current_account
    end

    # The raw transaction as an indifferent-access hash.
    def data
      @data ||= up_transaction.with_indifferent_access
    end

    # Canonical external id for this transaction (see .canonical_external_id).
    def external_id
      @external_id ||= self.class.canonical_external_id(data)
    end

    # Display name: the Up description, or a generic fallback.
    def name
      data[:description].presence || I18n.t("transactions.unknown_name")
    end

    # The id of the other account in an internal money movement, if any (see
    # Provider::Up#flatten_transaction). Present for transfers between the user's own
    # accounts and for round-ups swept into a Saver; nil for ordinary income/expense.
    def transfer_account_id
      data[:transfer_account_id].presence
    end

    # Mark internal movements as funds_movement so they are excluded from income,
    # expense, and budget analytics. Two-sided transfers between two linked accounts are
    # additionally paired into a Transfer by Family#auto_match_transfers!; one-sided moves
    # (counterpart not linked in Sure) and round-ups rely on this flag, since the matcher
    # has no opposing entry to pair them with.
    def kind
      transfer_account_id ? "funds_movement" : nil
    end

    # Optional user-entered message attached to the transaction.
    def notes
      data[:message].presence
    end

    # Find or create the merchant for this transaction's description, or nil.
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

    # Transaction currency, falling back to the account/default currency.
    def currency
      parse_currency(amount_data[:currencyCode]) || up_account.currency || account&.currency || "AUD"
    end

    # Settlement date (or creation date for pendings) as a Date.
    def date
      value = data[:settledAt].presence || data[:createdAt].presence
      case value
      when String
        if value.include?("T") || value.include?(":")
          Time.parse(value).in_time_zone(account&.family&.timezone).to_date
        else
          Date.parse(value)
        end
      when Integer, Float
        Time.at(value).in_time_zone(account&.family&.timezone).to_date
      when Time, DateTime
        value.in_time_zone(account&.family&.timezone).to_date
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

    # Provider metadata persisted on Transaction#extra (pending/status/fx/etc.).
    def extra_metadata
      {
        "up" => {
          "pending" => pending?,
          "status" => data[:status],
          "category_id" => data[:category_id],
          "transfer_account_id" => transfer_account_id,
          "raw_text" => data[:rawText],
          "fx_from" => foreign_amount_data[:currencyCode],
          "fx_amount" => foreign_amount_data[:value]
        }.compact
      }
    end

    # Whether this transaction is still HELD (unsettled) on Up.
    def pending?
      self.class.pending?(data)
    end

    # The native amount object ({ value:, currencyCode: }) as a hash.
    def amount_data
      @amount_data ||= data[:amount].is_a?(Hash) ? data[:amount].with_indifferent_access : {}
    end

    # The foreign-currency amount object for FX transactions, or empty hash.
    def foreign_amount_data
      @foreign_amount_data ||= data[:foreignAmount].is_a?(Hash) ? data[:foreignAmount].with_indifferent_access : {}
    end

    # CurrencyNormalizable hook: warn when an Up currency code is unrecognized.
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Up transaction #{external_id}, falling back to account currency")
    end
end
