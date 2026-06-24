class Assistant::Function::GetCategories < Assistant::Function
  class << self
    def name
      "get_categories"
    end

    def description
      <<~INSTRUCTIONS
        Returns all categories for the user's family, ordered alphabetically by hierarchy.

        Each entry includes id, name, color, icon, parent_id (null for top-level), and
        name_with_parent (e.g. "Food & Drink > Restaurants"). Use this before creating
        subcategories or referencing a category by id in update_category.
      INSTRUCTIONS
    end
  end

  def call(params = {})
    categories = family.categories.alphabetically_by_hierarchy

    {
      categories: categories.map { |c|
        {
          id: c.id,
          name: c.name,
          name_with_parent: c.name_with_parent,
          color: c.color,
          icon: c.lucide_icon,
          parent_id: c.parent_id,
          is_subcategory: c.subcategory?
        }
      },
      total: categories.size
    }
  end
end
