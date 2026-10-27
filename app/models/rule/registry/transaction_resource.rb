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

  # Every action this resource knows, whether or not it is offered right now:
  # the AI actions are listed only while a provider is configured (or the rule
  # already has one), but stay valid when it is not.
  ACTION_EXECUTOR_CLASSES = [
    Rule::ActionExecutor::SetTransactionCategory,
    Rule::ActionExecutor::SetTransactionTags,
    Rule::ActionExecutor::SetTransactionMerchant,
    Rule::ActionExecutor::SetTransactionName,
    Rule::ActionExecutor::SetInvestmentActivityLabel,
    Rule::ActionExecutor::ExcludeTransaction,
    Rule::ActionExecutor::SetAsTransferOrPayment,
    Rule::ActionExecutor::SplitTransaction,
    Rule::ActionExecutor::SendEmailNotification,
    Rule::ActionExecutor::FillSimilarMerchants,
    Rule::ActionExecutor::BayesCategorize,
    Rule::ActionExecutor::AutoCategorize,
    Rule::ActionExecutor::AutoDetectMerchants
  ].freeze

  def self.condition_filter_keys
    CONDITION_FILTER_CLASSES.map(&:key)
  end

  def self.action_executor_keys
    ACTION_EXECUTOR_CLASSES.map(&:key)
  end

  def resource_scope
    family.transactions.visible.with_entry.merge(Entry.excluding_split_parents).where(entry: { date: rule.effective_date.. })
  end

  def condition_filters
    CONDITION_FILTER_CLASSES.map { |filter_class| filter_class.new(rule) }
  end

  def action_executors
    ACTION_EXECUTOR_CLASSES.filter_map do |executor_class|
      executor_class.new(rule) if offered?(executor_class)
    end
  end

  private
    def offered?(executor_class)
      case executor_class.key
      when "auto_categorize"
        auto_categorization_enabled? || existing_action?("auto_categorize")
      when "auto_detect_merchants"
        auto_merchant_detection_enabled? || existing_action?("auto_detect_merchants")
      else
        true
      end
    end

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
