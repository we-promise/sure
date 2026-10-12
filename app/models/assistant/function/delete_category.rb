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
        id: {
          type: "string",
          description: "ID of the category to delete (use get_categories to find it)"
        },
        replacement_id: {
          type: "string",
          description: "ID of a category to move the deleted category's transactions to (optional). Transactions become uncategorized if omitted."
        }
      }
    )
  end

  def call(params = {})
    # Matches Category::DeletionsController, which rejects guests.
    return error("forbidden", "Guests cannot delete categories.") if user.guest?

    category = find_category(params["id"])
    return error("not_found", "Category with id '#{params["id"]}' not found.") unless category

    replacement = nil
    if params["replacement_id"].present?
      replacement = find_category(params["replacement_id"])
      return error("replacement_not_found", "Replacement category with id '#{params["replacement_id"]}' not found.") unless replacement
      return error("invalid_replacement", "A category cannot replace itself.") if replacement == category
    end

    name = category.name_with_parent
    category.replace_and_destroy!(replacement)

    message = "Category '#{name}' deleted."
    message += " Its transactions were moved to '#{replacement.reload.name_with_parent}'." if replacement
    { success: true, id: category.id, replacement_id: replacement&.id, message: message }
  end

  private
    def find_category(id)
      family.categories.find_by(id: id) if valid_uuid?(id)
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
