class Assistant::Function::GetHoldings < Assistant::Function
  SUPPORTED_ACCOUNT_TYPES = %w[Investment Crypto].freeze

  class << self
    def default_page_size
      50
    end

    def name
      "get_holdings"
    end

    def description
      <<~INSTRUCTIONS
        Use this to search user's investment holdings by using various optional filters.

        This function is great for things like:
        - Finding specific holdings or securities
        - Getting portfolio composition and allocation
        - Viewing investment performance and cost basis

        Note: This function only returns holdings from Investment and Crypto accounts.

        Note on pagination:

        This function can be paginated. You can expect the following properties in the response:

        - `total_pages`: The total number of pages of results
        - `page`: The current page of results
        - `page_size`: The number of results per page (this will always be #{default_page_size})
        - `total_results`: The total number of results for the given filters
        - `total_value`: The total value of all holdings for the given filters

        Simple example (all current holdings):

        ```
        get_holdings({
          page: 1
        })
        ```

        More complex example (various filters):

        ```
        get_holdings({
          page: 1,
          accounts: ["Brokerage Account"],
          securities: ["AAPL", "GOOGL"]
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "page" ],
      properties: {
        page: {
          type: "integer",
          minimum: 1,
          description: "Page number"
        },
        accounts: {
          type: "array",
          description: "Filter holdings by account name (only Investment and Crypto accounts are supported)",
          items: { enum: investment_account_names },
          minItems: 1,
          uniqueItems: true
        },
        securities: {
          type: "array",
          description: "Filter holdings by security ticker symbol",
          items: { enum: family_security_tickers },
          minItems: 1,
          uniqueItems: true
        }
      }
    )
  end

  def call(params = {})
    holdings = build_holdings_query(params).includes(:security, :account).to_a

    # A provider snapshot can be in another currency than the account, and the
    # family's accounts can differ too, so amounts are converted to the family
    # currency before they are ordered and totaled. They convert at today's
    # rate, as InvestmentStatement and the balance sheet do for family totals,
    # even when a provider snapshot is dated earlier. (Account#current_holdings_total
    # uses each holding's own date, but converts into the account currency for
    # the weights.) A currency with no rate counts as 0 rather than 1:1.
    rates = ExchangeRate.rates_for(holdings.map(&:currency), to: family.currency, date: Date.current)
    family_amounts = holdings.index_with { |holding| holding.amount * (rates[holding.currency] || 0) }

    ordered_holdings = holdings.sort_by { |holding| [ -family_amounts[holding], holding.id ] }
    pagy = Pagy.new(count: ordered_holdings.size, page: resolved_page(params), limit: default_page_size)
    paginated_holdings = ordered_holdings[pagy.offset, pagy.limit] || []

    total_value = family_amounts.values.sum

    normalized_holdings = paginated_holdings.map do |holding|
      {
        ticker: holding.ticker,
        name: holding.name,
        quantity: holding.qty.to_f,
        price: holding.price.to_f,
        currency: holding.currency,
        amount: holding.amount.to_f,
        formatted_amount: holding.amount_money.format,
        weight: holding.weight&.round(2),
        average_cost: holding.avg_cost&.to_f,
        formatted_average_cost: holding.avg_cost&.format,
        account: holding.account.name,
        date: holding.date
      }
    end

    {
      holdings: normalized_holdings,
      total_results: pagy.count,
      page: pagy.page,
      page_size: default_page_size,
      total_pages: pagy.pages,
      total_value: Money.new(total_value, family.currency).format
    }
  end

  private
    def default_page_size
      self.class.default_page_size
    end

    def build_holdings_query(params)
      accounts = investment_accounts

      if params["accounts"].present?
        accounts = accounts.where(name: params["accounts"])
      end

      # The rows each account's Holdings tab shows, so the quantity and average
      # cost match it. On a provider-linked account these are the provider rows
      # on the latest snapshot date. The newest row there can be a calculated
      # one dated today, whose cost basis covers only the imported trades.
      holdings = Holding.where(id: accounts.flat_map { |account| account.current_holdings.ids })

      if params["securities"].present?
        holdings = holdings.joins(:security).where(securities: { ticker: params["securities"] })
      end

      holdings
    end

    def investment_accounts
      user.accessible_accounts.visible.where(accountable_type: SUPPORTED_ACCOUNT_TYPES)
    end

    def investment_account_names
      @investment_account_names ||= investment_accounts.pluck(:name)
    end

    def family_security_tickers
      @family_security_tickers ||= Security
        .where(id: Holding.where(account_id: investment_accounts.select(:id)).select(:security_id))
        .distinct
        .pluck(:ticker)
    end
end
