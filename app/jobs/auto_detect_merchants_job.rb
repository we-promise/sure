class AutoDetectMerchantsJob < RuleAiJob
  private
    def enrich(family, transaction_ids)
      family.auto_detect_transaction_merchants(transaction_ids)
    end
end
