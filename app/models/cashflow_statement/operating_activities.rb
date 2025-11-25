class CashflowStatement::OperatingActivities
  include Monetizable

  attr_reader :family, :period

  def initialize(family, period:)
    @family = family
    @period = period
  end

  # Income from regular transactions (negative amounts = income)
  def inflows
    @inflows ||= totals[:income]
  end

  def inflows_money
    Money.new(inflows, family.currency)
  end

  # Expenses from regular transactions (positive amounts = expense)
  # Excludes loan_payment and cc_payment (those are financing)
  def outflows
    @outflows ||= totals[:expense]
  end

  def outflows_money
    Money.new(outflows, family.currency)
  end

  def net
    inflows - outflows
  end

  def net_money
    Money.new(net, family.currency)
  end

  # Breakdown by category
  def income_by_category
    @income_by_category ||= category_breakdown(:income)
  end

  def expenses_by_category
    @expenses_by_category ||= category_breakdown(:expense)
  end

  def summary
    Summary.new(
      inflows: inflows_money,
      outflows: outflows_money,
      net: net_money,
      income_by_category: income_by_category,
      expenses_by_category: expenses_by_category
    )
  end

  private
    Summary = Data.define(:inflows, :outflows, :net, :income_by_category, :expenses_by_category)
    CategoryTotal = Data.define(:category, :total, :currency, :weight)

    def totals
      @totals ||= begin
        result = ActiveRecord::Base.connection.select_one(totals_query_sql)
        {
          income: result["income"]&.to_d || 0,
          expense: result["expense"]&.to_d || 0
        }
      end
    end

    def totals_query_sql
      # Combined query for transactions AND categorized trades
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL,
          SELECT
            COALESCE(SUM(CASE WHEN amount < 0 THEN ABS(amount) ELSE 0 END), 0) as income,
            COALESCE(SUM(CASE WHEN amount > 0 THEN ABS(amount) ELSE 0 END), 0) as expense
          FROM (
            -- Transactions (excluding financing)
            SELECT ae.amount * COALESCE(er.rate, 1) as amount
            FROM transactions t
            JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
            JOIN accounts a ON a.id = ae.account_id
            LEFT JOIN exchange_rates er ON (
              er.date = ae.date AND
              er.from_currency = ae.currency AND
              er.to_currency = :target_currency
            )
            WHERE a.family_id = :family_id
              AND a.status IN ('draft', 'active')
              AND ae.excluded = false
              AND ae.date BETWEEN :start_date AND :end_date
              AND t.kind NOT IN ('funds_movement', 'one_time', 'cc_payment', 'loan_payment')

            UNION ALL

            -- Trades with categories assigned
            SELECT ae.amount * COALESCE(er.rate, 1) as amount
            FROM trades t
            JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Trade'
            JOIN accounts a ON a.id = ae.account_id
            LEFT JOIN exchange_rates er ON (
              er.date = ae.date AND
              er.from_currency = ae.currency AND
              er.to_currency = :target_currency
            )
            WHERE a.family_id = :family_id
              AND a.status IN ('draft', 'active')
              AND ae.excluded = false
              AND ae.date BETWEEN :start_date AND :end_date
              AND t.category_id IS NOT NULL
          ) combined
        SQL
        {
          family_id: family.id,
          target_currency: family.currency,
          start_date: period.start_date,
          end_date: period.end_date
        }
      ])
    end

    def category_breakdown(classification)
      direction_condition = classification == :income ? "amount < 0" : "amount > 0"

      sql = ActiveRecord::Base.sanitize_sql_array([
        <<~SQL,
          SELECT
            category_id,
            category_name,
            category_color,
            category_icon,
            ABS(SUM(amount)) as total
          FROM (
            -- Transactions
            SELECT
              c.id as category_id,
              c.name as category_name,
              c.color as category_color,
              c.lucide_icon as category_icon,
              ae.amount * COALESCE(er.rate, 1) as amount
            FROM transactions t
            JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
            JOIN accounts a ON a.id = ae.account_id
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN exchange_rates er ON (
              er.date = ae.date AND
              er.from_currency = ae.currency AND
              er.to_currency = :target_currency
            )
            WHERE a.family_id = :family_id
              AND a.status IN ('draft', 'active')
              AND ae.excluded = false
              AND ae.date BETWEEN :start_date AND :end_date
              AND t.kind NOT IN ('funds_movement', 'one_time', 'cc_payment', 'loan_payment')

            UNION ALL

            -- Trades with categories
            SELECT
              c.id as category_id,
              c.name as category_name,
              c.color as category_color,
              c.lucide_icon as category_icon,
              ae.amount * COALESCE(er.rate, 1) as amount
            FROM trades t
            JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Trade'
            JOIN accounts a ON a.id = ae.account_id
            LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN exchange_rates er ON (
              er.date = ae.date AND
              er.from_currency = ae.currency AND
              er.to_currency = :target_currency
            )
            WHERE a.family_id = :family_id
              AND a.status IN ('draft', 'active')
              AND ae.excluded = false
              AND ae.date BETWEEN :start_date AND :end_date
              AND t.category_id IS NOT NULL
          ) combined
          WHERE #{direction_condition}
          GROUP BY category_id, category_name, category_color, category_icon
          ORDER BY total DESC
        SQL
        {
          family_id: family.id,
          target_currency: family.currency,
          start_date: period.start_date,
          end_date: period.end_date
        }
      ])

      total_amount = classification == :income ? inflows : outflows

      ActiveRecord::Base.connection.select_all(sql).map do |row|
        category = if row["category_id"]
          OpenStruct.new(
            id: row["category_id"],
            name: row["category_name"],
            color: row["category_color"],
            lucide_icon: row["category_icon"]
          )
        else
          OpenStruct.new(
            id: nil,
            name: "Uncategorized",
            color: Category::UNCATEGORIZED_COLOR,
            lucide_icon: "circle-dashed"
          )
        end

        row_total = row["total"].to_d
        weight = total_amount.zero? ? 0 : (row_total / total_amount * 100)

        CategoryTotal.new(
          category: category,
          total: row_total,
          currency: family.currency,
          weight: weight
        )
      end
    end

    def monetizable_currency
      family.currency
    end
end
