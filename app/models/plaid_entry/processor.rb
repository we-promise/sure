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
      extra: {
        plaid: {
          pending: plaid_transaction["pending"],
          pending_transaction_id: pending_transaction_id, # Also store for reference
          **Provider::BankEntryDate.provenance([
            [ :date, plaid_transaction["date"] ],
            [ :authorized_date, plaid_transaction["authorized_date"] ],
            [ :datetime, plaid_transaction["datetime"] ],
            [ :authorized_datetime, plaid_transaction["authorized_datetime"] ]
          ])
        }.compact
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

    def name
      plaid_transaction["merchant_name"] || plaid_transaction["original_description"]
    end

    def amount
      plaid_transaction["amount"]
    end

    def currency
      plaid_transaction["iso_currency_code"]
    end

    # Prefer Plaid's posted `date`, then authorized/datetime fields when needed to
    # avoid a future display date (#2907).
    def date
      selected = Provider::BankEntryDate.select([
        [ "date", parse_provider_date(plaid_transaction["date"]) ],
        [ "authorized_date", parse_provider_date(plaid_transaction["authorized_date"]) ],
        [ "datetime", parse_provider_date(plaid_transaction["datetime"]) ],
        [ "authorized_datetime", parse_provider_date(plaid_transaction["authorized_datetime"]) ]
      ],
        as_of: Provider::BankEntryDate.family_today(account&.family),
        existing_date: Provider::BankEntryDate.existing_entry_date(
          account: account,
          external_id: external_id,
          source: "plaid"
        ))

      return selected if selected

      raise ArgumentError, "Invalid date format: #{plaid_transaction["date"].inspect}"
    end

    def parse_provider_date(date_value)
      return nil if date_value.blank?

      case date_value
      when String
        if date_value.include?("T") || date_value.include?(":")
          Time.parse(date_value).in_time_zone(account&.family&.timezone).to_date
        else
          Date.parse(date_value)
        end
      when Time, DateTime, ActiveSupport::TimeWithZone
        date_value.in_time_zone(account&.family&.timezone).to_date
      when Date
        date_value
      else
        nil
      end
    rescue ArgumentError, TypeError
      nil
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
