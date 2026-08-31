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

    # Fetches order history via the primary endpoint, falling back to the
    # market-order endpoint (a different shape CoinSpot uses for market-type
    # orders) if the primary one errors.
    def fetch_order_history
      coinspot_provider.get_order_history(**history_window)
    rescue Provider::Coinspot::ApiError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "CoinSpot order history failed; trying market order history: #{e.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_item.family,
        metadata: { coinspot_item_id: coinspot_item.id, error_class: e.class.name }
      )
      coinspot_provider.get_market_order_history(**history_window)
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
