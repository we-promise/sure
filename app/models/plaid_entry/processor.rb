class PlaidEntry::Processor
  # plaid_transaction is the raw hash fetched from Plaid API and converted to JSONB
  def initialize(plaid_transaction, plaid_account:, category_matcher:)
    @plaid_transaction = plaid_transaction
    @plaid_account = plaid_account
    @category_matcher = category_matcher
  end

  # Upserts one Plaid transaction into the account.
  #
  # @return [Entry] the created or updated entry
  def process
    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "plaid",
      category_id: matched_category&.id,
      merchant: merchant,
      pending_transaction_id: pending_transaction_id, # Plaid's linking ID for pending→posted
      extra: {
        plaid: {
          pending: plaid_transaction["pending"],
          pending_transaction_id: pending_transaction_id # Also store for reference
        }
      }
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

    # Combines Plaid's cleaned merchant name with the bank's original description,
    # mirroring SimplefinEntry::Processor#name.
    #
    # merchant_name alone collapses distinct transactions into one indistinguishable
    # name — every Target purchase becomes "Target", every Tesla charge "Tesla" —
    # and rules match on the transaction name (Rule::Condition's transaction_name,
    # compiled to ILIKE '%value%'), so nothing can tell the variants apart. Keeping
    # both means existing "Target" rules still match while narrower ones become
    # possible.
    #
    # @return [String, nil] the transaction name, or nil when Plaid sent neither
    def name
      merchant = merchant_name.presence
      original = original_description.presence

      if merchant.present? && original.present? && merchant != original
        "#{merchant} - #{original}"
      else
        merchant || original
      end
    end

    # @return [String, nil] Plaid's cleaned-up merchant name, when it resolved one
    def merchant_name
      plaid_transaction["merchant_name"]
    end

    # @return [String, nil] the raw description as the bank wrote it
    def original_description
      plaid_transaction["original_description"]
    end

    # @return [Numeric] the transaction amount, in Plaid's sign convention
    def amount
      plaid_transaction["amount"]
    end

    def currency
      plaid_transaction["iso_currency_code"]
    end

    def date
      plaid_transaction["date"]
    end

    # Plaid provides this linking ID when a posted transaction matches a pending one
    # This is the most reliable way to reconcile pending→posted
    def pending_transaction_id
      plaid_transaction["pending_transaction_id"]
    end

    def detailed_category
      plaid_transaction.dig("personal_finance_category", "detailed")
    end

    def matched_category
      return nil unless detailed_category
      return nil unless account&.enable_category_matcher?
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
