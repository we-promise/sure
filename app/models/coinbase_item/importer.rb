# Imports wallet/account data from Coinbase API.
# Fetches accounts, balances, and transaction history.
class CoinbaseItem::Importer
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
      # Skip accounts with zero balance unless they have transaction history
      balance = account_data.dig("balance", "amount").to_d
      return if balance.zero? && account_data.dig("balance", "currency") != "USD"

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

      # Fetch transactions for this account if it has a balance
      if balance > 0
        fetch_and_store_transactions(coinbase_account, account_data["id"])
      end

      coinbase_account.save!
    end

    def fetch_and_store_transactions(coinbase_account, account_id)
      # Fetch transactions for this account (includes buys, sells, sends, receives)
      # This endpoint returns better data than separate buys/sells endpoints
      transactions = coinbase_provider.get_transactions(account_id, limit: 100)

      # Store raw transaction data for processing later
      coinbase_account.raw_transactions_payload = {
        "transactions" => transactions,
        "fetched_at" => Time.current.iso8601
      }

      Rails.logger.info(
        "CoinbaseItem::Importer - Fetched #{transactions.count} transactions for #{coinbase_account.name}"
      )
    rescue Provider::Coinbase::ApiError => e
      # Some accounts may not support transaction endpoints
      Rails.logger.debug "CoinbaseItem::Importer - Could not fetch transactions for account #{account_id}: #{e.message}"
    end
end
