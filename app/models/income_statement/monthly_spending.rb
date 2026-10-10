# Monthly gross expenses, grouped by root category in the family currency.
# Shared by the web dashboard and mobile API; no client-side accounting rules.
class IncomeStatement::MonthlySpending
  include IncomeStatement::ScopedTransactionsQuery

  MAX_MONTHS = 36
  class InvalidSelection < ArgumentError; end

  attr_reader :accounts, :categories, :account_ids, :category_ids, :from, :to

  def initialize(statement, params: {}, as_of: Date.current)
    @family = statement.family
    @as_of = as_of
    @accounts = statement.eligible_accounts.order(:name).to_a
    @categories = @family.categories.roots.order(:name).map do |category|
      { id: category.id.to_s, name: category.name, color: category.color }
    end
    @categories << { id: Category::UNCATEGORIZED_FILTER_VALUE,
                     name: I18n.t("models.category.uncategorized"), color: Category::UNCATEGORIZED_COLOR }

    @to = params[:to].nil? ? as_of.beginning_of_month : parse_month(params[:to])
    @from = params[:from].nil? ? @to - 11.months : parse_month(params[:from])
    months = (@to.year - @from.year) * 12 + @to.month - @from.month + 1
    unless (1..MAX_MONTHS).cover?(months) && @to <= as_of.beginning_of_month
      raise InvalidSelection, "Select 1–36 months ending no later than the current month"
    end

    @included_account_ids = @account_ids = select_ids(params[:account_ids], accounts.map { |a| a.id.to_s })
    @category_ids = select_ids(params[:category_ids], categories.pluck(:id))
    @date_range = @from..[ @to.end_of_month, as_of ].min
    @transactions_scope = @family.transactions.visible.excluding_pending.in_period(
      Period.custom(start_date: @date_range.begin, end_date: @date_range.end)
    )
  end

  def as_json(*)
    @result ||= begin
      rows = account_ids.empty? || category_ids.empty? ? [] : ActiveRecord::Base.connection.select_all(query_sql).to_a
      rows.select! { |row| category_ids.include?(row["category_id"]) }
      by_month = rows.group_by { |row| row["month"].to_date }
      months = (0...month_count).map do |offset|
        month = from + offset.months
        month_rows = by_month.fetch(month, [])
        {
          month: month.iso8601,
          partial: month.end_of_month > @as_of,
          total: month_rows.sum { |row| row["total"].to_d }.to_d.to_s("F"),
          missing_exchange_rates: month_rows.sum { |row| row["missing_exchange_rates"].to_i },
          categories: month_rows.map { |row| { id: row["category_id"], amount: row["total"].to_d.to_s("F") } }
        }
      end
      {
        currency: @family.currency,
        basis: "gross_expense",
        as_of: @as_of.iso8601,
        period: { from: from.iso8601, to: to.iso8601, end_date: @date_range.end.iso8601 },
        filters: { account_ids: account_ids, category_ids: category_ids },
        accounts: accounts.map { |a| { id: a.id.to_s, name: a.name } },
        categories: categories,
        months: months,
        empty_selection: account_ids.empty? || category_ids.empty?,
        missing_exchange_rates: months.sum { |month| month[:missing_exchange_rates] }
      }
    end
  end

  private
    def month_count
      (to.year - from.year) * 12 + to.month - from.month + 1
    end

    def parse_month(value)
      unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-01\z/)
        raise InvalidSelection, "Months must use YYYY-MM-01"
      end
      date = Date.iso8601(value)
      raise InvalidSelection, "Month year must be positive" unless date.year.positive?
      date
    rescue Date::Error
      raise InvalidSelection, "Invalid month"
    end

    def select_ids(value, allowed)
      return allowed if value.nil?
      unless value.is_a?(Array) && value.all? { |id| id.is_a?(String) }
        raise InvalidSelection, "Filters must be arrays of IDs"
      end
      ids = value.reject(&:blank?).uniq
      raise InvalidSelection, "Unknown or unavailable filter ID" unless (ids - allowed).empty?
      ids
    end

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ <<~SQL, base_sql_params(included_account_ids: account_ids) ])
        SELECT date_trunc('month', ae.date)::date AS month,
          COALESCE(c.parent_id::text, c.id::text, '#{Category::UNCATEGORIZED_FILTER_VALUE}') AS category_id,
          SUM(#{converted_amount_sql("at")}) AS total,
          COUNT(*) FILTER (WHERE ae.currency <> :target_currency AND er.rate IS NULL) AS missing_exchange_rates
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        #{exchange_rates_join_sql}
        LEFT JOIN categories c ON c.id = at.category_id AND c.family_id = :family_id
        WHERE #{classification_sql("at")} = 'expense'
          AND at.kind NOT IN (#{budget_excluded_kinds_sql})
          #{investment_activity_label_sql("at")}
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY month, COALESCE(c.parent_id::text, c.id::text, '#{Category::UNCATEGORIZED_FILTER_VALUE}')
        ORDER BY month, category_id
      SQL
    end
end
