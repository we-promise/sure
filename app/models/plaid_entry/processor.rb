class PlaidEntry::Processor
  # Joins the merchant name to the bank's description in #name. Rule matching has
  # to recognise the same seam to keep exact-match name rules working, so
  # Rule::ConditionFilter::TransactionName reads these constants rather than
  # spelling the separator and the source out a second time.
  NAME_SEPARATOR = " - "
  SOURCE = "plaid"

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
      source: SOURCE,
      category_id: matched_category&.id,
      merchant: merchant,
      pending_transaction_id: pending_transaction_id, # Plaid's linking ID for pending→posted
      extra: plaid_extra,
      # plaid_extra is a full snapshot of what Plaid currently reports, so the
      # branch is replaced rather than merged — otherwise a nested value Plaid
      # stopped sending (say payment_meta.payee) would linger indefinitely.
      replace_extra_namespaces: [ "plaid" ],
      # #name is built from original_description, and the rule filter rebuilds
      # it from the stored copy, so the two have to move together.
      name_extra_keys: { "plaid" => [ "original_description" ] }
    )
  end

  private
    attr_reader :plaid_transaction, :plaid_account, :category_matcher

    # @return [Account::ProviderImportAdapter] the upsert path shared by every provider
    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # @return [Account] the account this Plaid account currently maps to
    def account
      plaid_account.current_account
    end

    # @return [String] Plaid's transaction id, unique per account and source
    def external_id
      plaid_transaction["transaction_id"]
    end

    # Combines Plaid's cleaned merchant name with the bank's original description,
    # mirroring SimplefinEntry::Processor#name.
    #
    # merchant_name alone collapses distinct transactions into one indistinguishable
    # name — every Target purchase becomes "Target", every Tesla charge "Tesla" —
    # and rules match on the transaction name, so nothing can tell the variants
    # apart. Keeping both makes narrower rules possible.
    #
    # Rules the user already wrote are held harmless by
    # Rule::ConditionFilter::TransactionName, which recognises NAME_SEPARATOR and
    # keeps matching a Plaid row on the merchant half alone.
    #
    # @return [String, nil] the transaction name, or nil when Plaid sent neither
    def name
      merchant = merchant_name.presence
      original = original_description.presence

      if merchant.present? && original.present? && merchant != original
        "#{merchant}#{NAME_SEPARATOR}#{original}"
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

    # The whole branch is replaced on every import (see replace_extra_namespaces
    # in #process), so a field Plaid stops sending is cleared by omission. Absent
    # values are left out rather than stored as nil: they add nothing, and a nil
    # key is one more name for a details rule to trip over.
    #
    # @return [Hash] the Plaid snapshot, under its own namespace
    def plaid_extra
      plaid = {
        "pending" => plaid_transaction["pending"],
        "pending_transaction_id" => pending_transaction_id,
        "original_description" => original_description.presence,
        "payment_channel" => plaid_transaction["payment_channel"].presence,
        "transaction_code" => plaid_transaction["transaction_code"].presence,
        "payment_meta" => compact_provider_hash(plaid_transaction["payment_meta"]),
        "counterparties" => compact_counterparties(plaid_transaction["counterparties"])
      }.compact

      { "plaid" => plaid }
    end

    # Drops keys whose value carries nothing, recursing into nested hashes, so
    # the stored snapshot holds only fields Plaid actually reported.
    #
    # @param value [Object] a provider hash, or anything else
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
    def blank_provider_value?(raw)
      return true if raw.nil?
      return raw.strip.empty? if raw.is_a?(String)

      false
    end

    # @param value [Object] Plaid's counterparties array, or anything else
    # @return [Array<Hash>, nil] compacted counterparties, or nil when none survived
    def compact_counterparties(value)
      return nil unless value.is_a?(Array)

      value.filter_map do |counterparty|
        next unless counterparty.is_a?(Hash)

        compact_provider_hash(counterparty)
      end.presence
    end

    # @return [Numeric] the transaction amount, in Plaid's sign convention
    def amount
      plaid_transaction["amount"]
    end

    # @return [String, nil] ISO currency code for the amount
    def currency
      plaid_transaction["iso_currency_code"]
    end

    # @return [String, Date] the date Plaid reported for the transaction
    def date
      plaid_transaction["date"]
    end

    # Plaid provides this linking ID when a posted transaction matches a pending one
    # This is the most reliable way to reconcile pending→posted
    def pending_transaction_id
      plaid_transaction["pending_transaction_id"]
    end

    # @return [String, nil] Plaid's detailed personal finance category, when present
    def detailed_category
      plaid_transaction.dig("personal_finance_category", "detailed")
    end

    # @return [Category, nil] the family category matching Plaid's, when the
    #   account has category matching enabled
    def matched_category
      return nil unless detailed_category
      return nil unless account&.enable_category_matcher?
      @matched_category ||= category_matcher.match(detailed_category)
    end

    # Built from the cleaned merchant name on its own path, so merchant grouping
    # and logos stay put even though #name now carries the description too.
    #
    # @return [ProviderMerchant, nil] the merchant for this transaction
    def merchant
      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: plaid_transaction["merchant_entity_id"],
        name: plaid_transaction["merchant_name"],
        source: SOURCE,
        website_url: plaid_transaction["website"],
        logo_url: plaid_transaction["logo_url"]
      )
    end
end
