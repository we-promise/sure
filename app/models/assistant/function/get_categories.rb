class Assistant::Function::GetCategories < Assistant::Function
  class << self
    def default_page_size
      50
    end

    def name
      "get_categories"
    end

    def description
      <<~INSTRUCTIONS
        Returns categories for the user's family, ordered alphabetically by hierarchy, with pagination.

        Each entry includes id, name, color, icon, parent_id (null for top-level), and
        name_with_parent (e.g. "Food & Drink > Restaurants"). Use this before creating
        subcategories or referencing a category by id in update_category.

        Note on pagination:

        This function can be paginated. You can expect the following properties in the response:

        - `total_pages`: The total number of pages of results
        - `page`: The current page of results
        - `page_size`: The number of results per page (defaults to #{default_page_size})
        - `total_results`: The total number of results
      INSTRUCTIONS
    end
  end

  # Optional params are incompatible with strict function calling, which
  # requires every declared property to be listed in `required`.
  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        page: {
          type: "integer",
          minimum: 1,
          description: "Page number (defaults to 1)"
        },
        page_size: {
          type: "integer",
          minimum: 1,
          maximum: MAX_PAGE_SIZE,
          description: "Results per page (defaults to #{self.class.default_page_size})"
        }
      }
    )
  end

  def call(params = {})
    categories_scope = family.categories.alphabetically_by_hierarchy
    page_size = resolved_page_size(params)
    pagy = Pagy.new(count: categories_scope.count, page: resolved_page(params), limit: page_size)
    categories = categories_scope.offset(pagy.offset).limit(pagy.limit)

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
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages
    }
  end
end
