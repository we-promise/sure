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
      merchant: merchant,
      pending_transaction_id: pending_transaction_id, # Plaid's linking ID for pending→posted
      extra: plaid_extra
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

    # Default is Plaid's cleaned merchant name. When the connection opts into
    # bank fidelity, the raw original description wins instead.
    def name
      merchant = merchant_name.presence
      original = original_description.presence

      if prefer_original_description?
        original || merchant
      else
        merchant || original
      end
    end

    # Memoized: this is read once per transaction in a sync batch.
    def prefer_original_description?
      return @prefer_original_description if defined?(@prefer_original_description)

      @prefer_original_description = plaid_account.plaid_item.family.plaid_prefer_original_description?
    end

    def merchant_name
      plaid_transaction["merchant_name"]
    end

    def original_description
      plaid_transaction["original_description"]
    end

    def plaid_extra
      plaid = {
        "pending" => plaid_transaction["pending"],
        "pending_transaction_id" => pending_transaction_id
      }

      plaid["original_description"] = original_description if original_description.present?
      plaid["payment_channel"] = plaid_transaction["payment_channel"] if plaid_transaction["payment_channel"].present?
      plaid["transaction_code"] = plaid_transaction["transaction_code"] if plaid_transaction["transaction_code"].present?

      payment_meta = compact_provider_hash(plaid_transaction["payment_meta"])
      plaid["payment_meta"] = payment_meta if payment_meta.present?

      counterparties = compact_counterparties(plaid_transaction["counterparties"])
      plaid["counterparties"] = counterparties if counterparties.present?

      { "plaid" => plaid }
    end

    def compact_provider_hash(value)
      return nil unless value.is_a?(Hash)

      compacted = {}
      value.each do |key, raw|
        next if raw.nil? || raw == ""

        if raw.is_a?(Hash)
          nested = compact_provider_hash(raw)
          compacted[key.to_s] = nested if nested.present?
        else
          compacted[key.to_s] = raw
        end
      end
      compacted.presence
    end

    def compact_counterparties(value)
      return nil unless value.is_a?(Array)

      value.filter_map do |counterparty|
        next unless counterparty.is_a?(Hash)

        compact_provider_hash(counterparty)
      end.presence
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
