class Assistant::Function::UpdateCategory < Assistant::Function
  class << self
    def name
      "update_category"
    end

    def description
      <<~INSTRUCTIONS
        Updates an existing category's name, color, or icon.

        Use get_categories first to find the category id. At least one of name, color,
        or icon must be supplied. Changing a parent's color does not cascade to existing
        subcategories (their colors are set at creation time).
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
          description: "ID of the category to update (use get_categories to find it)"
        },
        name: {
          type: "string",
          description: "New name for the category (optional)"
        },
        color: {
          type: "string",
          description: "New hex color code (optional)"
        },
        icon: {
          type: "string",
          description: "New Lucide icon name (optional)"
        }
      }
    )
  end

  def call(params = {})
    return error("not_found", "Category with id '#{params["id"]}' not found.") unless valid_uuid?(params["id"])
    category = family.categories.find_by(id: params["id"])
    return error("not_found", "Category with id '#{params["id"]}' not found.") unless category

    attrs = {}
    attrs[:name] = params["name"].to_s.strip if params["name"].present?
    attrs[:color] = params["color"].to_s.strip if params["color"].present?
    attrs[:lucide_icon] = params["icon"].to_s.strip if params["icon"].present?

    return error("no_changes", "Provide at least one of name, color, or icon to update.") if attrs.empty?

    if category.update(attrs)
      { success: true, category: serialize(category), message: "Category '#{category.name_with_parent}' updated." }
    else
      error("validation_failed", category.errors.full_messages.join("; "))
    end
  end

  private
    def serialize(c)
      { id: c.id, name: c.name, name_with_parent: c.name_with_parent, color: c.color, icon: c.lucide_icon, parent_id: c.parent_id }
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
