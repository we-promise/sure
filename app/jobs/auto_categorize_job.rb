class AutoCategorizeJob < RuleAiJob
  private
    def enrich(family, transaction_ids)
      return 0 unless Ai.available?(:categorize, family:)

      family.auto_categorize_transactions(transaction_ids)
    end
end
