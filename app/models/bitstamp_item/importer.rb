# frozen_string_literal: true

class BitstampItem::Importer
  MAX_TRANSACTION_PAGES = 50
  TRANSACTION_PAGE_SIZE = 1000

  attr_reader :bitstamp_item, :bitstamp_provider

  def initialize(bitstamp_item, bitstamp_provider:)
    @bitstamp_item = bitstamp_item
    @bitstamp_provider = bitstamp_provider
  end

  def import
    raw_balances = bitstamp_provider.get_account_balances || []
    raw_earn = fetch_earn_subscriptions
    spot_assets = parse_assets(raw_balances)
    earn_assets = parse_earn_assets(raw_earn)
    assets = spot_assets + earn_assets
    transactions = fetch_transactions
    earn_transactions = fetch_earn_transactions

    total_usd = assets.sum { |asset| asset[:amount_usd].to_d }.round(2)
    bitstamp_account = upsert_bitstamp_account(
      assets: assets,
      raw_balances: raw_balances,
      transactions: transactions,
      earn_transactions: earn_transactions,
      total_usd: total_usd
    )

    bitstamp_item.upsert_bitstamp_snapshot!({
      "raw_balances" => raw_balances,
      "raw_earn" => raw_earn,
      "imported_at" => Time.current.iso8601
    })

    { success: true, account_id: bitstamp_account.id, assets_imported: assets.size, transactions_imported: transactions.size, total_usd: total_usd }
  rescue Provider::Bitstamp::PermissionError => e
    bitstamp_item.update!(status: :requires_update)
    raise e
  end

  private

    def parse_assets(raw_balances)
      raw_balances.filter_map do |balance_data|
        symbol = (balance_data["currency_symbol"] || balance_data["currency"]).to_s.upcase
        total = (balance_data["balance"] || balance_data["total"]).to_d
        available = balance_data["available"].to_d
        reserved = balance_data["reserved"].to_d

        next if total.zero? && reserved.zero?

        price_usd, price_status = price_for(symbol)
        amount_usd = price_usd ? (total * price_usd).round(2) : 0.to_d

        {
          symbol: symbol,
          balance: total.to_s("F"),
          available: available.to_s("F"),
          reserved: reserved.to_s("F"),
          price_usd: price_usd&.to_s("F"),
          amount_usd: amount_usd.to_s("F"),
          price_status: price_status,
          source: "spot"
        }
      end
    end

    def price_for(symbol)
      return [ 1.to_d, "exact" ] if symbol == "USD" || BitstampAccount::STABLECOINS.include?(symbol)

      if BitstampAccount::FIAT_CURRENCIES.include?(symbol)
        rate = ExchangeRate.find_or_fetch_rate(from: symbol, to: "USD", date: Date.current)
        return [ rate.rate.to_d, rate.date == Date.current ? "exact" : "stale" ] if rate

        return [ nil, "missing" ]
      end

      ticker_price = ticker_price_for(symbol)
      return [ ticker_price, "exact" ] if ticker_price

      [ nil, "missing" ]
    rescue StandardError => e
      Rails.logger.warn "BitstampItem::Importer - could not price #{symbol}: #{e.message}"
      [ nil, "missing" ]
    end

    def ticker_price_for(symbol)
      pair_candidates_for(symbol).each do |pair|
        response = bitstamp_provider.get_ticker(pair)
        price = response&.dig("last")
        return price.to_d if price.present?
      rescue Provider::Bitstamp::ApiError
        next
      end

      nil
    end

    def pair_candidates_for(symbol)
      downcased = symbol.downcase
      [ "#{downcased}usd", "#{downcased}usdt", "#{downcased}eur" ].uniq
    end

    def fetch_earn_subscriptions
      bitstamp_provider.get_earn_subscriptions || []
    rescue Provider::Bitstamp::Error => e
      Rails.logger.warn "BitstampItem::Importer - earn subscriptions unavailable: #{e.message}"
      []
    end

    def fetch_earn_transactions
      offset = 0
      all_transactions = []

      MAX_TRANSACTION_PAGES.times do
        page = bitstamp_provider.get_earn_transactions(offset: offset, limit: TRANSACTION_PAGE_SIZE) || []
        break if page.empty?

        all_transactions.concat(page)
        break if page.size < TRANSACTION_PAGE_SIZE

        offset += page.size
      end

      all_transactions
    rescue Provider::Bitstamp::Error => e
      Rails.logger.warn "BitstampItem::Importer - earn transactions unavailable: #{e.message}"
      []
    end

    def parse_earn_assets(raw_earn)
      raw_earn.filter_map do |sub|
        symbol = sub["currency"].to_s.upcase
        total = sub["amount"].to_d
        next if symbol.blank? || total.zero?

        price_usd, price_status = price_for(symbol)
        amount_usd = price_usd ? (total * price_usd).round(2) : 0.to_d

        {
          symbol: symbol,
          balance: total.to_s("F"),
          available: sub["available_amount"].to_d.to_s("F"),
          reserved: 0.to_d.to_s("F"),
          price_usd: price_usd&.to_s("F"),
          amount_usd: amount_usd.to_s("F"),
          price_status: price_status,
          source: "earn",
          subscription_type: sub["type"].to_s.upcase
        }
      end
    end

    def fetch_transactions
      since_timestamp = bitstamp_item.sync_start_date&.to_i
      offset = 0
      all_transactions = []

      MAX_TRANSACTION_PAGES.times do
        params = { offset: offset, limit: TRANSACTION_PAGE_SIZE }
        params[:since_timestamp] = since_timestamp if since_timestamp.present?

        page = bitstamp_provider.get_user_transactions(**params) || []
        break if page.empty?

        all_transactions.concat(page)
        break if page.size < TRANSACTION_PAGE_SIZE

        offset += page.size
      end

      all_transactions
    end

    def upsert_bitstamp_account(assets:, raw_balances:, transactions:, earn_transactions:, total_usd:)
      bitstamp_item.bitstamp_accounts.find_or_initialize_by(account_id: "combined").tap do |account|
        account.assign_attributes(
          name: bitstamp_item.institution_name.presence || "Bitstamp",
          account_type: "combined",
          currency: "USD",
          current_balance: total_usd,
          institution_metadata: institution_metadata(assets),
          raw_payload: {
            "raw_balances" => raw_balances,
            "assets" => assets.map(&:stringify_keys),
            "fetched_at" => Time.current.iso8601
          },
          raw_transactions_payload: {
            "transactions" => transactions,
            "earn_transactions" => earn_transactions,
            "fetched_at" => Time.current.iso8601
          }
        )
        account.save!
      end
    end

    def institution_metadata(assets)
      {
        "name" => "Bitstamp",
        "domain" => "bitstamp.net",
        "url" => "https://www.bitstamp.net",
        "color" => "#00A86B",
        "asset_count" => assets.size,
        "assets" => assets.map { |asset| asset[:symbol] }
      }
    end
end
