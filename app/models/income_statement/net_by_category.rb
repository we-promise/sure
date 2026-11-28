# Net spending per category for one period: expense minus income booked to the
# category. A refund lowers its category instead of counting as more spending.
#
# Shared by SpendingComparison and the Reports category trend, so both net a
# statement the same way.
class IncomeStatement::NetByCategory
  def initialize(statement, period:, tag_ids: nil)
    @statement = statement
    @period = period
    @tag_ids = tag_ids
  end

  # { key => { category:, net: } } for every category with activity.
  def call
    result = {}
    period_totals = [
      [ statement.expense_totals(period: period, tag_ids: tag_ids), 1 ],
      [ statement.income_totals(period: period, tag_ids: tag_ids), -1 ]
    ]

    period_totals.each do |totals, sign|
      totals.category_totals.each do |category_total|
        next if category_total.total.zero?

        entry = result[self.class.key(category_total.category)] ||= { category: category_total.category, net: 0 }
        entry[:net] += sign * category_total.total
      end
    end

    result
  end

  # A stable key for synthetic categories, or the persisted id.
  def self.key(category)
    return :uncategorized if category.uncategorized?
    return :other_investments if category.other_investments?

    category.id
  end

  private
    attr_reader :statement, :period, :tag_ids
end
