# Spending per merchant for a period, read from the same rows as the
# headline expense total (IncomeStatement::Totals), so a merchant's
# purchases summed with every other merchant's equal that total.
#
# Rows group by merchant name, not id: a family merchant and a provider
# merchant with the same name are one shop to the user, and the
# transactions list filters merchants by name, so a row's figures match
# the list it links to. A nil name is spending with no merchant.
class IncomeStatement::MerchantTotals
  include IncomeStatement::ScopedTransactionsQuery

  Row = Data.define(:name, :purchases, :purchases_count, :refunds) do
    # Income at a merchant is a refund of spending there. Income with no
    # merchant is mostly pay, so the no-merchant row reports purchases only.
    def net
      name.nil? ? purchases : purchases - refunds
    end

    def average
      purchases_count.zero? ? 0 : purchases / purchases_count
    end
  end

  def initialize(family, transactions_scope:, date_range:, included_account_ids: nil)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @included_account_ids = included_account_ids

    validate_date_range!
  end

  def call
    return [] if @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      Row.new(
        name: row["merchant_name"],
        purchases: row["purchases"].to_d,
        purchases_count: row["purchases_count"].to_i,
        refunds: row["refunds"].to_d
      )
    end
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ <<~SQL, sql_params ])
        SELECT
          merchant_name,
          COALESCE(SUM(amount) FILTER (WHERE classification = 'expense'), 0) AS purchases,
          COUNT(DISTINCT purchase_id) FILTER (WHERE classification = 'expense' AND amount IS NOT NULL) AS purchases_count,
          COALESCE(-SUM(amount) FILTER (WHERE classification = 'income'), 0) AS refunds
        FROM (
          SELECT
            m.name AS merchant_name,
            #{classification_sql("at")} AS classification,
            #{converted_amount_sql("at")} AS amount,
            COALESCE(ae.parent_entry_id, ae.id) AS purchase_id
          FROM (#{@transactions_scope.to_sql}) at
          #{entries_join_sql("at")}
          #{accounts_join_sql}
          LEFT JOIN merchants m ON m.id = at.merchant_id
          WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
            #{investment_activity_label_sql("at")}
            AND ae.excluded = false
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND a.exclude_from_reports = false
            #{exclude_tax_advantaged_sql}
            #{include_finance_accounts_sql}
        ) merchant_rows
        GROUP BY merchant_name
      SQL
    end

    def sql_params
      params = base_sql_params
      params[:included_account_ids] = @included_account_ids if @included_account_ids
      params
    end
end
