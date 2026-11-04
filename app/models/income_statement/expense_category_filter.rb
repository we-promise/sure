# A category filter over an IncomeStatement's daily expense series (the
# dashboard's spending widget): which categories it offers, which of them are
# checked, and what the selection resolves to.
#
# Options are listed by category group (a top-level category and its
# subcategories): every group with spending in the given periods, plus any
# group with a picked category. A group is listed whole, so a
# parent/subcategory cascade sees every child; picking a parent covers them
# all. Ordered like the transactions category filter, with Uncategorized
# first. An option is checked when it was picked, or its parent was, or
# nothing was picked at all; it's live when its group has spending.
#
# The selection resolves to nil (unfiltered) when every option is checked
# and live: that draws exactly what the unfiltered series does. A picked
# category with no spending keeps the filter, so it survives a period where
# it's empty.
class IncomeStatement::ExpenseCategoryFilter
  Option = Data.define(:category, :value, :checked, :live)

  attr_reader :options, :category_ids

  # `category_ids` holds category ids and/or
  # Category::UNCATEGORIZED_FILTER_VALUE, already limited to the family's
  # own; nil means nothing was picked.
  def initialize(income_statement, periods:, category_ids:)
    @income_statement = income_statement
    @options = build_options(periods, category_ids)
    @category_ids = category_ids unless @options.all? { |option| option.checked && option.live }
  end

  # How many categories the selection covers, counted where spending is
  # filed: a category with subcategories counts as its subcategories, not
  # itself as well. So a picked parent with all 8 subcategories counts 8,
  # and unchecking one of them lowers the count by one.
  def selected_count
    parent_ids = options.filter_map { |option| option.category.parent_id }
    options.count { |option| option.checked && !parent_ids.include?(option.category.id) }
  end

  private
    def build_options(periods, category_ids)
      used_ids = periods.flat_map { |period| @income_statement.daily_expense_category_ids(period: period) }.uniq
      selected_ids = Array(category_ids)

      categories = @income_statement.family.categories.alphabetically_by_hierarchy.to_a
      group_of = ->(category) { category.parent_id || category.id }
      live_groups = categories.select { |c| used_ids.include?(c.id) }.map(&group_of)
      shown_groups = live_groups + categories.select { |c| selected_ids.include?(c.id) }.map(&group_of)
      categories.select! { |c| shown_groups.include?(group_of.call(c)) }
      categories.unshift(Category.uncategorized) if used_ids.include?(nil) || selected_ids.include?(Category::UNCATEGORIZED_FILTER_VALUE)

      categories.map do |category|
        value = category.persisted? ? category.id : category.filter_value
        Option.new(
          category: category,
          value: value,
          checked: category_ids.nil? || category_ids.include?(value) || category_ids.include?(category.parent_id),
          live: category.persisted? ? live_groups.include?(group_of.call(category)) : used_ids.include?(nil)
        )
      end
    end
end
