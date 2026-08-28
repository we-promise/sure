# The WHERE fragments that decide what counts as household spending.
#
# Extracted so the two readers of that definition cannot drift apart:
# FamilyStats, which answers "what does a typical month look like", and
# ExpenseWindow, which answers "what was actually spent between these dates".
# A reserve sized in months of expenses reads the second and is explained by
# the first, so a filter added to one and forgotten in the other would show up
# as a target nobody can reconcile with their own numbers.
module IncomeStatement::ExpensePredicates
  private
    def budget_excluded_kinds_sql
      @budget_excluded_kinds_sql ||= Transaction::BUDGET_EXCLUDED_KINDS.map { |k| "'#{k}'" }.join(", ")
    end

    def pending_providers_sql
      Transaction.pending_providers_sql("t")
    end

    def exclude_tax_advantaged_sql
      return "" if @family.tax_advantaged_account_ids.empty?

      "AND a.id NOT IN (:tax_advantaged_account_ids)"
    end

    def scope_to_account_ids_sql
      return "" if @account_ids.nil?

      ActiveRecord::Base.sanitize_sql([ "AND a.id IN (?)", @account_ids ])
    end

    def tax_advantaged_params
      ids = @family.tax_advantaged_account_ids
      ids.present? ? { tax_advantaged_account_ids: ids } : {}
    end
end
