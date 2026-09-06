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
    #
    # @return [Boolean] whether this family opted into bank-fidelity naming
    def prefer_original_description?
      return @prefer_original_description if defined?(@prefer_original_description)

      @prefer_original_description = plaid_account.plaid_item.family.plaid_prefer_original_description?
    end

    # @return [String, nil] Plaid's cleaned-up merchant name, when it resolved one
    def merchant_name
      plaid_transaction["merchant_name"]
    end

    # @return [String, nil] the raw description as the bank wrote it
    def original_description
      plaid_transaction["original_description"]
    end

    # Every key is emitted on every sync, including when the value is absent.
    # Account::ProviderImportAdapter#import_transaction deep-merges this into
    # the existing Transaction#extra, so an omitted key would leave the previous
    # value in place forever once Plaid stops sending it — the drawer would go
    # on showing metadata the provider has since cleared. Writing an explicit
    # nil is what clears it.
    #
    # @return [Hash] the "plaid" namespace to merge into Transaction#extra
    def plaid_extra
      plaid = {
        "pending" => plaid_transaction["pending"],
        "pending_transaction_id" => pending_transaction_id,
        "original_description" => original_description.presence,
        "payment_channel" => plaid_transaction["payment_channel"].presence,
        "transaction_code" => plaid_transaction["transaction_code"].presence,
        "payment_meta" => compact_provider_hash(plaid_transaction["payment_meta"]),
        "counterparties" => compact_counterparties(plaid_transaction["counterparties"])
      }

      { "plaid" => plaid }
    end

    # Drops blank entries recursively so stored metadata carries only values the
    # drawer can actually show, rather than a wall of nulls.
    #
    # @param value [Object] a nested provider hash, or anything else
    # @return [Hash, nil] the compacted hash, or nil when nothing survived
    def compact_provider_hash(value)
      return nil unless value.is_a?(Hash)

      compacted = {}
      value.each do |key, raw|
        next if blank_provider_value?(raw)

        if raw.is_a?(Hash)
          nested = compact_provider_hash(raw)
          compacted[key.to_s] = nested if nested.present?
        else
          compacted[key.to_s] = raw
        end
      end
      compacted.presence
    end

    # Only strings get the whitespace treatment. `blank?` would also discard
    # `false`, which is a meaningful value for a provider flag.
    #
    # @param raw [Object] a single provider value
    # @return [Boolean] whether the value is worth storing
    def blank_provider_value?(raw)
      return true if raw.nil?
      return raw.strip.empty? if raw.is_a?(String)

      false
    end

    # @param value [Object] Plaid's counterparties array, or anything else
    # @return [Array<Hash>, nil] compacted counterparties, or nil when none remain
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
