class Assistant::Function::UpdateTransaction < Assistant::Function
  class << self
    def name
      "update_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Updates an existing transaction.

        Use get_transactions first to find the transaction id, and get_categories,
        get_tags, or the current transaction merchant before referencing related ids.

        This tool can update the amount, date, income/expense nature, name, notes,
        category, merchant, and tags. It will not edit split or linked transfer
        transactions directly; use the dedicated transfer tools for those.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: {
          type: "string",
          description: "Transaction ID from get_transactions"
        },
        name: {
          type: "string",
          description: "New transaction name. Omit to leave unchanged."
        },
        amount: {
          type: "number",
          exclusiveMinimum: 0,
          description: "New positive amount in major currency units. Omit to leave unchanged."
        },
        date: {
          type: "string",
          format: "date",
          description: "New transaction date in YYYY-MM-DD format. Omit to leave unchanged."
        },
        nature: {
          type: "string",
          enum: [ "expense", "income" ],
          description: "Whether the transaction is an expense or income. Omit to leave unchanged."
        },
        notes: {
          type: [ "string", "null" ],
          description: "New transaction notes. Use null to clear notes. Omit to leave unchanged."
        },
        category_id: {
          type: [ "string", "null" ],
          description: "Category ID from get_categories. Use null to clear category. Omit to leave unchanged."
        },
        merchant_id: {
          type: [ "string", "null" ],
          description: "Merchant ID currently available to the family. Use null to clear merchant. Omit to leave unchanged."
        },
        tag_ids: {
          type: "array",
          items: { type: "string" },
          description: "Full list of tag IDs to set. Use an empty array to clear all tags. Omit to leave unchanged."
        }
      }
    )
  end

  def call(params = {})
    transaction = find_transaction(params["id"])
    return error("not_found", "Transaction with id '#{params["id"]}' not found.") unless transaction

    tag_ids = nil
    if params.key?("tag_ids")
      tag_ids = Array(params["tag_ids"]).map(&:to_s).reject(&:blank?)
      return error("invalid_tags", "One or more tag_ids do not belong to the user's family.") unless valid_tag_ids?(tag_ids)
    end

    result = nil
    Entry.transaction do
      entry = transaction.entry
      entry.lock!
      transaction.lock!
      entry.association(:entryable).target = transaction

      if entry.split_child?
        result = error("split_child", "Split child transactions cannot be edited directly. Use the split editor.")
        next
      end
      if financial_fields?(params) && (entry.split_parent? || transaction.transfer.present?)
        result = error("complex_transaction", "Split and linked transfer transactions must be edited with their dedicated tools.")
        next
      end
      unless permitted_to_update?(entry.account, params)
        result = error("not_authorized", "You do not have permission to update this transaction.")
        next
      end

      entry_attrs = entry_attributes(params, entry)
      if error_response?(entry_attrs)
        result = entry_attrs
        next
      end
      if no_changes?(entry_attrs, params)
        result = error("no_changes", "Provide at least one field to update.")
        next
      end

      entry.update!(entry_attrs)

      if params.key?("tag_ids")
        transaction.tag_ids = tag_ids
        transaction.save!
      end

      entry.sync_account_later
      entry.lock_saved_attributes!
      transaction.reload.lock_attr!(:tag_ids) if params.key?("tag_ids")
    end
    return result if result

    {
      success: true,
      transaction: serialize(transaction.reload),
      message: "Transaction '#{transaction.entry.name}' updated."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def find_transaction(id)
      return nil unless valid_uuid?(id)

      family.transactions
        .joins(:entry)
        .where(entries: { account_id: user.accessible_accounts.visible.select(:id) })
        .find_by(id: id)
    end

    def permitted_to_update?(account, params)
      permission = account.permission_for(user)
      return true if permission.in?([ :owner, :full_control ])

      permission == :read_write && (params.keys & %w[name amount date nature]).empty?
    end

    def entry_attributes(params, entry)
      entryable_attrs = { id: entry.entryable_id }

      if params.key?("category_id")
        category_id = optional_uuid(params["category_id"])
        return category_id if error_response?(category_id)
        return error("invalid_category", "category_id does not belong to the user's family.") if category_id && !family.categories.exists?(id: category_id)

        entryable_attrs[:category_id] = category_id
      end

      if params.key?("merchant_id")
        merchant_id = optional_uuid(params["merchant_id"])
        return merchant_id if error_response?(merchant_id)
        return error("invalid_merchant", "merchant_id is not available to the user's family.") if merchant_id && !available_merchants.exists?(id: merchant_id)

        entryable_attrs[:merchant_id] = merchant_id
      end

      attrs = {}
      attrs[:name] = params["name"].to_s.strip if params.key?("name")
      attrs[:notes] = params["notes"] if params.key?("notes")

      if financial_fields?(params)
        nature = params.fetch("nature", entry.amount.negative? ? "income" : "expense")
        return error("invalid_nature", "nature must be either 'expense' or 'income'.") unless nature.in?(%w[expense income])

        amount = params.key?("amount") ? decimal_amount(params["amount"]) : entry.amount.abs
        return amount if error_response?(amount)
        attrs[:amount] = nature == "income" ? -amount : amount

        if params.key?("date")
          begin
            attrs[:date] = Date.iso8601(params["date"].to_s)
          rescue Date::Error
            return error("invalid_date", "date must use YYYY-MM-DD format.")
          end
        end
      end

      attrs[:entryable_attributes] = entryable_attrs if entryable_attrs.keys.size > 1
      attrs
    end

    def financial_fields?(params)
      (params.keys & %w[amount date nature]).any?
    end

    def decimal_amount(value)
      amount = BigDecimal(value.to_s)
      return error("invalid_amount", "amount must be greater than 0.") unless amount.positive? && amount.finite?

      amount
    rescue ArgumentError
      error("invalid_amount", "amount must be a finite number greater than 0.")
    end

    def optional_uuid(value)
      return nil if value.nil? || value == ""
      return value.to_s if valid_uuid?(value)

      error("invalid_uuid", "Expected a valid UUID.")
    end

    def valid_tag_ids?(tag_ids)
      family.tags.where(id: tag_ids).count == tag_ids.uniq.size
    end

    def available_merchants
      family.available_merchants_for(user)
    end

    def no_changes?(entry_attrs, params)
      entry_attrs.empty? && !params.key?("tag_ids")
    end

    def serialize(transaction)
      entry = transaction.entry
      {
        id: transaction.id,
        account_id: entry.account_id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.abs,
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
        tags: transaction.tags.map { |tag| { id: tag.id, name: tag.name } }
      }
    end

    def error_response?(value)
      value.is_a?(Hash) && value[:success] == false
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
