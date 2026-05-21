class Rule::ConditionFilter::Unsupported < Rule::ConditionFilter
  def initialize(rule, condition_type)
    super(rule)
    @condition_type = condition_type.to_s
  end

  def key
    @condition_type
  end

  def label
    I18n.t("rule.conditions.unsupported_label", type: @condition_type)
  end

  def apply(scope, _operator, _value)
    scope.none
  end
end
