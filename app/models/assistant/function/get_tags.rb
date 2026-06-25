class Assistant::Function::GetTags < Assistant::Function
  include Pagy::Backend

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
        - `page_size`: The number of results per page (this will always be #{default_page_size})
        - `total_results`: The total number of results
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [ "page" ],
      properties: {
        page: {
          type: "integer",
          description: "Page number"
        }
      }
    )
  end

  def call(params = {})
    pagy, tags = pagy(
      family.tags.alphabetically,
      page: params["page"] || 1,
      limit: default_page_size
    )

    {
      tags: tags.map { |t| { id: t.id, name: t.name, color: t.color } },
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
