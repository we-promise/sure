class MoomooAccount::ActivitiesProcessor
  include MoomooAccount::DataHelpers

  def initialize(moomoo_account)
    @moomoo_account = moomoo_account
    @skipped = Hash.new(0)
  end

  # Each fill of a stock or fund becomes a trade in its order's currency (an
  # account split by currency takes only its own currency's fills), and
  # a fill moomoo cancelled removes its trade. Short sales, buy-backs and
  # derivatives are skipped. moomoo reports fees per order only, so trades
  # carry none.
  def process
    return { trades: 0, removed: 0, skipped: 0 } unless account.present?

    trades = 0
    removed = 0
    fills.each do |fill|
      if fill["status"].to_s == "CANCELLED"
        removed += 1 if remove_cancelled(fill)
      elsif import_fill(fill)
        trades += 1
      end
    end

    log_skipped
    { trades: trades, removed: removed, skipped: @skipped.values.sum }
  end

  private

    attr_reader :moomoo_account

    def account
      @account ||= moomoo_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def fills
      moomoo_account.fills
    end

    def orders
      @orders ||= moomoo_account.source_account.orders_map
    end

    def positions_by_code
      @positions_by_code ||= moomoo_account.positions_by_code
    end

    def import_fill(fill)
      details = trade_fill_details(fill, orders, positions_by_code)
      return skip(details) if details.is_a?(Symbol)

      quantity = details[:quantity]
      gross = details[:gross]

      import_adapter.import_trade(
        external_id: fill_external_id(fill),
        source: "moomoo",
        security: security_for_code(fill["code"], fill["stock_name"]),
        quantity: details[:buy] ? quantity : -quantity,
        price: details[:price],
        amount: details[:buy] ? gross : -gross,
        currency: details[:currency],
        date: details[:date],
        activity_label: TRADE_SIDES[details[:side]]
      )
      true
    rescue => e
      capture_failure(fill, e)
      false
    end

    # A trade the user edited or excluded is left alone.
    def remove_cancelled(fill)
      entry = account.entries.find_by(external_id: fill_external_id(fill), source: "moomoo")
      return false if entry.nil? || entry.protected_from_sync?

      entry.destroy!
      true
    rescue => e
      capture_failure(fill, e)
      false
    end

    def skip(reason)
      @skipped[reason.to_s] += 1
      false
    end

    def log_skipped
      return if @skipped.empty?

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooAccount::ActivitiesProcessor - skipped #{@skipped.values.sum} fills",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { reasons: @skipped.to_h, moomoo_account_id: moomoo_account.id }
      )
    end

    def capture_failure(fill, error)
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "MoomooAccount::ActivitiesProcessor - Failed to import fill #{fill['deal_id']}: #{error.message}",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { deal_id: fill["deal_id"], moomoo_account_id: moomoo_account.id }
      )
    end
end
