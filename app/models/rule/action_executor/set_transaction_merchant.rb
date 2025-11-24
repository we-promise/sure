class Rule::ActionExecutor::SetTransactionMerchant < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.merchants.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false)
    merchant = family.merchants.find_by_id(value)
    return 0 unless merchant

    scope = transaction_scope
    unless ignore_attribute_locks
      scope = scope.enrichable(:merchant_id)
    end

    count_modified_resources(scope) do |txn|
      txn.enrich_attribute(
        :merchant_id,
        merchant.id,
        source: "rule"
      )
    end
  end
end
