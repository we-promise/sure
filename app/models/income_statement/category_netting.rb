# Nets refunds within each category before arranging flows. Parent totals already
# include children: subtract those children before partitioning by direction, so
# a refund in a child cannot be counted again in its parent's net amount.
#
# Shared by the dashboard, category and account Sankeys, so all of them net a
# statement the same way and branch a category node the same way.
class IncomeStatement::CategoryNetting
  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  # One group per top-level category: its own net (`direct`) and its
  # subcategories' nets (`children`), positive meaning spending.
  #
  # Unlike IncomeStatement#net_category_totals, which nets a parent together
  # with its subcategories, this keeps each subcategory's direction, so a
  # refunded subcategory can be drawn on the other side of a Sankey.
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

    # A flow a category node passes on, ready to draw: a subcategory, or
    # (own: true) the parent's own share beside its subcategories, which
    # shares the parent's category and so its filter.
    def branch(side, category, amount, own: false)
      { category: category, amount: amount, own: own,
        id: "#{side}_sub_#{category.id}#{"_own" if own}",
        name: own ? I18n.t("models.category.own_share", category: category.name) : category.name }
    end

    # The subcategories of a group with an amount on one side, as branches.
    def side_children(group, side)
      group[:children].filter_map do |child|
        amount = side_amount(child[:net], side)
        branch(side, child[:category], amount) unless amount.zero?
      end
    end

    # What a category node on one side flows on to: its subcategories and, when
    # it has any, its own share beside them, so the node passes on everything
    # it takes in. A category without subcategories on that side is a leaf.
    def branches(side, category, own:, children:)
      return children if children.empty? || own.zero?
      children + [ branch(side, category, own, own: true) ]
    end

    def side_branches(group, side)
      branches(side, group[:category], own: side_amount(group[:direct], side), children: side_children(group, side))
    end
  end
end
