class Assistant::Function::DeleteCategory < Assistant::Function
  class << self
    def name
      "delete_category"
    end

    def description
      <<~INSTRUCTIONS
        Deletes a category from the user's family. This cannot be undone.

        Use get_categories first to find the category id. Transactions in the deleted category
        are moved to replacement_id when given, otherwise they become uncategorized. Subcategories
        of a deleted top-level category are kept and become top-level categories. Budget
        allocations for the deleted category are removed.

        Confirm with the user before calling this tool.
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
        id: { type: "string", description: "ID of the category to delete (use get_categories to find it)" },
        replacement_id: { type: "string", description: "Optional category ID to move the deleted category's transactions to" },
        replacement_category_id: { type: [ "string", "null" ], description: "Existing clients may use this alias for replacement_id; do not provide conflicting IDs" }
      }
    )
  end

  def call(params = {})
    return error("not_authorized", "Guests cannot delete categories.") if user.guest?

    category_id = valid_uuid?(params["id"]) ? params["id"].to_s : nil
    return error("not_found", "Category not found.") unless category_id

    if params.key?("replacement_id") && params.key?("replacement_category_id") && params["replacement_id"] != params["replacement_category_id"]
      return error("invalid_replacement", "Provide only one replacement category.")
    end

    replacement_id = params.key?("replacement_id") ? params["replacement_id"] : params["replacement_category_id"]
    if !replacement_id.nil? && !valid_uuid?(replacement_id)
      return error("replacement_not_found", "Replacement category not found.")
    end
    replacement_id = replacement_id.to_s unless replacement_id.nil?
    return error("invalid_replacement", "A category cannot replace itself.") if replacement_id == category_id

    Category.transaction do
      categories = family.categories.where(id: [ category_id, replacement_id ].compact).order(:id).lock.index_by { |category| category.id.to_s }
      category = categories[category_id]
      next error("not_found", "Category not found.") unless category
      replacement = replacement_id && categories[replacement_id]
      next error("replacement_not_found", "Replacement category not found.") if replacement_id && !replacement

      name = category.name_with_parent
      category.replace_and_destroy!(replacement)
      message = "Category '#{name}' deleted."
      message += " Its transactions were moved to '#{replacement.reload.name_with_parent}'." if replacement
      {
        success: true, id: category_id, replacement_id: replacement&.id,
        deleted_category_id: category_id, replacement_category_id: replacement&.id, message: message
      }
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    error("delete_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def error(key, message)
      { success: false, error: key, message: message }
    end
end
