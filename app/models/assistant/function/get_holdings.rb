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
    rates = exchange_rates_for(holdings)

    holdings_with_value = holdings.map do |holding|
      [ holding, convert_to_family_currency(holding.amount, holding.currency, rates) ]
    end

    total_value = holdings_with_value.sum { |(_, value)| value }

    # Sort by family-currency value so mixed-currency portfolios order correctly.
    sorted_holdings = holdings_with_value
      .sort_by { |(_, value)| -value }
      .map(&:first)

    pagy = Pagy.new(count: sorted_holdings.size, page: params["page"] || 1, limit: default_page_size)
    paginated_holdings = sorted_holdings.slice(pagy.offset, pagy.limit) || []

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

      holdings = Holding.where(account: accounts)
        .where(
          id: Holding.where(account: accounts)
            .select("DISTINCT ON (account_id, security_id) id")
            .where.not(qty: 0)
            .order(Arel.sql(
              Holding.latest_security_order_sql(
                partition_columns: %w[account_id security_id]
              )
            ))
        )

      if params["securities"].present?
        security_ids = family.securities.where(ticker: params["securities"]).pluck(:id)
        holdings = holdings.where(security_id: security_ids)
      end

      holdings
    end

    def exchange_rates_for(holdings)
      foreign = holdings.map(&:currency).uniq.reject { |currency| currency == family.currency }
      ExchangeRate.rates_for(foreign, to: family.currency, date: Date.current, fallback: nil)
    end

    def convert_to_family_currency(amount, from_currency, rates)
      return amount.to_d if from_currency == family.currency

      rate = rates[from_currency]
      return 0.to_d if rate.nil?

      amount.to_d * rate
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
