# Imports a single Plaid transaction into a Sure Account via import_adapter.
# Direct port of PlaidEntry::Processor; takes provider_account instead of
# plaid_account, otherwise identical.
class Provider::Plaid::Transactions::EntryProcessor
  def initialize(plaid_transaction, provider_account:, category_matcher:)
    @plaid_transaction = plaid_transaction
    @provider_account = provider_account
    @category_matcher = category_matcher
  end

  def process
    import_adapter.import_transaction(
      external_id:            external_id,
      amount:                 amount,
      currency:               currency,
      date:                   date,
      name:                   name,
      source:                 "plaid",
      category_id:            matched_category&.id,
      merchant:               merchant,
      pending_transaction_id: pending_transaction_id,
      extra: {
        plaid: {
          pending:                plaid_transaction["pending"],
          pending_transaction_id: pending_transaction_id
        }
      }
    )
  end

  private
    attr_reader :plaid_transaction, :provider_account, :category_matcher

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(provider_account.account)
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

    def pending_transaction_id
      plaid_transaction["pending_transaction_id"]
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
        name:                 plaid_transaction["merchant_name"],
        source:               "plaid",
        website_url:          plaid_transaction["website"],
        logo_url:             safe_https(plaid_transaction["logo_url"])
      )
    end

    # Restrict ingested logo URLs to HTTPS — same guard Provider::Account#safe_logo_uri
    # applies to institution logos. Defends against malformed/malicious upstream
    # payloads writing http: or javascript: schemes into merchants.logo_url.
    def safe_https(url)
      return nil if url.blank?
      URI.parse(url).is_a?(URI::HTTPS) ? url : nil
    rescue URI::InvalidURIError
      nil
    end
end
