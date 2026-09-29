class Assistant::Function::GetMerchants < Assistant::Function
  class << self
    def default_page_size
      50
    end

    def name
      "get_merchants"
    end

    def description
      <<~INSTRUCTIONS
        Returns merchants relevant to the user's transactions, sorted alphabetically,
        with pagination. Each entry includes the stable id needed for
        update_transaction's merchant_id and the exact name usable in
        get_transactions' merchants filter.

        Pass `search` to filter by name instead of paging through everything.
      INSTRUCTIONS
    end
  end

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
        },
        search: {
          type: "string",
          description: "Case-insensitive substring filter on merchant name"
        }
      }
    )
  end

  def call(params = {})
    # available_merchants_for scopes to merchants on transactions in accounts
    # this user can access (plus the family's own merchants), so merchants
    # seen only in accounts hidden from the user never leak into the list.
    scope = family.available_merchants_for(user).alphabetically

    if params["search"].present?
      scope = scope.where("merchants.name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params["search"])}%")
    end

    page_size = resolved_page_size(params)
    pagy = Pagy.new(count: scope.count, page: resolved_page(params), limit: page_size)
    merchants = scope.offset(pagy.offset).limit(pagy.limit)

    {
      merchants: merchants.map { |m|
        {
          id: m.id,
          name: m.name,
          source: m.type == "FamilyMerchant" ? "family" : "provider"
        }
      },
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages
    }
  end
end
