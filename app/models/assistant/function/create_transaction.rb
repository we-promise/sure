class Assistant::Function::CreateTransaction < Assistant::Function
  class << self
    def name
      "create_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Creates an income or expense transaction on a writable account.

        Use get_accounts and get_categories first to resolve related ids. Every call
        must include a stable external_id so retries return the existing transaction
        instead of creating a duplicate.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "account_id", "amount", "date", "name", "nature", "external_id" ],
      properties: {
        account_id: {
          type: "string",
          description: "Writable account ID from get_accounts"
        },
        amount: {
          type: "number",
          exclusiveMinimum: 0,
          description: "Positive transaction amount"
        },
        date: {
          type: "string",
          format: "date",
          description: "Transaction date in YYYY-MM-DD format"
        },
        name: {
          type: "string",
          description: "Transaction name or description"
        },
        nature: {
          type: "string",
          enum: [ "expense", "income" ],
          description: "Whether the transaction is an expense or income"
        },
        category_id: {
          type: [ "string", "null" ],
          description: "Category ID from get_categories"
        },
        merchant_id: {
          type: [ "string", "null" ],
          description: "Merchant ID currently available to the family"
        },
        tag_ids: {
          type: "array",
          items: { type: "string" },
          uniqueItems: true,
          description: "Tag IDs from get_tags"
        },
        notes: {
          type: [ "string", "null" ],
          description: "Optional transaction notes"
        },
        external_id: {
          type: "string",
          description: "Stable caller-generated idempotency key"
        }
      }
    )
  end

  def call(params = {})
    attrs = normalized_attributes(params)
    return attrs if error_response?(attrs)

    account = family.accounts.visible.writable_by(user).find_by(id: params["account_id"])
    return error("account_not_found", "Writable account with id '#{params["account_id"]}' not found.") unless account

    existing_entry = account.entries.find_by(source: "mcp", external_id: attrs[:external_id])
    return existing_response(existing_entry) if existing_entry

    entry = account.entries.new(
      name: attrs[:name],
      amount: attrs[:amount],
      date: attrs[:date],
      currency: account.currency,
      notes: params["notes"],
      external_id: attrs[:external_id],
      source: "mcp",
      entryable: Transaction.new(
        category: attrs[:category],
        merchant: attrs[:merchant],
        tags: attrs[:tags]
      )
    )

    if entry.save
      entry.sync_account_later
      entry.lock_saved_attributes!
      entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?

      success_response(entry, created: true)
    else
      error("validation_failed", entry.errors.full_messages.join("; "))
    end
  rescue ActiveRecord::RecordNotUnique
    existing_entry = account&.entries&.find_by(source: "mcp", external_id: attrs[:external_id])
    existing_entry ? existing_response(existing_entry) : raise
  end

  private
    def normalized_attributes(params)
      name = params["name"].to_s.strip
      return error("name_required", "Please provide a transaction name.") if name.blank?

      external_id = params["external_id"].to_s.strip
      return error("external_id_required", "Please provide a stable external_id.") if external_id.blank?

      nature = params["nature"].to_s.downcase
      return error("invalid_nature", "nature must be 'expense' or 'income'.") unless nature.in?(%w[expense income])

      amount = BigDecimal(params["amount"].to_s)
      return error("invalid_amount", "amount must be greater than zero.") unless amount.positive?
      amount = -amount if nature == "income"

      date = Date.iso8601(params["date"].to_s)

      category = nil
      if params["category_id"].present?
        return error("invalid_category", "category_id does not belong to the user's family.") unless valid_uuid?(params["category_id"])
        category = family.categories.find_by(id: params["category_id"])
        return error("invalid_category", "category_id does not belong to the user's family.") unless category
      end

      merchant = nil
      if params["merchant_id"].present?
        return error("invalid_merchant", "merchant_id is not available to the user's family.") unless valid_uuid?(params["merchant_id"])
        merchant = family.available_merchants_for(user).find_by(id: params["merchant_id"])
        return error("invalid_merchant", "merchant_id is not available to the user's family.") unless merchant
      end

      tag_ids = Array(params["tag_ids"]).map(&:to_s).reject(&:blank?).uniq
      tags = family.tags.where(id: tag_ids).to_a
      return error("invalid_tags", "One or more tag_ids do not belong to the user's family.") unless tags.size == tag_ids.size

      {
        name: name,
        external_id: external_id,
        amount: amount,
        date: date,
        category: category,
        merchant: merchant,
        tags: tags
      }
    rescue ArgumentError
      error("invalid_parameters", "amount must be numeric and date must use YYYY-MM-DD format.")
    end

    def existing_response(entry)
      return error("idempotency_conflict", "external_id already belongs to a non-transaction entry.") unless entry.entryable.is_a?(Transaction)

      success_response(entry, created: false)
    end

    def success_response(entry, created:)
      {
        success: true,
        created: created,
        transaction: serialize(entry.transaction),
        message: created ? "Transaction '#{entry.name}' created." : "Transaction '#{entry.name}' already exists."
      }
    end

    def serialize(transaction)
      entry = transaction.entry
      {
        id: transaction.id,
        account_id: entry.account_id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.abs,
        currency: entry.currency,
        nature: entry.amount.negative? ? "income" : "expense",
        notes: entry.notes,
        category: transaction.category && {
          id: transaction.category.id,
          name: transaction.category.name
        },
        merchant: transaction.merchant && {
          id: transaction.merchant.id,
          name: transaction.merchant.name
        },
        tags: transaction.tags.map { |tag| { id: tag.id, name: tag.name } },
        external_id: entry.external_id,
        source: entry.source
      }
    end

    def error_response?(value)
      value.is_a?(Hash) && value[:success] == false
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
