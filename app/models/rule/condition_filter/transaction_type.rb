class Rule::ConditionFilter::TransactionType < Rule::ConditionFilter
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
    # Logic matches Transaction::Search#apply_type_filter for consistency.
    # `kind` alone misses a pending auto-match: its legs still carry
    # kind == "standard" until confirmed, so also excluding/including rows
    # that are a leg of a still-pending transfer keeps unconfirmed matches
    # out of income/expense rule matching the same way they're excluded once
    # confirmed. (NOT `transfer_id` -- that column exists on `transactions`
    # but nothing in the app ever writes it; `Transaction#transfer` reads
    # `transfer_as_inflow`/`transfer_as_outflow` instead, see
    # Transaction::Transferable.)
    case value
    when "income"
      scope.where("entries.amount < 0")
           .where.not(kind: Transaction::TRANSFER_KINDS)
           .excluding_pending_transfer_legs
    when "expense"
      scope.where("entries.amount >= 0")
           .where.not(kind: Transaction::TRANSFER_KINDS)
           .excluding_pending_transfer_legs
    when "transfer"
      scope.where(kind: Transaction::TRANSFER_KINDS).or(scope.pending_transfer_legs)
    else
      scope
    end
  end
end
