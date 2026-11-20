class Rule::ConditionFilter::TransactionCategory < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    Category::Group.select_options(family.categories, indent: false)
  end

  def prepare(scope)
    scope.left_joins(:category)
  end

  def apply(scope, operator, value)
    expression = build_sanitized_where_condition("categories.id", operator, value)
    scope.where(expression)
  end
end
