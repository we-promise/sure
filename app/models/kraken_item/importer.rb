class KrakenItem::Importer
  attr_reader :kraken_item, :kraken_provider

  def initialize(kraken_item, kraken_provider:)
    @kraken_item = kraken_item
    @kraken_provider = kraken_provider
  end

  def import
    Rails.logger.info "KrakenItem::Importer - Starting import for item #{kraken_item.id}"

    balances = kraken_provider.get_balances
    ledgers = kraken_provider.get_ledgers(start: time_range_start)
    trades = kraken_provider.get_trades_history(start: time_range_start)

    snapshot = {
      "balances" => balances,
      "ledgers" => ledgers,
      "trades" => trades,
      "fetched_at" => Time.current.iso8601
    }
    kraken_item.upsert_kraken_snapshot!(snapshot)

    balance_groups = aggregate_balances(balances)
    ledger_groups = group_ledgers_by_asset(ledgers)
    trade_groups = group_trades_by_asset(trades)

    asset_codes = (balance_groups.keys + ledger_groups.keys + trade_groups.keys).uniq.sort
    asset_codes.each do |asset_code|
      import_account(
        asset_code,
        balance_groups[asset_code],
        ledger_groups[asset_code],
        trade_groups[asset_code]
      )
    end

    {
      success: true,
      accounts_imported: asset_codes.count
    }
  end

  private

    def time_range_start
      kraken_item.sync_start_date&.to_i
    end

    def aggregate_balances(balances)
      balances.each_with_object(Hash.new { |hash, key| hash[key] = { amount: 0.to_d, raw_assets: [] } }) do |(raw_asset, raw_balance), memo|
        asset_code = kraken_provider.normalize_asset_code(raw_asset)
        next if asset_code.blank?

        memo[asset_code][:amount] += raw_balance.to_d
        memo[asset_code][:raw_assets] << raw_asset
      end
    end

    def group_ledgers_by_asset(ledgers)
      ledgers.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(ledger_id, ledger_data), memo|
        ledger = ledger_data.with_indifferent_access
        asset_code = kraken_provider.normalize_asset_code(ledger[:asset])
        next if asset_code.blank?

        memo[asset_code] << ledger.merge(id: ledger_id, normalized_asset: asset_code)
      end
    end

    def group_trades_by_asset(trades)
      trades.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(trade_id, trade_data), memo|
        trade = trade_data.with_indifferent_access
        pair = kraken_provider.pair_for_code(trade[:pair])
        next unless pair

        memo[pair[:base]] << trade.merge(
          id: trade_id,
          normalized_pair: pair,
          base_asset: pair[:base],
          quote_asset: pair[:quote]
        )
      end
    end

    def import_account(asset_code, balance_data, ledger_entries, trades)
      balance = balance_data&.dig(:amount).to_d
      return if balance.zero? && ledger_entries.blank? && trades.blank?

      native_balance = calculate_native_balance(asset_code, balance)
      asset_name = kraken_provider.asset_display_name(asset_code)
      raw_assets = Array(balance_data&.dig(:raw_assets))

      account_snapshot = {
        "id" => asset_code,
        "name" => account_name(asset_code),
        "balance" => balance,
        "currency" => asset_code,
        "status" => "active",
        "provider" => "kraken",
        "institution_name" => "Kraken",
        "asset_name" => asset_name,
        "asset_code" => asset_code,
        "quote_currency" => native_balance["currency"],
        "native_balance" => native_balance,
        "fiat_asset" => kraken_provider.fiat_asset?(asset_code),
        "raw_assets" => raw_assets
      }

      kraken_account = kraken_item.kraken_accounts.find_or_initialize_by(account_id: asset_code)
      kraken_account.upsert_kraken_snapshot!(account_snapshot)
      kraken_account.upsert_kraken_transactions_snapshot!(
        "ledgers" => ledger_entries || [],
        "trades" => trades || [],
        "fetched_at" => Time.current.iso8601
      )
    end

    def calculate_native_balance(asset_code, balance)
      normalized_asset = kraken_provider.normalize_asset_code(asset_code)

      if kraken_provider.fiat_asset?(normalized_asset)
        return {
          "amount" => balance.round(2).to_s("F"),
          "currency" => normalized_asset,
          "price" => "1"
        }
      end

      preferred_quotes.each do |quote_currency|
        price = kraken_provider.get_spot_price(asset: normalized_asset, quote_currency: quote_currency)
        next unless price.present? && price.positive?

        return {
          "amount" => (balance * price).round(2).to_s("F"),
          "currency" => quote_currency,
          "price" => price.to_s("F")
        }
      end

      {
        "amount" => "0",
        "currency" => preferred_quotes.first || "USD"
      }
    end

    def preferred_quotes
      [
        kraken_provider.normalize_asset_code(kraken_item.family.currency.presence || "USD"),
        "USD",
        "EUR"
      ].uniq
    end

    def account_name(asset_code)
      "#{kraken_provider.asset_display_name(asset_code)} Balance"
    end
end
