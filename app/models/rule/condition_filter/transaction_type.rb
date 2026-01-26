class Rule::ConditionFilter::TransactionType < Rule::ConditionFilter
  # Transfer kinds matching Transaction#transfer? method
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment].freeze

  def type
    "select"
  end

  def options
    [
      [ "Income", "income" ],
      [ "Expense", "expense" ],
      [ "Transfer", "transfer" ]
    ]
  end

  def operators
    [ [ "Equal to", "=" ] ]
  end

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    case value
    when "income"
      scope.where("entries.amount < 0")
    when "expense"
      scope.where("entries.amount > 0").where.not(kind: TRANSFER_KINDS)
    when "transfer"
      scope.where(kind: TRANSFER_KINDS)
    else
      scope
    end
  end
end
