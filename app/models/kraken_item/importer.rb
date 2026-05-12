# frozen_string_literal: true

class KrakenItem::Importer
  MAX_TRADE_PAGES = 200
  TRADE_PAGE_SIZE = 50

  attr_reader :kraken_item, :kraken_provider

  def initialize(kraken_item, kraken_provider:)
    @kraken_item = kraken_item
    @kraken_provider = kraken_provider
  end

  def import
    api_key_info = kraken_provider.get_api_key_info

    asset_metadata = kraken_provider.get_asset_info || {}
    pair_metadata = kraken_provider.get_asset_pairs || {}
    balances = kraken_provider.get_extended_balance || {}
    assets = parse_assets(balances, asset_metadata)
    trades = fetch_trades

    total_usd = assets.sum { |asset| asset[:amount_usd].to_d }.round(2)
    kraken_account = upsert_kraken_account(
      assets: assets,
      balances: balances,
      trades: trades,
      asset_metadata: asset_metadata,
      pair_metadata: pair_metadata,
      api_key_info: api_key_info,
      total_usd: total_usd
    )

    kraken_item.upsert_kraken_snapshot!({
      "api_key_info" => api_key_info,
      "balances" => balances,
      "asset_metadata" => asset_metadata,
      "pair_metadata" => pair_metadata,
      "imported_at" => Time.current.iso8601
    })

    { success: true, account_id: kraken_account.id, assets_imported: assets.size, trades_imported: trades.size, total_usd: total_usd }
  rescue Provider::Kraken::PermissionError => e
    kraken_item.update!(status: :requires_update)
    raise e
  end

  private
    def parse_assets(balances, asset_metadata)
      normalizer = KrakenAccount::AssetNormalizer.new(asset_metadata)

      balances.filter_map do |raw_asset, balance_data|
        parsed = normalizer.normalize(raw_asset)
        balance = balance_data.fetch("balance", "0").to_d
        credit = balance_data.fetch("credit", "0").to_d
        credit_used = balance_data.fetch("credit_used", "0").to_d
        hold_trade = balance_data.fetch("hold_trade", "0").to_d
        available = balance + credit - credit_used - hold_trade

        next if balance.zero? && hold_trade.zero?

        price_usd, price_status = price_for(parsed[:price_symbol])
        amount_usd = price_usd ? (balance * price_usd).round(2) : 0.to_d

        parsed.merge(
          balance: balance.to_s("F"),
          available: available.to_s("F"),
          hold_trade: hold_trade.to_s("F"),
          price_usd: price_usd&.to_s("F"),
          amount_usd: amount_usd.to_s("F"),
          price_status: price_status,
          source: "spot"
        )
      end
    end

    def price_for(symbol)
      return [ 1.to_d, "exact" ] if symbol == "USD" || KrakenAccount::STABLECOINS.include?(symbol)

      if KrakenAccount::FIAT_CURRENCIES.include?(symbol)
        rate = ExchangeRate.find_or_fetch_rate(from: symbol, to: "USD", date: Date.current)
        return [ rate.rate.to_d, rate.date == Date.current ? "exact" : "stale" ] if rate

        return [ nil, "missing" ]
      end

      ticker_price = ticker_price_for(symbol)
      return [ ticker_price, "exact" ] if ticker_price

      [ nil, "missing" ]
    rescue StandardError => e
      Rails.logger.warn "KrakenItem::Importer - could not price #{symbol}: #{e.message}"
      [ nil, "missing" ]
    end

    def ticker_price_for(symbol)
      pair_candidates_for(symbol).each do |pair|
        response = kraken_provider.get_ticker(pair)
        ticker_payload = response&.values&.first
        price = ticker_payload&.dig("c", 0)
        return price.to_d if price.present?
      rescue Provider::Kraken::ApiError
        next
      end

      nil
    end

    def pair_candidates_for(symbol)
      kraken_symbol = symbol == "BTC" ? "XBT" : symbol
      [
        "#{kraken_symbol}USD",
        "#{symbol}USD",
        "X#{kraken_symbol}ZUSD",
        "#{kraken_symbol}USDT",
        "#{symbol}USDT"
      ].uniq
    end

    def fetch_trades
      start_time = kraken_item.sync_start_date&.to_i
      offset = 0
      all_trades = {}

      MAX_TRADE_PAGES.times do
        result = kraken_provider.get_trades_history(start: start_time, offset: offset)
        trades = result.to_h.fetch("trades", {})
        duplicate_trade_ids = all_trades.keys & trades.keys
        if duplicate_trade_ids.any?
          Rails.logger.warn("KrakenItem::Importer - #{duplicate_trade_ids.size} duplicate trade ids from Kraken page ignored")
        end
        all_trades.merge!(trades.except(*duplicate_trade_ids))

        count = result.to_h["count"].to_i
        break if trades.size < TRADE_PAGE_SIZE

        offset += trades.size
        break if count.positive? && offset >= count
      end

      all_trades
    end

    def upsert_kraken_account(assets:, balances:, trades:, asset_metadata:, pair_metadata:, api_key_info:, total_usd:)
      kraken_item.kraken_accounts.find_or_initialize_by(account_id: "combined").tap do |account|
        account.assign_attributes(
          name: kraken_item.institution_name.presence || "Kraken",
          account_type: "combined",
          currency: "USD",
          current_balance: total_usd,
          institution_metadata: institution_metadata(assets),
          raw_payload: {
            "balances" => balances,
            "assets" => assets.map(&:stringify_keys),
            "asset_metadata" => asset_metadata,
            "pair_metadata" => pair_metadata,
            "api_key_info" => api_key_info,
            "fetched_at" => Time.current.iso8601
          },
          raw_transactions_payload: {
            "trades" => trades,
            "fetched_at" => Time.current.iso8601
          },
          extra: account.extra.to_h.deep_merge(price_metadata(assets))
        )
        account.save!
      end
    end

    def institution_metadata(assets)
      {
        "name" => "Kraken",
        "domain" => "kraken.com",
        "url" => "https://www.kraken.com",
        "color" => "#5841D8",
        "asset_count" => assets.size,
        "assets" => assets.map { |asset| asset[:symbol] }
      }
    end

    def price_metadata(assets)
      missing = assets.select { |asset| asset[:price_status] == "missing" }.map { |asset| asset[:symbol] }
      stale = assets.select { |asset| asset[:price_status] == "stale" }.map { |asset| asset[:symbol] }

      { "kraken" => { "missing_prices" => missing, "stale_prices" => stale } }
    end
end
