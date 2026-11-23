# DeleteCategory — deletes a category, moving its transactions to a
# replacement or leaving them uncategorized. A call without preview_token
# deletes nothing and returns what would change plus a token; only a call with
# that token deletes (see PreviewToken).
class Assistant::Function::DeleteCategory < Assistant::Function
  include Assistant::Function::PreviewToken

  annotate :destructive, idempotent: true

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

        Always two calls. First call it without preview_token: nothing is
        deleted, and it returns the category, how many transactions it holds,
        where they would go, and a preview_token. Show that to the user, and
        only once they confirm call it again with the same id, the same
        replacement_id and that preview_token. The token expires after
        #{Assistant::Function::PreviewToken::PREVIEW_TOKEN_TTL.inspect} and is refused if any of that changed since the preview.
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
        },
        preview_token: {
          type: "string",
          description: "preview_token from the preview call with the same id and replacement_id. Omit it to preview; nothing is deleted without it."
        }
      }
    )
  end

  def call(params = {})
    category = find_category(params["id"])
    return error("not_found", "Category with id '#{params["id"]}' not found.") unless category

    replacement = nil
    # Only an omitted or null replacement_id uncategorizes the transactions; any
    # other value, blank included, must be the id of a category in the family.
    unless params["replacement_id"].nil?
      replacement = find_category(params["replacement_id"])
      return error("replacement_not_found", "Replacement category with id '#{params["replacement_id"]}' not found.") unless replacement
      return error("invalid_replacement", "A category cannot replace itself.") if replacement == category
    end

    preview_before_delete(params, category, preview(category, replacement)) do
      name = category.name_with_parent
      category.replace_and_destroy!(replacement)

      message = "Category '#{name}' deleted."
      message += " Its transactions were moved to '#{replacement.reload.name_with_parent}'." if replacement
      { success: true, deleted: true, id: category.id, replacement_id: replacement&.id, message: message }
    end
  end

  private
    # What deleting the category would change; the token is bound to it.
    def preview(category, replacement)
      {
        category: { id: category.id, name: category.name_with_parent },
        transaction_count: category.transactions.count,
        replacement: replacement && { id: replacement.id, name: replacement.name_with_parent },
        subcategories: category.subcategories.order(:name).pluck(:name),
        budget_allocations: category.budget_categories.count
      }
    end

    def find_category(id)
      family.categories.find_by(id: id) if valid_uuid?(id)
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
