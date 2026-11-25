# Filters a relation of budgets the caller may already read (see ScopedSearch).
class Budget::Search
  include ScopedSearch

  attribute :start_date, :date
  attribute :end_date, :date

  # Budgets that start on or after start_date and end on or before end_date.
  def budgets_scope
    relation = scope
    relation = relation.where(start_date: start_date..) unless start_date.nil?
    relation = relation.where(end_date: ..end_date) unless end_date.nil?
    relation
  end
end
