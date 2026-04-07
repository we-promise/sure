class Rule::ConditionFilter::TransactionAccount < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    family.accounts.accessible_by(Current.user).alphabetically.pluck(:name, :id)
  end

  def apply(scope, operator, value)
    expression = build_sanitized_where_condition("entries.account_id", operator, value)
    scope.where(expression)
  end
end
