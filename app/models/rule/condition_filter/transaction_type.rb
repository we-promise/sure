class Rule::ConditionFilter::TransactionType < Rule::ConditionFilter
  # Transfer kinds matching Transaction#transfer? method
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment].freeze

  def type
    "select"
  end

  def options
    [
      [ I18n.t("rules.condition_filters.transaction_type.income"), "income" ],
      [ I18n.t("rules.condition_filters.transaction_type.expense"), "expense" ],
      [ I18n.t("rules.condition_filters.transaction_type.transfer"), "transfer" ]
    ]
  end

  def operators
    [ [ I18n.t("rules.condition_filters.transaction_type.equal_to"), "=" ] ]
  end

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    # Logic matches Transaction::Search#apply_type_filter for consistency
    case value
    when "income"
      # Negative amounts, excluding transfers and investment_contribution
      scope.where("entries.amount < 0")
           .where.not(kind: TRANSFER_KINDS + %w[investment_contribution])
    when "expense"
      # Positive amounts OR investment_contribution (regardless of sign), excluding transfers
      scope.where("entries.amount >= 0 OR transactions.kind = 'investment_contribution'")
           .where.not(kind: TRANSFER_KINDS)
    when "transfer"
      scope.where(kind: TRANSFER_KINDS)
    else
      scope
    end
  end
end
