class AutoDetectMerchantsJob < RuleAiJob
  private
    def enrich(family, transaction_ids)
      return 0 unless Ai.available?(:detect_merchants, family:)

      family.auto_detect_transaction_merchants(transaction_ids)
    end
end
