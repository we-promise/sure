# frozen_string_literal: true

# Fetches the API key's balances and stores them, valued in USD, on the
# connection's single account, along with the raw transaction history.
# One API key is one Revolut X (sub-)account,
# so a connection always has exactly one RevolutXAccount.
class RevolutXItem::Importer
  ACCOUNT_ID = "default"
  # Quotes tried when an asset has no USD pair, converted to USD via ExchangeRate.
  FALLBACK_QUOTES = %w[EUR GBP].freeze

  TRANSACTIONS_WINDOW_MS = 30 * 86_400_000
  TRANSACTIONS_PAGE_LIMIT = 1900
  INCREMENTAL_OVERLAP = 3.days
  DEFAULT_HISTORY = 2.years

  class RepeatedCursorError < StandardError; end

  attr_reader :revolut_x_item, :revolut_x_provider

  def initialize(revolut_x_item, revolut_x_provider:)
    @revolut_x_item = revolut_x_item
    @revolut_x_provider = revolut_x_provider
  end

  def import
    balances = Array(revolut_x_provider.get_balances)
    currencies = revolut_x_provider.get_currencies
    # Kept for the history floor only; its totals are never holdings.
    sub_accounts = revolut_x_provider.get_sub_accounts.to_h.dig("data", "sub_accounts")
    tickers = revolut_x_provider.get_tickers.to_h.fetch("data", []).index_by { |ticker| ticker["symbol"] }

    # Saved first: fiat_currency? reads the currencies from it.
    revolut_x_item.update!(raw_payload: {
      "balances" => balances,
      "sub_accounts" => sub_accounts,
      "currencies" => currencies,
      "imported_at" => Time.current.iso8601(6)
    })

    assets = balances.filter_map { |balance| parse_asset(balance, tickers) }
    total_usd = assets.sum { |asset| asset["amount_usd"].to_d }

    account = upsert_account(assets, total_usd)
    import_transactions(account)
    { success: true, account_id: account.id, assets_imported: assets.size, total_usd: total_usd }
  end

  private

    # Walks back from now in 30-day windows (the API's maximum), newest first.
    # The cursor only advances once every window and page arrived, so a walk
    # cut short by a rate limit is redone from the same point next sync.
    def import_transactions(account)
      now = Time.current
      stored = account.raw_transactions_payload.to_h.fetch("transactions", {})
      fetched = {}

      complete = begin
        window_end = to_ms(now)
        floor = transactions_floor_ms(stored)
        while window_end > floor
          window_start = [ window_end - TRANSACTIONS_WINDOW_MS, floor ].max
          fetch_window(window_start, window_end) { |row| fetched[row["id"]] = row }
          window_end = window_start
        end
        true
      rescue Provider::RevolutX::RateLimitError, Provider::RevolutX::ApiError, RepeatedCursorError,
             SystemCallError, *Provider::HttpTransport::TRANSPORT_ERRORS => e
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "Revolut X transaction history stopped early: #{e.message}",
          source: self.class.name,
          provider_key: "revolut_x",
          family: revolut_x_item.family,
          account_provider: account.account_provider,
          metadata: { revolut_x_item_id: revolut_x_item.id, error_class: e.class.name, rows_fetched: fetched.size }
        )
        false
      end

      commit_transactions(account, fetched, now, complete)
    end

    # Two imports of one item can overlap (sync dedupe only lasts
    # Sync::VISIBLE_FOR), so the commit runs under the account's row lock,
    # merges into the rows stored now rather than those read at the start,
    # and is skipped when a newer import has already committed. fetched_at
    # keeps microseconds: TransactionsProcessor compares it with
    # transactions_synced_through to tell a cut walk from a complete one.
    def commit_transactions(account, fetched, now, complete)
      account.with_lock do
        payload = account.raw_transactions_payload.to_h
        next if payload["fetched_at"].present? && Time.iso8601(payload["fetched_at"]) > now

        account.update!(raw_transactions_payload: {
          "transactions" => payload.fetch("transactions", {}).merge(fetched),
          "fetched_at" => now.iso8601(6)
        })
        revolut_x_item.update!(transactions_synced_through: now) if complete
      end
    end

    # A malformed page raises rather than being skipped, so the walk counts
    # as cut short and is redone from the same point next sync.
    def fetch_window(start_ms, end_ms)
      cursor = nil
      seen = Set.new

      loop do
        page = revolut_x_provider.get_transactions(start_date: start_ms, end_date: end_ms, cursor: cursor, limit: TRANSACTIONS_PAGE_LIMIT).to_h
        rows = page["data"]
        unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row["id"].present? }
          raise Provider::RevolutX::ApiError, "malformed transactions page for window #{start_ms}..#{end_ms}"
        end
        rows.each { |row| yield row }

        cursor = page.dig("metadata", "next_cursor")
        break if cursor.blank?
        raise RepeatedCursorError, "cursor repeated" unless seen.add?(cursor)
      end
    end

    # First sync: back to the oldest sub-account, or sync_start_date when that
    # is later. Later syncs overlap the last walk by INCREMENTAL_OVERLAP, and
    # reach further back for any row still pending so its outcome is picked up.
    def transactions_floor_ms(stored)
      synced_through = revolut_x_item.transactions_synced_through
      if synced_through
        oldest_pending = stored.values.select { |row| row["status"] == "pending" }.filter_map { |row| row["created_date"]&.to_i }.min
        return [ to_ms(synced_through - INCREMENTAL_OVERLAP), oldest_pending ].compact.min
      end

      created = Array(revolut_x_item.raw_payload.to_h["sub_accounts"]).filter_map { |sub_account| sub_account["created_date"]&.to_i }.min
      start = revolut_x_item.sync_start_date && to_ms(revolut_x_item.sync_start_date)
      [ created, start ].compact.max || to_ms(DEFAULT_HISTORY.ago)
    end

    def to_ms(time)
      (time.to_r * 1000).to_i
    end

    def parse_asset(balance, tickers)
      symbol = balance["currency"].to_s.upcase
      total = parse_total(balance)
      return if symbol.blank? || total.zero?

      fiat = revolut_x_item.fiat_currency?(symbol)
      price_usd = fiat ? fiat_usd_rate(symbol) : crypto_usd_price(symbol, tickers)

      {
        "symbol" => symbol,
        "name" => revolut_x_item.raw_payload.dig("currencies", symbol, "name"),
        "kind" => fiat ? "fiat" : "crypto",
        "total" => total.to_s("F"),
        "available" => balance["available"],
        "reserved" => balance["reserved"],
        "staked" => balance["staked"],
        # nil when nothing prices it; the processor skips and reports it.
        "price_usd" => price_usd&.to_s("F"),
        "amount_usd" => price_usd ? (total * price_usd).round(2).to_s("F") : "0"
      }
    end

    # A missing or non-numeric total raises: read as 0 it would look like a
    # sold asset and drop the holding.
    def parse_total(balance)
      BigDecimal(balance["total"].to_s)
    rescue ArgumentError, TypeError
      raise Provider::RevolutX::ApiError, "invalid balance total for #{balance["currency"].inspect}: #{balance["total"].inspect}"
    end

    def crypto_usd_price(symbol, tickers)
      usd = ticker_price(tickers["#{symbol}/USD"])
      return usd if usd

      FALLBACK_QUOTES.each do |quote|
        price = ticker_price(tickers["#{symbol}/#{quote}"])
        rate = fiat_usd_rate(quote) if price
        return price * rate if rate
      end

      nil
    end

    def ticker_price(ticker)
      return nil unless ticker.is_a?(Hash)

      price = ticker["mid"].presence || ticker["last_price"].presence
      price&.to_d&.positive? ? price.to_d : nil
    end

    def fiat_usd_rate(code)
      Money.new(1, code).exchange_to("USD").amount
    rescue Money::ConversionError, Money::Currency::UnknownCurrencyError
      nil
    end

    def upsert_account(assets, total_usd)
      revolut_x_item.revolut_x_accounts.find_or_initialize_by(account_id: ACCOUNT_ID).tap do |account|
        account.update!(
          name: revolut_x_item.name,
          account_type: "exchange",
          currency: "USD",
          current_balance: total_usd,
          raw_payload: { "assets" => assets, "fetched_at" => Time.current.iso8601 }
        )
      end
    end
end
