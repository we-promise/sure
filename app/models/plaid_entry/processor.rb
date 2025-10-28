class PlaidEntry::Processor
  # plaid_transaction is the raw hash fetched from Plaid API and converted to JSONB
  def initialize(plaid_transaction, plaid_account:, category_matcher:)
    @plaid_transaction = plaid_transaction
    @plaid_account = plaid_account
    @category_matcher = category_matcher
  end

  def process
    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "plaid",
      category_id: matched_category&.id,
      merchant: merchant
    )
  end

  private
    attr_reader :plaid_transaction, :plaid_account, :category_matcher

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.current_account
    end

    def external_id
      plaid_transaction["transaction_id"]
    end

    def name
      plaid_transaction["merchant_name"] || plaid_transaction["original_description"]
    end

    def amount
      plaid_transaction["amount"]
    end

    def currency
      plaid_transaction["iso_currency_code"]
    end

    def date
      plaid_transaction["date"]
    end

    def detailed_category
      plaid_transaction.dig("personal_finance_category", "detailed")
    end

    def matched_category
      return nil unless detailed_category
      @matched_category ||= category_matcher.match(detailed_category)
    end

    def merchant
      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: plaid_transaction["merchant_entity_id"],
        name: plaid_transaction["merchant_name"],
        source: "plaid",
        website_url: plaid_transaction["website"],
        logo_url: plaid_transaction["logo_url"]
      )
    end
end
