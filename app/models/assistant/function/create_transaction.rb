require "digest"

class Assistant::Function::CreateTransaction < Assistant::Function
  class << self
    def name
      "create_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Creates a transaction on a writable account. Use get_accounts, get_categories,
        get_merchants and get_tags to resolve related IDs.

        Existing callers may send a signed amount (negative is income), or pass
        type: income/expense/inflow/outflow to derive the sign from its magnitude.
        external_id is optional for this contract; calls without it are not retry-safe.

        Alternatively, send nature: income/expense with a strictly positive amount
        and a required stable external_id. This magnitude-based contract returns an
        absolute transaction amount and its nature; the signed/type contract keeps
        its existing signed string amount. Do not send contradictory type and nature.

        currency defaults to the account currency. source is an optional provenance
        label paired with external_id, defaulting to mcp. Idempotency is scoped to
        source plus external_id across the family: a changed request is rejected.
        user_modified explicitly controls provider-sync protection; it defaults to
        true for nature-based calls and false for the existing signed/type contract.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id date amount name],
      properties: {
        account_id: { type: "string", description: "Writable account ID from get_accounts" },
        date: { type: "string", format: "date", description: "Transaction date in YYYY-MM-DD format" },
        amount: { type: "number", description: "Signed amount, or positive magnitude when nature is supplied; type derives the sign from the magnitude" },
        name: { type: "string", description: "Transaction name or description" },
        type: { type: "string", enum: %w[income expense inflow outflow], description: "Optional direction for signed/type callers" },
        nature: { type: "string", enum: %w[expense income], description: "Optional magnitude-based contract: requires a positive amount and stable external_id" },
        currency: { type: "string", description: "ISO currency code; defaults to the account currency" },
        source: { type: "string", description: "Provenance label paired with external_id; defaults to mcp" },
        category_id: { type: [ "string", "null" ], description: "Category ID from get_categories" },
        merchant_id: { type: [ "string", "null" ], description: "Merchant ID available to the family" },
        tag_ids: { type: "array", items: { type: "string" }, uniqueItems: true, description: "Tag IDs from get_tags" },
        notes: { type: [ "string", "null" ], description: "Optional notes" },
        external_id: { type: "string", description: "Stable idempotency key; required with nature and optional for existing signed/type callers" },
        user_modified: { type: "boolean", description: "Protect this entry from provider overwrites; defaults to true with nature, otherwise false" }
      }
    )
  end

  def call(params = {})
    account = family.accounts.visible.writable_by(user).find_by(id: params["account_id"]) if valid_uuid?(params["account_id"])
    return account_not_found unless account

    attrs = normalized_attributes(params, account)
    return attrs if error_response?(attrs)

    result = family.with_lock do
      account = Account::MutationAccess.lock!(accounts: [ account ], user:, level: Account::MutationAccess::WRITE).fetch(account.id.to_s)
      next account_not_found unless family.accounts.visible.exists?(id: account.id)

      fingerprint = fingerprint_for(account.id, attrs) if attrs[:external_id]
      existing = family.entries.find_by(source: attrs[:source], external_id: attrs[:external_id]) if attrs[:external_id]
      if existing
        existing_response(existing, fingerprint, attrs)
      else
        persist_entry(account, attrs, fingerprint)
      end
    end
    return result if result.is_a?(Hash)

    response = success_response(result, created: true, magnitude: attrs[:magnitude])
    begin
      result.sync_account_later
    rescue StandardError => e
      response[:warning] = "Transaction created, but the post-create account sync could not be enqueued (#{e.class}). The balance will recalculate on the next sync."
    end
    response
  rescue Account::MutationAccess::Denied
    account_not_found
  rescue ActiveRecord::RecordNotUnique
    existing = family.entries.find_by(source: attrs[:source], external_id: attrs[:external_id]) if attrs&.dig(:external_id)
    existing ? existing_response(existing, fingerprint_for(account.id, attrs), attrs) : raise
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def normalized_attributes(params, account)
      magnitude = params.key?("nature")
      name = params["name"].to_s.strip
      return error(magnitude ? "name_required" : "invalid_name", "Please provide a transaction name.") if name.blank?

      external_id = params["external_id"].to_s.strip.presence
      return error("external_id_required", "Please provide a stable external_id.") if magnitude && !external_id
      if params["source"].present? && !external_id
        return error("source_requires_external_id", "source must be paired with external_id.")
      end

      direction = { "income" => "income", "inflow" => "income", "expense" => "expense", "outflow" => "expense" }
      type = direction[params["type"].to_s.downcase] if params["type"].present?
      return error("invalid_type", "type must be income, expense, inflow or outflow.") if params["type"].present? && !type
      nature = params["nature"].to_s.downcase if magnitude
      return error("invalid_nature", "nature must be 'expense' or 'income'.") if magnitude && !nature.in?(%w[expense income])
      return error("invalid_nature", "type and nature must describe the same direction.") if type && nature && type != nature

      amount = parse_decimal(params["amount"])
      return error("invalid_amount", "amount must be finite and numeric; with nature it must be greater than zero.") if amount.nil? || (magnitude && !amount.positive?)
      selected_direction = nature || type
      amount = selected_direction == "income" ? -amount.abs : amount.abs if selected_direction

      begin
        date = Date.iso8601(params["date"].to_s)
      rescue Date::Error
        return error(magnitude ? "invalid_parameters" : "invalid_date", "date must use YYYY-MM-DD format.")
      end

      currency = (params["currency"].to_s.strip.presence || account.currency.presence || family.primary_currency_code).upcase
      begin
        Money::Currency.new(currency)
      rescue Money::Currency::UnknownCurrencyError, ArgumentError
        return error("invalid_currency", "currency must be a valid ISO currency code.")
      end

      category = nil
      unless params["category_id"].nil? || params["category_id"] == ""
        return error("invalid_uuid", "Expected a valid UUID.") unless valid_uuid?(params["category_id"])
        category = family.categories.find_by(id: params["category_id"])
        return error("invalid_category", "category_id does not belong to the user's family.") unless category
      end
      merchant = nil
      unless params["merchant_id"].nil? || params["merchant_id"] == ""
        return error("invalid_uuid", "Expected a valid UUID.") unless valid_uuid?(params["merchant_id"])
        merchant = family.available_merchants_for(user).find_by(id: params["merchant_id"])
        return error("invalid_merchant", "merchant_id is not available to the user's family.") unless merchant
      end
      tag_ids = Array(params["tag_ids"]).map(&:to_s).reject(&:blank?).uniq
      tags = family.tags.where(id: tag_ids).to_a
      return error("invalid_tags", "One or more tag_ids do not belong to the user's family.") unless tags.size == tag_ids.size

      {
        account_id: account.id.to_s,
        name:, external_id:, amount:, date:, currency:, category:, merchant:, tags:,
        notes: params["notes"], magnitude:,
        source: external_id && (params["source"].to_s.strip.presence || "mcp"),
        user_modified: params.key?("user_modified") ? ActiveModel::Type::Boolean.new.cast(params["user_modified"]) == true : magnitude
      }
    end

    def persist_entry(account, attrs, fingerprint)
      extra = fingerprint ? { "mcp" => { "idempotency_fingerprint" => fingerprint } } : {}
      entry = account.entries.new(
        name: attrs[:name], amount: attrs[:amount], date: attrs[:date], currency: attrs[:currency],
        notes: attrs[:notes], external_id: attrs[:external_id], source: attrs[:source],
        entryable: Transaction.new(category: attrs[:category], merchant: attrs[:merchant], tags: attrs[:tags], extra:)
      )
      entry.save!

      entry.lock_saved_attributes!
      entry.mark_user_modified! if attrs[:user_modified]
      entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?
      entry
    end

    def existing_response(entry, fingerprint, attrs)
      return error("idempotency_conflict", "external_id already belongs to a non-transaction entry.") unless entry.entryable.is_a?(Transaction)

      stored = entry.transaction.extra&.dig("mcp", "idempotency_fingerprint")
      matches = stored ? ActiveSupport::SecurityUtils.secure_compare(stored, fingerprint) : fingerprint_for_entry(entry) == fingerprint
      # Earlier magnitude-based clients stored fingerprints without currency,
      # source or user_modified. Check those fields before accepting that digest.
      if !matches && stored && entry.account_id == attrs[:account_id] && entry.currency == attrs[:currency] && entry.source == attrs[:source] && entry.user_modified? == attrs[:user_modified]
        matches = ActiveSupport::SecurityUtils.secure_compare(stored, fingerprint_for(attrs[:account_id], attrs, legacy: true))
      end
      return error("idempotency_conflict", "external_id was already used with different transaction parameters.") unless matches

      success_response(entry, created: false, magnitude: attrs[:magnitude])
    end

    def fingerprint_for(account_id, attrs, legacy: false)
      payload = {
        account_id: account_id.to_s, name: attrs[:name], amount: attrs[:amount].to_d.to_s("F"), date: attrs[:date].iso8601,
        category_id: attrs[:category]&.id&.to_s, merchant_id: attrs[:merchant]&.id&.to_s,
        tag_ids: attrs[:tags].map { |tag| tag.id.to_s }.sort, notes: attrs[:notes]
      }
      payload.merge!(currency: attrs[:currency], source: attrs[:source], user_modified: attrs[:user_modified]) unless legacy
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def fingerprint_for_entry(entry)
      transaction = entry.transaction
      fingerprint_for(entry.account_id, {
        name: entry.name, amount: entry.amount, date: entry.date, currency: entry.currency, source: entry.source,
        category: transaction.category, merchant: transaction.merchant, tags: transaction.tags.to_a,
        notes: entry.notes, user_modified: entry.user_modified?
      })
    end

    def success_response(entry, created:, magnitude:)
      {
        success: true, created:, transaction: serialize(entry, magnitude:),
        message: created ? "Transaction '#{entry.name}' created." : "Transaction '#{entry.name}' already exists."
      }
    end

    def serialize(entry, magnitude:)
      transaction = entry.transaction
      {
        id: transaction.id, entry_id: entry.id, account_id: entry.account_id, name: entry.name, date: entry.date,
        amount: magnitude ? entry.amount.abs : entry.amount.to_s, amount_formatted: format_money(entry),
        currency: entry.currency, type: entry.classification, nature: entry.amount.negative? ? "income" : "expense", notes: entry.notes,
        category: transaction.category && { id: transaction.category.id, name: transaction.category.name },
        merchant: transaction.merchant && { id: transaction.merchant.id, name: transaction.merchant.name },
        tags: transaction.tags.map { |tag| { id: tag.id, name: tag.name } },
        external_id: entry.external_id, source: entry.source
      }
    end

    def format_money(entry)
      entry.amount_money.format
    rescue StandardError
      "#{entry.amount} #{entry.currency}"
    end

    def parse_decimal(value)
      number = BigDecimal(value.to_s)
      number if number.finite?
    rescue ArgumentError, TypeError
      nil
    end

    def account_not_found
      error("account_not_found", "No account found with that ID that this user can write to.")
    end

    def error_response?(value)
      value.is_a?(Hash) && value[:success] == false
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
