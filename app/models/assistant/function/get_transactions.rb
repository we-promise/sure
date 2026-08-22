class Assistant::Function::GetTransactions < Assistant::Function
  class << self
    def default_page_size
      50
    end

    def name
      "get_transactions"
    end

    def description
      <<~INSTRUCTIONS
        Use this to search user's transactions by using various optional filters.

        This function is great for things like:
        - Finding specific transactions
        - Getting basic stats about a small group of transactions

        This function is not great for:
        - Large time periods (use the get_income_statement function for this)

        Filters take exact names: use the values returned by get_accounts,
        get_categories, get_merchants, and get_tags when unsure. Pass
        types: ["income", "expense"] to exclude transfers between the user's
        own accounts. Use a small page_size when you only need a few rows.

        Note on pagination:

        This function can be paginated.  You can expect the following properties in the response:

        - `total_pages`: The total number of pages of results
        - `page`: The current page of results
        - `page_size`: The number of results per page (defaults to #{default_page_size})
        - `total_results`: The total number of results for the given filters
        - `total_income`: The total income for the given filters
        - `total_expenses`: The total expenses for the given filters
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
          description: "Results per page (defaults to #{self.class.default_page_size}); use small values to save tokens"
        },
        order: {
          type: "string",
          enum: [ "asc", "desc" ],
          description: "Sort direction (defaults to desc)"
        },
        sort_by: {
          type: "string",
          enum: [ "date", "amount" ],
          description: "Sort by date (default) or by absolute amount"
        },
        search: {
          type: "string",
          description: "Search for transactions by name"
        },
        amount: {
          type: "string",
          description: "Amount for transactions (must be used with amount_operator)"
        },
        amount_operator: {
          type: "string",
          description: "Operator for amount (must be used with amount)",
          enum: [ "equal", "less", "greater" ]
        },
        start_date: {
          type: "string",
          description: "Start date for transactions in YYYY-MM-DD format"
        },
        end_date: {
          type: "string",
          description: "End date for transactions in YYYY-MM-DD format"
        },
        types: {
          type: "array",
          description: "Filter by kind; [\"income\", \"expense\"] excludes transfers between the user's own accounts",
          items: { enum: [ "income", "expense", "transfer" ] },
          minItems: 1,
          uniqueItems: true
        },
        statuses: {
          type: "array",
          description: "Filter by status",
          items: { enum: [ "pending", "confirmed" ] },
          minItems: 1,
          uniqueItems: true
        },
        account_ids: {
          type: "array",
          description: "Filter by account UUIDs as returned by get_accounts",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        accounts: {
          type: "array",
          description: "Filter by exact account names as returned by get_accounts",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        categories: {
          type: "array",
          description: "Filter by exact category names as returned by get_categories (\"Uncategorized\" is accepted)",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        merchants: {
          type: "array",
          description: "Filter by exact merchant names as returned by get_merchants",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        tags: {
          type: "array",
          description: "Filter by exact tag names as returned by get_tags",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        }
      }
    )
  end

  def call(params = {})
    search_params = params.except("order", "page", "page_size", "sort_by")
    search_params["status"] = search_params.delete("statuses") if search_params.key?("statuses")

    search = Transaction::Search.new(
      family,
      filters: search_params,
      accessible_account_ids: user.accessible_accounts.visible.pluck(:id)
    )
    transactions_query = search.transactions_scope
    pagy_query = ordered(transactions_query, params)

    # By default, we give a small page size to force the AI to use filters effectively and save on tokens
    page_size = resolved_page_size(params)
    pagy = Pagy.new(count: pagy_query.count, page: resolved_page(params), limit: page_size)
    paginated_transactions = pagy_query.includes(
      { entry: :account },
      :category, :merchant, :tags,
      transfer_as_outflow: { inflow_transaction: { entry: :account } },
      transfer_as_inflow: { outflow_transaction: { entry: :account } }
    ).offset(pagy.offset).limit(pagy.limit)

    totals = search.totals

    normalized_transactions = paginated_transactions.map do |txn|
      entry = txn.entry
      {
        id: txn.id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.abs,
        currency: entry.currency,
        formatted_amount: entry.amount_money.abs.format,
        classification: entry.amount < 0 ? "income" : "expense",
        account: entry.account.name,
        notes: entry.notes,
        category: txn.category&.name,
        merchant: txn.merchant&.name,
        tags: txn.tags.map(&:name),
        is_transfer: txn.transfer?
      }
    end

    {
      transactions: normalized_transactions,
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages,
      total_income: totals.income_money.format,
      total_expenses: totals.expense_money.format
    }
  end

  private
    def ordered(query, params)
      if params["sort_by"] == "amount"
        # Fully literal order strings; nothing user-provided reaches Arel.sql
        if params["order"] == "asc"
          query.order(Arel.sql("ABS(entries.amount) ASC"), Arel.sql("entries.date DESC"))
        else
          query.order(Arel.sql("ABS(entries.amount) DESC"), Arel.sql("entries.date DESC"))
        end
      else
        params["order"] == "asc" ? query.chronological : query.reverse_chronological
      end
    end
end
