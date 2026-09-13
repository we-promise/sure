# frozen_string_literal: true

# AI-ASSISTED: written with AI assistance (Claude) and manually reviewed and
# tested by its author against a live 0.7.5-alpha.7 deployment.

# Creates a ledger transaction through the same Entry + Transaction path the
# app's own create endpoint (Api::V1::TransactionsController#create) uses, so
# balance recalculation and provider-sync protection behave exactly as they do
# for a transaction entered by hand.
#
# Exposed on the shared Assistant.function_classes registry, so it is callable
# from both the /mcp endpoint and the in-app assistant — the same surface that
# already carries the equally-mutating UpdateTransaction.
class Assistant::Function::CreateTransaction < Assistant::Function
  class << self
    # The tool's stable name; this is the MCP function identifier callers use.
    def name
      "create_transaction"
    end

    # Human/LLM-facing description of what the tool does and how to call it.
    def description
      <<~INSTRUCTIONS
        Creates a new transaction on one of the user's accounts.

        Use this to record a transaction the app cannot see on its own — a
        manual account, an off-platform payment, a cash transaction, or a line
        from a statement export. It writes through the same Entry + Transaction
        path the app's own create endpoint uses, so balance recalculation and
        provider-sync protection behave exactly as they do for a transaction
        entered by hand.

        Amount sign convention (matches the rest of the app):
          - negative amount = income / money in
          - positive  amount = expense / money out
        You may instead pass a positive magnitude plus `type` ("income" or
        "expense"); the sign is then derived from `type`. If you pass neither
        a sign nor a `type`, the amount is stored exactly as given.

        Idempotency: if you pass `external_id` (and optionally `source`,
        defaulting to "mcp"), a repeat call with the same account + source +
        external_id returns the existing transaction instead of creating a
        duplicate. This makes batch imports safe to retry.

        The account must be one the user can write to (owner or full-control
        share). Related ids (category, merchant, tags) must belong to the
        user's family.

        Example:

        ```
        create_transaction({
          account_id: "abc123-...",
          date: "2026-09-11",
          amount: 2194.15,
          type: "expense",
          name: "Roche",
          category_id: "def456-..."
        })
        ```
      INSTRUCTIONS
    end
  end

  # This tool is not strict: it validates its own inputs and returns structured
  # error hashes rather than raising, so a bad call is reported to the model.
  def strict_mode?
    false
  end

  # JSON schema of the parameters this tool accepts, exposed to the model.
  def params_schema
    build_schema(
      required: %w[account_id date amount name],
      properties: {
        account_id: {
          type: "string",
          description: "UUID of the account to record the transaction on. The user must be able to write to it (owner or full-control share)."
        },
        date: {
          type: "string",
          description: "ISO 8601 date (YYYY-MM-DD) of the transaction."
        },
        amount: {
          type: "number",
          description: "Transaction amount in the account's currency. Negative = income (money in), positive = expense (money out). If `type` is also given, `type` decides the sign and the magnitude of `amount` is used."
        },
        name: {
          type: "string",
          description: "Transaction name / payee / description."
        },
        type: {
          type: "string",
          enum: %w[income expense inflow outflow],
          description: "Optional. Derives the amount sign: income/inflow -> negative, expense/outflow -> positive. Omit to store `amount` as given."
        },
        currency: {
          type: "string",
          description: "ISO 4217 currency code. Defaults to the account's currency."
        },
        notes: {
          type: [ "string", "null" ],
          description: "Optional notes. Use null to store an empty note."
        },
        category_id: {
          type: [ "string", "null" ],
          description: "Category ID from get_categories. Must belong to the user's family."
        },
        merchant_id: {
          type: [ "string", "null" ],
          description: "Merchant ID available to the family. Must be a valid merchant id."
        },
        tag_ids: {
          type: "array",
          items: { type: "string" },
          description: "Tag IDs from get_tags. Must belong to the user's family."
        },
        external_id: {
          type: "string",
          description: "Optional stable external identifier (e.g. a row id from a statement export). With `source`, makes the call idempotent."
        },
        source: {
          type: "string",
          description: "Optional provenance label paired with external_id (defaults to \"mcp\")."
        },
        user_modified: {
          type: "boolean",
          description: "If true, mark the transaction user-modified so a later provider sync will not overwrite it (defaults to false)."
        }
      }
    )
  end

  # Tool entry point. Validates the params, builds and persists the Entry
  # through the same path as the native create endpoint, enqueues the
  # post-commit account sync (best-effort), and returns a result hash. Returns
  # { success: true, created: true, transaction: } on success (with an optional
  # :warning if the sync could not be enqueued), an error hash on validation
  # failure, or { success: true, created: false } when an idempotency key
  # matches an existing record.
  def call(params = {})
    account = resolve_account(params["account_id"])
    return error("account_not_found", "No account found with that ID that this user can write to.") unless account

    date = parse_date(params["date"])
    return error("invalid_date", "date must be an ISO 8601 date (YYYY-MM-DD).") unless date

    amount = parse_decimal(params["amount"])
    return error("invalid_amount", "amount must be a number.") if amount.nil?

    name = params["name"].to_s.strip
    return error("invalid_name", "name is required.") if name.empty?

    # Default to the account's own currency, then the family's primary currency —
    # the same fallback the app's create endpoint uses (it falls back to
    # family.currency; account.currency is the more precise per-account value).
    currency = (params["currency"].to_s.strip.presence || account.currency.presence || family.primary_currency_code).upcase
    return error("invalid_currency", "currency must be a valid ISO 4217 code.") unless valid_currency?(currency)

    entryable_attrs = resolve_entryable_attributes(params)
    return entryable_attrs if error_response?(entryable_attrs)

    signed_amount = signed_amount(amount, params["type"])

    entry_params = {
      name: name,
      date: date,
      amount: signed_amount,
      currency: currency,
      notes: params.key?("notes") ? params["notes"] : nil,
      entryable_type: "Transaction",
      entryable_attributes: entryable_attrs
    }

    if params["external_id"].present?
      entry_params[:external_id] = params["external_id"].to_s
      entry_params[:source] = params["source"].to_s.strip.presence || "mcp"
    end

    # Idempotency: a repeat (account, source, external_id) returns the existing
    # entry instead of inserting a duplicate. The partial unique index on
    # [account_id, source, external_id] makes this race-safe (see schema.rb).
    if entry_params[:external_id].present?
      existing = existing_idempotent_entry(account, entry_params)
      return existing_response(existing) if existing
    end

    entry = account.entries.new(entry_params)
    unless entry.save
      return error("validation_failed", entry.errors.full_messages.join("; "))
    end

    entry.lock_saved_attributes!
    entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?
    entry.mark_user_modified! if user_modified?(params)

    # Post-commit account sync is best-effort. entry.save has ALREADY committed
    # the transaction, so a failure to enqueue the balance-sync job (e.g. an
    # unavailable job backend) must NOT be reported as a failed create — doing
    # so would make an MCP caller retry without an external_id and create a
    # duplicate. Mirrors DeleteTransaction's post-destroy sync handling.
    sync_warning = nil
    begin
      entry.sync_account_later
    rescue StandardError => e
      sync_warning = "Transaction created, but the post-create account sync could not be enqueued (#{e.class}). The balance will recalculate on the next sync."
    end

    transaction = entry.transaction
    response = {
      success: true,
      created: true,
      transaction: serialize(transaction),
      message: "Created #{transaction.entry.name} (#{format_money(entry)} on #{date.iso8601})."
    }
    response[:warning] = sync_warning if sync_warning
    response
  rescue ActiveRecord::RecordNotUnique
    # Lost a race on the idempotency index: a concurrent call created it first.
    if entry_params[:external_id].present?
      existing = existing_idempotent_entry(account, entry_params)
      return existing_response(existing) if existing
    end
    raise
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    # Find a writable account by UUID, scoped to accounts the user can write to
    # (owner or full-control share). Returns nil if the id is not a valid UUID
    # or the account is not writable — callers treat that as not_found.
    def resolve_account(account_id)
      return nil unless valid_uuid?(account_id)

      family.accounts.writable_by(user).find_by(id: account_id)
    end

    # Always seed category/merchant/tag keys (nil / empty) so the nested
    # entryable builds exactly as the API's create endpoint does, then override
    # with any caller-supplied, family-validated values. Returns the attribute
    # hash, or an error hash if a supplied id does not belong to the family.
    def resolve_entryable_attributes(params)
      attrs = { category_id: nil, merchant_id: nil, tag_ids: [] }

      if params.key?("category_id")
        category_id = optional_uuid(params["category_id"])
        return category_id if error_response?(category_id)
        return error("invalid_category", "category_id does not belong to the user's family.") if category_id && !family.categories.exists?(id: category_id)

        attrs[:category_id] = category_id
      end

      if params.key?("merchant_id")
        merchant_id = optional_uuid(params["merchant_id"])
        return merchant_id if error_response?(merchant_id)
        return error("invalid_merchant", "merchant_id is not available to the user's family.") if merchant_id && !available_merchants.exists?(id: merchant_id)

        attrs[:merchant_id] = merchant_id
      end

      if params.key?("tag_ids")
        tag_ids = Array(params["tag_ids"]).map(&:to_s).reject(&:blank?)
        return error("invalid_tags", "One or more tag_ids do not belong to the user's family.") unless valid_tag_ids?(tag_ids)

        attrs[:tag_ids] = tag_ids
      end

      attrs
    end

    # Apply the amount sign convention: income/inflow -> negative (money in),
    # expense/outflow -> positive (money out). With no type, the amount is
    # returned exactly as given.
    def signed_amount(amount, type)
      case type&.to_s&.downcase
      when "income", "inflow" then -amount.abs
      when "expense", "outflow" then amount.abs
      else amount
      end
    end

    # Whether the caller asked to mark the transaction user-modified (so a
    # later provider sync will not overwrite it). Coerces the param to a boolean.
    def user_modified?(params)
      ActiveModel::Type::Boolean.new.cast(params["user_modified"])
    end

    # Coerce a nullable UUID parameter: returns nil for blank input, the value
    # if it is a valid UUID, or an error hash otherwise.
    def optional_uuid(value)
      return nil if value.nil? || value == ""
      return value.to_s if valid_uuid?(value)

      error("invalid_uuid", "Expected a valid UUID.")
    end

    # True if every supplied tag id belongs to the user's family (an empty list
    # is trivially valid).
    def valid_tag_ids?(tag_ids)
      return true if tag_ids.empty?

      family.tags.where(id: tag_ids).count == tag_ids.uniq.size
    end

    # The set of merchants available to this user's family, used to validate
    # a supplied merchant_id.
    def available_merchants
      family.available_merchants_for(user)
    end

    # Validate a currency code using the app's own Money currency table (rather
    # than a bare 3-letter regex), so an explicit unknown code is rejected the
    # same way the API rejects it.
    def valid_currency?(code)
      # Use the app's own currency validator (Money) rather than a bare
      # 3-letter regex, so an explicit "ABC" is rejected like the API does.
      Money::Currency.new(code)
      true
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      false
    end

    # Look up an existing entry matching the (external_id, source) idempotency
    # key on the given account; nil if there is no external_id or no match.
    def existing_idempotent_entry(account, entry_params)
      return nil unless entry_params[:external_id].present?

      account.entries.find_by(
        external_id: entry_params[:external_id],
        source: entry_params[:source]
      )
    end

    # Build the response for an idempotency hit. If the existing entry is a
    # transaction, return it with created: false; if it is some other entry
    # type, return an idempotency_conflict error.
    def existing_response(existing)
      return error("idempotency_conflict", "external_id already belongs to a non-transaction entry.") unless existing&.entryable&.is_a?(Transaction)

      # `existing` is the Entry; `serialize` expects the Transaction, which is
      # the entry's entryable (Entry has no `.entry` method — that direction
      # only exists on the Transaction side).
      {
        success: true,
        created: false,
        transaction: serialize(existing.entryable),
        message: "Transaction already exists for this external_id; returned the existing one."
      }
    end

    # Parse an ISO 8601 date string; returns nil if blank or not a valid date.
    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    # Parse a finite decimal from a value; returns nil if blank, non-numeric,
    # or a non-finite value (BigDecimal accepts "Infinity"/"NaN", which we
    # reject so a malformed amount can never reach the ledger).
    def parse_decimal(value)
      return nil if value.nil? || value.to_s.strip.empty?

      number = BigDecimal(value.to_s)
      # BigDecimal accepts "Infinity" / "NaN" strings; reject non-finite values
      # so a malformed amount can never reach the ledger.
      return nil unless number.finite?

      number
    rescue ArgumentError, TypeError
      nil
    end

    # Human-formatted money string for the entry's amount and currency, with a
    # plain "amount currency" fallback if formatting fails.
    def format_money(entry)
      entry.amount_money.format
    rescue StandardError
      "#{entry.amount} #{entry.currency}"
    end

    # Shape a Transaction into the result hash returned to the caller (id,
    # name, date, amount, currency, type, notes, and nested category/merchant/
    # tags).
    def serialize(transaction)
      entry = transaction.entry
      {
        id: transaction.id,
        entry_id: entry.id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.to_s,
        amount_formatted: format_money(entry),
        currency: entry.currency,
        type: entry.classification,
        notes: entry.notes,
        category: transaction.category && { id: transaction.category.id, name: transaction.category.name },
        merchant: transaction.merchant && { id: transaction.merchant.id, name: transaction.merchant.name },
        tags: transaction.tags.map { |tag| { id: tag.id, name: tag.name } }
      }
    end

    # True if a helper returned an error hash (a Hash with success == false),
    # used to short-circuit on validation failures from other helpers.
    def error_response?(value)
      value.is_a?(Hash) && value[:success] == false
    end

    # Build a standard error result hash: { success: false, error:, message: }.
    def error(key, message)
      { success: false, error: key, message: message }
    end
end
