class Rule::Registry::TransactionResource < Rule::Registry
  CONDITION_FILTER_CLASSES = [
    Rule::ConditionFilter::TransactionName,
    Rule::ConditionFilter::TransactionAmount,
    Rule::ConditionFilter::TransactionType,
    Rule::ConditionFilter::TransactionMerchant,
    Rule::ConditionFilter::TransactionCategory,
    Rule::ConditionFilter::TransactionTag,
    Rule::ConditionFilter::TransactionDetails,
    Rule::ConditionFilter::TransactionNotes,
    Rule::ConditionFilter::TransactionAccount
  ].freeze

  def self.condition_filter_keys
    CONDITION_FILTER_CLASSES.map(&:key)
  end

  def resource_scope
    family.transactions.visible.with_entry.merge(Entry.excluding_split_parents).where(entry: { date: rule.effective_date.. })
  end

  def condition_filters
    CONDITION_FILTER_CLASSES.map { |filter_class| filter_class.new(rule) }
  end

  def action_executors
    enabled_executors = [
      Rule::ActionExecutor::SetTransactionCategory.new(rule),
      Rule::ActionExecutor::SetTransactionTags.new(rule),
      Rule::ActionExecutor::SetTransactionMerchant.new(rule),
      Rule::ActionExecutor::SetTransactionName.new(rule),
      Rule::ActionExecutor::SetInvestmentActivityLabel.new(rule),
      Rule::ActionExecutor::ExcludeTransaction.new(rule),
      Rule::ActionExecutor::SetAsTransferOrPayment.new(rule),
      Rule::ActionExecutor::SplitTransaction.new(rule),
      Rule::ActionExecutor::SendEmailNotification.new(rule)
    ]

    if auto_categorization_enabled? || existing_action?("auto_categorize")
      enabled_executors << Rule::ActionExecutor::AutoCategorize.new(rule)
    end

    if auto_merchant_detection_enabled? || existing_action?("auto_detect_merchants")
      enabled_executors << Rule::ActionExecutor::AutoDetectMerchants.new(rule)
    end

    enabled_executors
  end

  private
    def auto_categorization_enabled?
      family.resolved_categorization_provider.present?
    end

    def auto_merchant_detection_enabled?
      Provider::Registry.preferred_llm_provider.present?
    end

    def existing_action?(action_type)
      rule.actions.any? { |action| action.action_type == action_type }
    end
end
