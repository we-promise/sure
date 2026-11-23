class AutoCategorizeJob < RuleAiJob
  private
    def enrich(family, transaction_ids)
      family.auto_categorize_transactions(transaction_ids)
    end
end
