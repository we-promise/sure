class Assistant::Function::GetTags < Assistant::Function
  class << self
    def default_page_size
      50
    end

    def name
      "get_tags"
    end

    def description
      <<~INSTRUCTIONS
        Returns tags defined for the user's family, sorted alphabetically, with pagination.

        Use this when the user wants to see available tags or before referencing
        a tag in another operation like create_tag or update_tag.

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
    tags_scope = family.tags.alphabetically
    page_size = resolved_page_size(params)
    pagy = Pagy.new(count: tags_scope.count, page: resolved_page(params), limit: page_size)
    tags = tags_scope.offset(pagy.offset).limit(pagy.limit)

    {
      tags: tags.map { |t| { id: t.id, name: t.name, color: t.color } },
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages
    }
  end
end
