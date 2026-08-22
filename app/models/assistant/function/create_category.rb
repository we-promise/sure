class Assistant::Function::CreateCategory < Assistant::Function
  class << self
    def name
      "create_category"
    end

    def description
      <<~INSTRUCTIONS
        Creates a new category for the user's family.

        Categories support two levels of hierarchy: a top-level category can have subcategories,
        but subcategories cannot have children. Provide parent_id (from get_categories) to make
        a subcategory — it will inherit the parent's color automatically.

        If icon is omitted it is suggested from the name. If color is omitted a palette color is used
        (ignored for subcategories since color is inherited). Category names must be unique.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "name" ],
      properties: {
        name: {
          type: "string",
          description: "Category name (must be unique within the family)"
        },
        color: {
          type: "string",
          description: "Hex color code (e.g. #e99537). Ignored for subcategories. Defaults to a palette color."
        },
        icon: {
          type: "string",
          description: "Lucide icon name (e.g. 'shopping-cart'). Suggested from name if omitted."
        },
        parent_id: {
          type: "string",
          description: "ID of an existing top-level category to nest under (makes this a subcategory). Use get_categories to find ids."
        }
      }
    )
  end

  def call(params = {})
    name = params["name"].to_s.strip
    return error("name_required", "Please provide a name for the category.") if name.blank?

    color = params["color"].presence || Category::COLORS.sample
    icon = params["icon"].presence || Category.suggested_icon(name)
    attrs = { name: name, color: color, lucide_icon: icon }

    if params["parent_id"].present?
      return error("parent_not_found", "Parent category with id '#{params["parent_id"]}' not found.") unless valid_uuid?(params["parent_id"])
      parent = family.categories.find_by(id: params["parent_id"])
      return error("parent_not_found", "Parent category with id '#{params["parent_id"]}' not found.") unless parent
      attrs[:parent] = parent
    end

    category = family.categories.new(attrs)

    if category.save
      { success: true, category: serialize(category), message: "Category '#{category.name_with_parent}' created." }
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
