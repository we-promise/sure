# Imports wallet/account data from Coinbase API.
# Fetches accounts, balances, and transaction history.
class CoinbaseItem::Importer
  # Coinbase's /v2/accounts/{id}/transactions endpoint returns newest-first,
  # so a low limit silently drops older history for any wallet with more
  # lifetime transactions than that (e.g. one funded by frequent staking
  # rewards) - it's never even fetched, let alone processed by
  # CoinbaseAccount::Processor. 5000 comfortably covers even a multi-year
  # daily-staking-reward history without risking an unbounded loop against
  # Coinbase's API; Provider::Coinbase#get_transactions already paginates up
  # to whatever limit it's given, following Coinbase's next_uri cursor.
  FULL_HISTORY_LIMIT = 5000

  attr_reader :coinbase_item, :coinbase_provider

  # @param coinbase_item [CoinbaseItem] Item containing accounts to import
  # @param coinbase_provider [Provider::Coinbase] API client instance
  def initialize(coinbase_item, coinbase_provider:)
    @coinbase_item = coinbase_item
    @coinbase_provider = coinbase_provider
  end

  # Imports accounts and transaction data from Coinbase.
  # Creates or updates coinbase_accounts for each Coinbase wallet.
  # @return [Hash] Result with :success, :accounts_imported
  def import
    Rails.logger.info "CoinbaseItem::Importer - Starting import for item #{coinbase_item.id}"

    # Fetch all accounts (wallets) from Coinbase
    accounts_data = coinbase_provider.get_accounts

    if accounts_data.blank?
      Rails.logger.info "CoinbaseItem::Importer - No accounts found for item #{coinbase_item.id}"
      return { success: true, accounts_imported: 0 }
    end

    # Store raw payload for debugging
    coinbase_item.upsert_coinbase_snapshot!(accounts_data)

    accounts_imported = 0
    accounts_failed = 0

    accounts_data.each do |account_data|
      import_account(account_data)
      accounts_imported += 1
    rescue => e
      accounts_failed += 1
      Rails.logger.error "CoinbaseItem::Importer - Failed to import account: #{e.message}"
    end

    Rails.logger.info "CoinbaseItem::Importer - Imported #{accounts_imported} accounts (#{accounts_failed} failed)"

    {
      success: accounts_failed == 0,
      accounts_imported: accounts_imported,
      accounts_failed: accounts_failed
    }
  end

  private

    def import_account(account_data)
      balance = account_data.dig("balance", "amount").to_d

      # Find or create the coinbase_account record
      coinbase_account = coinbase_item.coinbase_accounts.find_or_initialize_by(
        account_id: account_data["id"]
      )

      # Determine the currency (crypto symbol)
      currency_code = account_data.dig("balance", "currency") || account_data.dig("currency", "code")

      # Update account details
      coinbase_account.assign_attributes(
        name: account_data["name"] || currency_code,
        currency: currency_code,
        current_balance: balance,
        account_type: account_data["type"], # "wallet", "vault", etc.
        account_status: account_data.dig("status") || "active",
        provider: "coinbase",
        raw_payload: account_data,
        institution_metadata: {
          "name" => "Coinbase",
          "domain" => "coinbase.com",
          "crypto_name" => account_data.dig("currency", "name"),
          "crypto_code" => currency_code,
          "crypto_type" => account_data.dig("currency", "type") # "crypto" or "fiat"
        }
      )

      # Fetch transactions for every account, regardless of current balance:
      # a wallet that was fully sold or transferred out still needs its
      # history imported to reconstruct realized gains, and a balance of
      # zero here says nothing about whether that history exists.
      fetch_and_store_transactions(coinbase_account, account_data["id"])

      coinbase_account.save!
    end

    def fetch_and_store_transactions(coinbase_account, account_id)
      # Fetch transactions for this account (includes buys, sells, sends, receives)
      # This endpoint returns better data than separate buys/sells endpoints
      transactions = coinbase_provider.get_transactions(account_id, limit: FULL_HISTORY_LIMIT)
      store_transactions(coinbase_account, transactions)
    rescue Provider::Coinbase::PartialResultError => e
      # A rate limit hit a later page after earlier ones already succeeded;
      # Provider::Coinbase#paginated_get hands back those earlier pages
      # instead of discarding them. Transactions are newest-first, so a
      # *shorter* partial fetch can still contain genuinely new transactions
      # the last stored history doesn't have -- comparing sizes to decide
      # whether to keep it would silently drop those. Merge by id instead:
      # every stored transaction is kept, every new one is added, and an id
      # present in both takes the freshly-fetched version.
      merged = merge_transactions(coinbase_account, e.partial_results)
      store_transactions(coinbase_account, merged, truncated: true)
      record_transactions_incident(coinbase_account, e, account_id, partial: true)
    rescue Provider::Coinbase::ApiError, Provider::Coinbase::RateLimitError => e
      # RateLimitError is a sibling of ApiError (both < Provider::Coinbase::Error),
      # not a subclass, so it has to be listed explicitly here. Without it, a
      # 429 on this call propagates past coinbase_account.save! below, so this
      # account's balance update -- already fetched correctly above -- gets
      # silently skipped for the whole sync along with the transaction fetch.
      record_transactions_incident(coinbase_account, e, account_id)
    end

    def merge_transactions(coinbase_account, incoming)
      stored = coinbase_account.raw_transactions_payload&.dig("transactions") || []
      by_id = stored.index_by { |txn| txn["id"] }
      incoming.each { |txn| by_id[txn["id"]] = txn }
      by_id.values
    end

    def store_transactions(coinbase_account, transactions, truncated: false)
      coinbase_account.raw_transactions_payload = {
        "transactions" => transactions,
        "fetched_at" => Time.current.iso8601,
        "truncated" => truncated
      }

      Rails.logger.info(
        "CoinbaseItem::Importer - Fetched #{transactions.count} transactions for #{coinbase_account.name}#{" (truncated by a rate limit)" if truncated}"
      )
    end

    def record_transactions_incident(coinbase_account, error, account_id, partial: false)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "#{partial ? "Partial" : "No"} transactions fetched this sync (#{error.class.name.demodulize}) for account #{account_id}: #{error.message}",
        source: self.class.name,
        provider_key: "coinbase",
        family: coinbase_item.family,
        account_provider: coinbase_account.account_provider,
        metadata: { coinbase_item_id: coinbase_item.id, account_id: account_id }
      )
    end
end
