class Assistant::Function::DeleteCategory < Assistant::Function
  class << self
    def name = "delete_category"
    def description = "Permanently deletes a family category, optionally reassigning transactions to another category."
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Category ID from get_categories" },
        replacement_category_id: { type: [ "string", "null" ], description: "Optional replacement category ID" }
      }
    )
  end

  def call(params = {})
    category_id = normalized_uuid(params["id"])
    return error("not_found", "Category not found.") unless category_id

    replacement_id = params["replacement_category_id"].presence
    if replacement_id && !valid_uuid?(replacement_id)
      return error("invalid_replacement", "Replacement category not found.")
    end
    replacement_id = replacement_id.to_s if replacement_id
    return error("invalid_replacement", "Replacement category must differ from the deleted category.") if replacement_id == category_id

    Category.transaction do
      categories = family.categories
        .where(id: [ category_id, replacement_id ].compact)
        .order(:id)
        .lock
        .index_by { |category| category.id.to_s }
      category = categories[category_id]
      return error("not_found", "Category not found.") unless category
      replacement = replacement_id && categories[replacement_id]
      return error("invalid_replacement", "Replacement category not found.") if replacement_id && !replacement

      name = category.name
      category.replace_and_destroy!(replacement)
      {
        success: true,
        deleted_category_id: category_id,
        replacement_category_id: replacement&.id,
        message: "Category '#{name}' deleted."
      }
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    message = e.record.respond_to?(:errors) ? e.record.errors.full_messages.join("; ") : e.message
    error("delete_failed", message)
  end

  private
    def normalized_uuid(value)
      valid_uuid?(value) ? value.to_s : nil
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
