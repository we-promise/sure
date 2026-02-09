class Rule::Registry::TransactionResource < Rule::Registry
  def resource_scope
    family.transactions.visible.with_entry.where(entry: { date: rule.effective_date.. })
  end

  def condition_filters
    [
      Rule::ConditionFilter::TransactionName.new(rule),
      Rule::ConditionFilter::TransactionAmount.new(rule),
      Rule::ConditionFilter::TransactionType.new(rule),
      Rule::ConditionFilter::TransactionMerchant.new(rule),
      Rule::ConditionFilter::TransactionCategory.new(rule),
      Rule::ConditionFilter::TransactionDetails.new(rule),
      Rule::ConditionFilter::TransactionNotes.new(rule)
    ]
  end

  def action_executors
    enabled_executors = [
      Rule::ActionExecutor::SetTransactionCategory.new(rule),
      Rule::ActionExecutor::SetTransactionTags.new(rule),
      Rule::ActionExecutor::SetTransactionMerchant.new(rule),
      Rule::ActionExecutor::SetTransactionName.new(rule),
      Rule::ActionExecutor::SetInvestmentActivityLabel.new(rule),
      Rule::ActionExecutor::ExcludeTransaction.new(rule),
      Rule::ActionExecutor::SetAsTransferOrPayment.new(rule)
    ]

    if ai_enabled?
      enabled_executors << Rule::ActionExecutor::AutoCategorize.new(rule)
      enabled_executors << Rule::ActionExecutor::AutoDetectMerchants.new(rule)
    end

    enabled_executors
  end

  private
    def ai_enabled?
      Provider::Registry.get_provider(:openai).present?
    end
end
