class Assistant::Function::GetCategoryTrends < Assistant::Function
  DEFAULT_LIMIT = 8
  MAX_LIMIT = 25

  class << self
    def name
      "get_category_trends"
    end

    def description
      <<~INSTRUCTIONS
        Monthly spending per category over the last N months, with the direction
        each one is moving.

        Use this instead of pulling months of transactions: one call replaces
        thousands of rows, and the arithmetic is already done.

        A single month cannot distinguish an unusual month from a habit that has
        been drifting all year. "You spent 300 on restaurants" is rarely the
        useful sentence; "restaurant spending went from 150 to 300 a month over
        eight months" is.

        Per category you get `values` (one figure per month, oldest first,
        aligned with `months`), the total and average, `slope_per_month`, the
        two half-period averages and `change_pct` between them, and a
        `direction`.

        `direction` is "rising" or "falling" ONLY when the slope and the
        half-over-half change agree, so a single holiday month is not reported
        as a trend. It reads "unclear" when they disagree, which is itself
        informative: the category is volatile rather than drifting. Quote the
        two half averages when you claim a trend; they are what a person would
        compute by eye and can check.

        Figures exclude transfers between the user's own accounts, pending
        transactions and tax-advantaged accounts, the same as the income
        statement.
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
        months: {
          type: "integer",
          minimum: 2,
          maximum: IncomeStatement::CategoryTrends::MAX_MONTHS,
          description: "How many months back (defaults to #{IncomeStatement::CategoryTrends::DEFAULT_MONTHS})"
        },
        classification: {
          type: "string",
          enum: [ "expense", "income" ],
          description: "Defaults to expense"
        },
        categories: {
          type: "array",
          items: { type: "string" },
          description: "Exact category names to restrict to (from get_categories). Defaults to the largest ones."
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: MAX_LIMIT,
          description: "How many categories to return, largest total first (defaults to #{DEFAULT_LIMIT})"
        }
      }
    )
  end

  def call(params = {})
    trends = IncomeStatement::CategoryTrends.new(
      family,
      user: user,
      months: params["months"] || IncomeStatement::CategoryTrends::DEFAULT_MONTHS,
      classification: params["classification"].to_s
    )

    selected = filter(trends.series, params)
    limit = (Integer(params["limit"].to_s, exception: false) || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)

    {
      as_of_date: Date.current,
      currency: family.currency,
      classification: trends.classification,
      months: trends.month_labels,
      categories: selected.first(limit).map { |entry| serialize(entry) },
      truncated: selected.size > limit
    }
  end

  private
    def filter(series, params)
      names = Array(params["categories"]).map(&:to_s).map(&:downcase)
      return series if names.empty?

      series.select { |entry| names.include?(entry.category.downcase) }
    end

    def serialize(entry)
      {
        category: entry.category,
        values: entry.values.map(&:to_f),
        total: entry.total,
        monthly_average: entry.average,
        first_half_average: entry.first_half_average,
        second_half_average: entry.second_half_average,
        change_pct: entry.change_pct,
        slope_per_month: entry.slope_per_month,
        direction: entry.direction
      }.compact
    end
end
