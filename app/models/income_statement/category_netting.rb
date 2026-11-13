# Nets refunds within each category before arranging flows. Parent totals already
# include children: subtract those children before partitioning by direction, so
# a refund in a child cannot be counted again in its parent's net amount.
#
# Shared by the category and account Sankeys, so both net a statement the same way.
class IncomeStatement::CategoryNetting
  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  # One group per top-level category: its own net (`direct`) and its
  # subcategories' nets (`children`), positive meaning spending.
  #
  # Keep this hierarchy-aware netting separate from IncomeStatement#net_category_totals
  # while the original dashboard Sankey remains available for preview comparisons.
  def groups
    expense = @statement.expense_totals(period: @period).category_totals.index_by { |ct| self.class.key(ct.category) }
    income = @statement.income_totals(period: @period).category_totals.index_by { |ct| self.class.key(ct.category) }
    entries = (expense.keys | income.keys).sort.map do |key|
      category = (expense[key] || income[key]).category
      { category: category, net: (expense[key]&.total || 0).to_d - (income[key]&.total || 0).to_d }
    end
    children = entries.select { |entry| entry[:category].subcategory? }.group_by { |entry| entry[:category].parent_id }
    entries.reject { |entry| entry[:category].subcategory? }.map do |root|
      subs = children.fetch(root[:category].id, [])
      { category: root[:category], direct: root[:net] - subs.sum { |sub| sub[:net] }, children: subs }
    end
  end

  class << self
    def key(category)
      return "uncategorized" if category.uncategorized?
      return "other_investments" if category.other_investments?
      category.id
    end

    def side_amount(net, side)
      [ side == :expense ? net : -net, 0 ].max
    end

    def side_total(group, side)
      side_amount(group[:direct], side) + group[:children].sum { |child| side_amount(child[:net], side) }
    end
  end
end
