class Assistant::Function::GetCategories < Assistant::Function
  include Pagy::Backend

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
        - `page_size`: The number of results per page (this will always be #{default_page_size})
        - `total_results`: The total number of results
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        page: {
          type: "integer",
          description: "Page number (defaults to 1)"
        }
      }
    )
  end

  def call(params = {})
    pagy, categories = pagy(
      family.categories.alphabetically_by_hierarchy,
      page: params["page"] || 1,
      limit: default_page_size
    )

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
      page_size: default_page_size,
      total_pages: pagy.pages
    }
  end

  private
    def default_page_size
      self.class.default_page_size
    end
end
