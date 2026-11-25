# Filters a relation of budget categories the caller may already read (see
# ScopedSearch). The date range applies to the budget each row belongs to.
class BudgetCategory::Search
  include ScopedSearch

  attribute :budget_id, :string
  attribute :category_id, :string
  attribute :start_date, :date
  attribute :end_date, :date

  def budget_categories_scope
    relation = scope
    relation = relation.where(budget_id:) unless budget_id.nil?
    relation = relation.where(category_id:) unless category_id.nil?
    relation = relation.joins(:budget).merge(budgets_in_range) unless start_date.nil? && end_date.nil?
    relation
  end

  private
    def budgets_in_range
      Budget::Search.new(Budget.all, filters: { start_date:, end_date: }).budgets_scope
    end
end
