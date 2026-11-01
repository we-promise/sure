# frozen_string_literal: true

class KrakenItem::Importer
  MAX_TRADE_PAGES = 200
  TRADE_PAGE_SIZE = 50
  MAX_LEDGER_PAGES = 200
  LEDGER_PAGE_SIZE = 50
  MAX_EARN_PAGES = 50

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
    assets += fetch_and_parse_earn_assets(asset_metadata)
    trades = fetch_trades
    ledgers = fetch_ledgers

    total_usd = assets.sum { |asset| asset[:amount_usd].to_d }.round(2)
    kraken_account = upsert_kraken_account(
      assets: assets,
      balances: balances,
      trades: trades,
      ledgers: ledgers,
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

    { success: true, account_id: kraken_account.id, assets_imported: assets.size, trades_imported: trades.size, ledgers_imported: ledgers.size, total_usd: total_usd }
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

        # Price the underlying asset, not the wallet variant: there is no
        # DOT28.S ticker, and staked DOT is worth what DOT is worth. Without
        # this the variant prices as "missing" and the holding is dropped
        # entirely, so a staked position vanishes from the snapshot.
        price_usd, price_status = price_for(
          KrakenAccount::SecurityResolver.canonical_asset(parsed[:price_symbol])
        )
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

    # Raised to mean "the Earn/Allocations response can't be trusted as a
    # complete snapshot" -- a fetch that failed outright (any page, including
    # a later cursor page after earlier ones succeeded) or a response whose
    # items don't all parse. Either way, #fetch_and_parse_earn_assets carries
    # forward the last known-good values instead of saving an undercount.
    EarnAllocationsUnavailable = Class.new(StandardError)

    # Earn's allocated principal (staking/bonding) lives in a sub-ledger
    # BalanceEx never reports -- see Provider::Kraken#get_earn_allocations.
    # Without this, only Earn's reward payouts (ordinary Ledgers entries,
    # handled in KrakenAccount::LedgerProcessor) were ever visible; the
    # locked balance itself was invisible to holdings.
    #
    # On any failure -- the fetch itself (permission denied, a transient API
    # error on any page) or one malformed item among otherwise-good ones --
    # carries forward the last successful sync's own "earn" assets rather
    # than saving a spot-only or undercounted snapshot. A source that failed
    # tells us nothing about what it holds, and writing only what did answer
    # would delete real principal from the account on a transient error; the
    # carried assets are stale until the next successful sync, which beats
    # gone. Same pattern as BinanceItem::Importer#carried_over_assets.
    def fetch_and_parse_earn_assets(asset_metadata)
      items = fetch_earn_allocations
      parse_earn_assets(items, asset_metadata)
    rescue Provider::Kraken::PermissionError, Provider::Kraken::ApiError, Provider::Kraken::RateLimitError,
           EarnAllocationsUnavailable, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, SystemCallError => e
      # The last four are raw transport failures (HTTParty/Net::HTTP raise
      # these before a response ever reaches Provider::Kraken#handle_response,
      # so they're never classified into a Provider::Kraken::Error) -- a
      # timeout or dropped connection on this call must degrade the same way
      # as every other Earn-specific failure here, not crash the whole sync.
      record_earn_unavailable(e)
      carried_over_earn_assets
    end

    def parse_earn_assets(items, asset_metadata)
      normalizer = KrakenAccount::AssetNormalizer.new(asset_metadata)

      items.filter_map do |item|
        raw_asset = item["native_asset"] || item[:native_asset]
        raise "Earn allocation missing native_asset: #{item.inspect}" if raw_asset.blank?

        # Checked before to_d, not after: a missing field or a non-numeric
        # value (both blank? false and to_d 0 for the latter) must raise
        # here rather than silently read as "genuinely zero and filtered" --
        # that's a parse failure, not a real zero balance, and needs to go
        # through the rescue below into the carry-forward path instead of
        # quietly saving an undercounted snapshot.
        raw_balance = item.dig("amount_allocated", "total", "native")
        raise "Earn allocation missing amount_allocated.total.native: #{item.inspect}" if raw_balance.blank?
        unless raw_balance.to_s.match?(/\A-?\d+(\.\d+)?\z/)
          raise "Earn allocation has a non-numeric amount_allocated.total.native: #{raw_balance.inspect}"
        end

        balance = raw_balance.to_d
        next if balance.zero? # a genuine zero balance, not a parse failure

        parsed = normalizer.normalize(raw_asset)
        price_usd, price_status = price_for(parsed[:price_symbol])
        amount_usd = price_usd ? (balance * price_usd).round(2) : 0.to_d

        parsed.merge(
          balance: balance.to_s("F"),
          available: "0", # bonded/pending in Earn, not spendable like a spot balance
          hold_trade: balance.to_s("F"),
          price_usd: price_usd&.to_s("F"),
          amount_usd: amount_usd.to_s("F"),
          price_status: price_status,
          source: "earn"
        )
      end
    rescue StandardError => e
      # One malformed item among otherwise-good ones used to be dropped
      # silently here, letting the importer save the remaining items as a
      # complete snapshot -- silently undercounting current_balance. Raising
      # instead routes it through #fetch_and_parse_earn_assets' carry-forward,
      # same as a fetch failure.
      raise EarnAllocationsUnavailable, "could not parse Earn allocation: #{e.message}"
    end

    def fetch_earn_allocations
      cursor = nil
      all_items = []

      MAX_EARN_PAGES.times do
        raw_result = kraken_provider.get_earn_allocations(cursor: cursor)
        # Provider::Kraken#handle_response validates the outer envelope but
        # not the type of "result" itself -- a scalar has no #to_h at all,
        # and a non-pair Array raises TypeError from it, neither of which
        # the rescue below would catch, so this must be checked before #to_h
        # ever runs, not after.
        raise EarnAllocationsUnavailable, "Earn allocation result must be an object" unless raw_result.is_a?(Hash)
        result = raw_result.to_h
        items = result["items"]
        # `|| []` here used to treat a missing "items" key as "genuinely zero
        # Earn assets this sync" -- a malformed response read as a clean
        # empty snapshot, which saves over any previously-carried Earn
        # assets instead of raising into the carry-forward path. A non-Array
        # "items" (e.g. a Hash) would otherwise raise an uncaught TypeError
        # from #concat below, crashing the whole sync instead of degrading
        # gracefully like every other Earn failure here.
        raise EarnAllocationsUnavailable, "Earn allocation items must be an array" unless items.is_a?(Array)
        all_items.concat(items)

        cursor = result["next_cursor"].presence
        break if cursor.blank?
      end

      all_items
    end

    # The prior sync's own "earn" assets, for #fetch_and_parse_earn_assets to
    # carry forward when this sync's Earn data can't be trusted. nil/blank
    # whenever there is nothing to fall back on (first sync, or a previous
    # sync that itself had no Earn holdings) -- filter_map above then simply
    # contributes nothing, same as Earn never having been reachable at all.
    def carried_over_earn_assets
      previous = kraken_item.kraken_accounts.find_by(account_id: "combined")&.raw_payload&.dig("assets")
      return [] if previous.blank?

      carried = previous.map(&:deep_symbolize_keys).select { |asset| asset[:source] == "earn" }

      if carried.any?
        Rails.logger.warn(
          "KrakenItem::Importer #{kraken_item.id} - carrying #{carried.size} Earn asset(s) forward from the last successful sync"
        )
      end

      carried
    end

    def record_earn_unavailable(error)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Earn allocations unavailable this sync (#{error.class.name.demodulize}); carrying forward last known values: #{error.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_item.family,
        metadata: { kraken_item_id: kraken_item.id }
      )
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

    def fetch_ledgers
      start_time = kraken_item.sync_start_date&.to_i
      offset = 0
      all_ledgers = {}

      MAX_LEDGER_PAGES.times do
        result = kraken_provider.get_ledgers(start: start_time, offset: offset)
        ledgers = result.to_h.fetch("ledger", {})
        duplicate_ids = all_ledgers.keys & ledgers.keys
        if duplicate_ids.any?
          DebugLogEntry.capture(
            category: "provider_sync_error",
            level: "warn",
            message: "#{duplicate_ids.size} duplicate ledger ids from Kraken ignored",
            source: self.class.name,
            provider_key: "kraken",
            family: kraken_item.family,
            metadata: { kraken_item_id: kraken_item.id, duplicate_ids: duplicate_ids }
          )
        end
        all_ledgers.merge!(ledgers.except(*duplicate_ids))

        count = result.to_h["count"].to_i
        break if ledgers.size < LEDGER_PAGE_SIZE

        offset += ledgers.size
        break if count.positive? && offset >= count
      end

      all_ledgers
    rescue Provider::Kraken::PermissionError => e
      # Key may not have Query Ledger Entries permission; degrade gracefully.
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Ledgers permission denied; skipping ledger import: #{e.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_item.family,
        metadata: { kraken_item_id: kraken_item.id }
      )
      {}
    end

    def upsert_kraken_account(assets:, balances:, trades:, ledgers:, asset_metadata:, pair_metadata:, api_key_info:, total_usd:)
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
            "ledgers" => ledgers,
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
