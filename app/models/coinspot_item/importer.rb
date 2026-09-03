# frozen_string_literal: true

class CoinspotItem::Importer
  # CoinSpot's history endpoints default to the last 24 hours when `startdate`
  # is omitted, so an initial sync with no user-configured sync_start_date
  # would otherwise silently import almost nothing. Mirrors Wise::Importer's
  # DEFAULT_HISTORY_DAYS fallback for the same reason.
  DEFAULT_HISTORY_DAYS = 365

  attr_reader :coinspot_item, :coinspot_provider

  # Initializes with the connection and an authenticated Provider::Coinspot
  # client to fetch data with.
  def initialize(coinspot_item, coinspot_provider:)
    @coinspot_item = coinspot_item
    @coinspot_provider = coinspot_provider
  end

  # Fetches every kind of CoinSpot data (balances, orders, transfers,
  # deposits, withdrawals) and upserts it into the connection's single
  # combined CoinspotAccount record. Marks the item as needing updated
  # credentials on a permission failure; other errors propagate to the
  # caller (the syncer) to classify.
  def import
    status = coinspot_provider.status
    balances = coinspot_provider.get_balances
    orders = fetch_order_history
    send_receive = coinspot_provider.get_send_receive_history(**history_window)
    deposits = coinspot_provider.get_deposit_history(**history_window)
    withdrawals = coinspot_provider.get_withdrawal_history(**history_window)

    assets = parse_assets(balances)
    total_aud = assets.sum { |asset| asset[:amount_aud].to_d }.round(2)
    coinspot_account = upsert_coinspot_account(
      assets: assets,
      balances: balances,
      orders: orders,
      send_receive: send_receive,
      deposits: deposits,
      withdrawals: withdrawals,
      status: status,
      total_aud: total_aud
    )

    coinspot_item.upsert_coinspot_snapshot!({
      "status" => status,
      "balances" => balances,
      "imported_at" => Time.current.iso8601
    })

    {
      success: true,
      account_id: coinspot_account.id,
      assets_imported: assets.size,
      orders_imported: count_orders(orders),
      total_aud: total_aud
    }
  rescue Provider::Coinspot::PermissionError => e
    coinspot_item.update!(status: :requires_update)
    raise e
  end

  private

    # The startdate/enddate every history fetch is scoped to: the user's
    # configured sync_start_date, or DEFAULT_HISTORY_DAYS back when unset.
    # startdate is always present -- CoinSpot's endpoints silently default to
    # the last 24 hours when it's omitted.
    def history_window
      {
        startdate: coinspot_item.sync_start_date&.to_date || DEFAULT_HISTORY_DAYS.days.ago.to_date,
        enddate: Date.current
      }
    end

    # The three shapes CoinSpot's order-history endpoints return records in:
    # "buyorders"/"sellorders" from the primary endpoint (always that type),
    # and "orders" from the market-order fallback (mixed type, inferred per
    # order by CoinspotAccount::Processor#infer_order_type).
    ORDER_BUCKETS = %w[buyorders sellorders orders].freeze
    ORDER_HISTORY_LIMIT = Provider::Coinspot::MAX_ORDER_HISTORY_LIMIT

    # Fetches order history via the primary endpoint, falling back to the
    # market-order endpoint if the primary one errors. Partitions the date
    # range into 30-day windows, further bisecting any window whose response
    # comes back saturated (== ORDER_HISTORY_LIMIT), since that means more
    # records exist in that window than a single response can return.
    def fetch_order_history
      orders_by_id = ORDER_BUCKETS.index_with { {} }
      window_start = history_window[:startdate]
      window_end = history_window[:enddate]

      while window_start <= window_end
        current_window_end = [ window_start + 29.days, window_end ].min
        merge_window!(orders_by_id, startdate: window_start, enddate: current_window_end)
        window_start = current_window_end + 1.day
      end

      orders_by_id.transform_values(&:values)
    end

    # Fetches one date window and merges its records into `orders_by_id`
    # (deduped per bucket by order id). Bisects and retries when the
    # response is saturated, bottoming out at a single day -- CoinSpot
    # offers no finer-grained paging, so a still-saturated single day is
    # logged and accepted as an incomplete import rather than looped on.
    def merge_window!(orders_by_id, startdate:, enddate:)
      buckets = fetch_orders_for_window(startdate: startdate, enddate: enddate)

      if saturated?(buckets)
        if startdate < enddate
          midpoint = startdate + ((enddate - startdate) / 2).to_i.days
          merge_window!(orders_by_id, startdate: startdate, enddate: midpoint)
          merge_window!(orders_by_id, startdate: midpoint + 1.day, enddate: enddate)
          return
        end

        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "CoinSpot order history for #{startdate} may be incomplete: a single day hit the #{ORDER_HISTORY_LIMIT}-record response limit",
          source: self.class.name,
          provider_key: "coinspot",
          family: coinspot_item.family,
          metadata: { coinspot_item_id: coinspot_item.id, date: startdate.to_s }
        )
      end

      buckets.each do |kind, orders|
        orders.each do |order|
          order_id = order["id"] || order[:id]
          orders_by_id[kind][order_id] = order if order_id
        end
      end
    end

    def saturated?(buckets)
      buckets.values.any? { |orders| orders.size >= ORDER_HISTORY_LIMIT }
    end

    # Returns the primary endpoint's buy/sell orders for the window, or the
    # market-order fallback's mixed-type orders if the primary endpoint
    # errors. Both the primary and fallback failing for the same window
    # degrades to an empty result (logged) rather than aborting the sync,
    # so one bad window doesn't lose every other window's history.
    def fetch_orders_for_window(startdate:, enddate:)
      response = coinspot_provider.get_order_history(startdate: startdate, enddate: enddate)
      { "buyorders" => Array(response["buyorders"]), "sellorders" => Array(response["sellorders"]) }
    rescue Provider::Coinspot::ApiError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "CoinSpot order history failed for window #{startdate}-#{enddate}; trying market order history: #{e.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_item.family,
        metadata: { coinspot_item_id: coinspot_item.id, error_class: e.class.name }
      )

      begin
        response = coinspot_provider.get_market_order_history(startdate: startdate, enddate: enddate)
        { "orders" => Array(response["orders"]) }
      rescue Provider::Coinspot::ApiError => e
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "error",
          message: "CoinSpot order history failed for window #{startdate}-#{enddate}: #{e.message}",
          source: self.class.name,
          provider_key: "coinspot",
          family: coinspot_item.family,
          metadata: { coinspot_item_id: coinspot_item.id, error_class: e.class.name }
        )
        {}
      end
    end

    # Converts CoinSpot's balances response into the flat asset-list shape
    # the rest of the importer works with, dropping zero-balance/zero-value
    # entries and deriving an AUD amount from the rate when CoinSpot doesn't
    # supply one directly.
    def parse_assets(balances)
      Array(balances["balances"]).filter_map do |entry|
        symbol, balance_data = entry.first
        next if symbol.blank? || !balance_data.is_a?(Hash)

        balance = balance_data["balance"].to_d
        amount_aud = balance_data["audbalance"].presence&.to_d
        rate_aud = balance_data["rate"].presence&.to_d
        amount_aud ||= symbol.to_s.upcase == "AUD" ? balance : balance * rate_aud.to_d
        next if balance.zero? && amount_aud.zero?

        {
          symbol: symbol.to_s.upcase,
          balance: balance.to_s("F"),
          amount_aud: amount_aud.to_s("F"),
          price_aud: rate_aud&.to_s("F"),
          source: "spot"
        }
      end
    end

    # Finds or creates this connection's single combined CoinspotAccount
    # record and stores the freshly-fetched balance and transaction-history
    # payloads on it for CoinspotAccount::Processor to turn into activity.
    def upsert_coinspot_account(assets:, balances:, orders:, send_receive:, deposits:, withdrawals:, status:, total_aud:)
      coinspot_item.coinspot_accounts.find_or_initialize_by(account_id: "combined").tap do |account|
        account.assign_attributes(
          name: coinspot_item.institution_name.presence || "CoinSpot",
          account_type: "combined",
          currency: "AUD",
          current_balance: total_aud,
          institution_metadata: institution_metadata(assets),
          raw_payload: {
            "balances" => balances,
            "assets" => assets.map(&:stringify_keys),
            "status" => status,
            "fetched_at" => Time.current.iso8601
          },
          raw_transactions_payload: {
            "orders" => orders,
            "send_receive" => send_receive,
            "deposits" => deposits,
            "withdrawals" => withdrawals,
            "fetched_at" => Time.current.iso8601
          },
          extra: account.extra.to_h.deep_merge(price_metadata(assets))
        )
        account.save!
      end
    end

    # Institution branding plus a snapshot of which assets were seen, stored
    # on the account for display without re-parsing the raw payload.
    def institution_metadata(assets)
      {
        "name" => "CoinSpot",
        "domain" => "coinspot.com.au",
        "url" => "https://www.coinspot.com.au",
        "color" => "#0F6BFF",
        "asset_count" => assets.size,
        "assets" => assets.map { |asset| asset[:symbol] }
      }
    end

    # Flags any non-AUD asset CoinSpot returned with no price, so the UI can
    # surface which holdings' valuations are incomplete.
    def price_metadata(assets)
      missing = assets.select { |asset| asset[:price_aud].blank? && asset[:symbol] != "AUD" }.map { |asset| asset[:symbol] }
      { "coinspot" => { "missing_prices" => missing } }
    end

    # Total order count across every order-history shape CoinSpot can return.
    def count_orders(orders)
      Array(orders["buyorders"]).size + Array(orders["sellorders"]).size + Array(orders["orders"]).size
    end
end
