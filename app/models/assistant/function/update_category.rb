class Assistant::Function::UpdateCategory < Assistant::Function
  class << self
    def name
      "update_category"
    end

    def description
      <<~INSTRUCTIONS
        Updates an existing category's name, color, icon, or parent.

        Use get_categories first to find the category id. At least one of name, color,
        icon, or parent_id must be supplied. Changing a parent's color does not cascade to
        existing subcategories (their colors are set when they are saved).

        Pass parent_id to move the category under another top-level category (it takes the
        parent's color), or pass an empty string to make it a top-level category. A category
        that has subcategories cannot itself become a subcategory.
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
        },
        parent_id: {
          type: "string",
          description: "ID of a top-level category to move this category under, or an empty string to make it top-level (optional)"
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


    if params.key?("parent_id")
      if params["parent_id"].present?
        parent = family.categories.find_by(id: params["parent_id"]) if valid_uuid?(params["parent_id"])
        return error("parent_not_found", "Parent category with id '#{params["parent_id"]}' not found.") unless parent
        return error("invalid_parent", "A category cannot be its own parent.") if parent == category
        attrs[:parent] = parent
      else
        attrs[:parent] = nil
      end
    end

    return error("no_changes", "Provide at least one of name, color, icon, or parent_id to update.") if attrs.empty?

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
