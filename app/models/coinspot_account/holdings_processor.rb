# frozen_string_literal: true

class CoinspotAccount::HoldingsProcessor
  include CoinspotAccount::AudConverter

  class SnapshotUnavailableError < StandardError; end

  # Initializes with the CoinspotAccount whose latest balance snapshot
  # (raw_payload) will be turned into holdings.
  def initialize(coinspot_account)
    @coinspot_account = coinspot_account
  end

  # Imports every non-AUD asset in the account's latest balance snapshot as a
  # holding, then zeroes out any previously-imported holding whose security
  # is absent from that snapshot (sold/transferred away entirely). No-op for
  # accounts not yet linked to a Crypto Sure account. Returns structured
  # failures so the parent sync cannot report a partial import as successful.
  def process
    return unless account&.accountable_type == "Crypto"

    # An unavailable snapshot is NOT an empty portfolio. raw_payload["assets"]
    # missing (a failed or never-completed fetch) used to read as [], and
    # mark_absent_provider_holdings_zero! then zeroed every holding the
    # account had. A genuinely empty array still zeroes, which is how a
    # wallet emptied down to nothing is represented.
    assets = snapshot_assets
    unless assets
      failure = log_failure(nil, SnapshotUnavailableError.new("CoinSpot balance snapshot has no assets array"))
      return { success: false, failures: [ failure ] }
    end

    failures = assets.filter_map { |asset| process_asset(asset) }
    mark_absent_provider_holdings_zero!
    { success: failures.empty?, failures: failures }
  rescue StandardError => e
    failure = log_failure(nil, e)
    { success: false, failures: [ failure ] }
  end

  private

    attr_reader :coinspot_account

    # The family's base currency -- holdings are always imported in it.
    def target_currency
      coinspot_account.coinspot_item&.family&.currency
    end

    # The linked Sure account holdings are imported into.
    def account
      coinspot_account.current_account
    end

    # The `assets` array from the account's last-synced balance snapshot, or
    # nil when the snapshot doesn't carry one. Callers must treat nil as
    # "unknown" rather than "empty" -- see #process.
    def snapshot_assets
      assets = coinspot_account.raw_payload&.dig("assets")
      assets.is_a?(Array) ? assets : nil
    end

    # The assets actually present in the snapshot; [] when unavailable, for
    # the read-only callers that only ask what is currently held.
    def raw_assets
      snapshot_assets || []
    end

    # Resolves one raw balance-snapshot asset to a Security and imports it as
    # a holding for today. Skips AUD (cash, not a holding) and anything
    # missing a symbol, balance, or AUD amount. A single asset's failure is
    # logged and returned while the rest of the snapshot is still attempted.
    def process_asset(asset)
      symbol = asset["symbol"] || asset[:symbol]
      return if symbol.to_s.upcase == "AUD"

      total = (asset["balance"] || asset[:balance] || 0).to_d
      amount_aud = asset["amount_aud"] || asset[:amount_aud]
      price_aud = asset["price_aud"] || asset[:price_aud]
      source = asset["source"] || asset[:source] || "spot"

      return if symbol.blank? || total.zero? || amount_aud.blank?

      security = CoinspotAccount::SecurityResolver.resolve(symbol)
      return unless security

      amount, amount_stale, amount_rate_date = convert_from_aud(amount_aud.to_d, date: Date.current)
      price = if price_aud.present?
        converted_price, price_stale, price_rate_date = convert_from_aud(price_aud.to_d, date: Date.current)
        log_stale_rate(symbol, "price", price_rate_date) if price_stale
        converted_price
      end
      log_stale_rate(symbol, "amount", amount_rate_date) if amount_stale

      import_adapter.import_holding(
        security: security,
        quantity: total,
        amount: amount,
        currency: target_currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "coinspot_#{symbol}_#{source}_#{Date.current}",
        account_provider_id: coinspot_account.account_provider&.id,
        source: "coinspot",
        delete_future_holdings: false
      )
      nil
    rescue StandardError => e
      log_failure(symbol, e, asset)
    end

    def log_failure(symbol, error, asset = nil)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process CoinSpot holding#{" #{symbol}" if symbol.present?}: #{error.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_account.coinspot_item&.family,
        account_provider: coinspot_account.account_provider,
        metadata: { symbol: symbol, asset: asset, error_class: error.class.name }
      )
      { kind: "holding", symbol: symbol, error: error.message, error_class: error.class.name }
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Zeroes out every previously-imported CoinSpot-owned holding whose
    # security is no longer present in the latest balance snapshot -- the
    # snapshot omits zero balances entirely, so without this a sold or
    # transferred-away position would keep showing its last nonzero value
    # (and latest_provider_holdings_snapshot_date would keep resolving to
    # that stale snapshot indefinitely).
    def mark_absent_provider_holdings_zero!
      provider_link = coinspot_account.account_provider
      return unless provider_link

      present_security_ids = raw_assets.filter_map do |asset|
        symbol = asset["symbol"] || asset[:symbol]
        next if symbol.to_s.upcase == "AUD"
        next if symbol.blank?

        balance = (asset["balance"] || asset[:balance] || 0).to_d
        next if balance.zero?

        CoinspotAccount::SecurityResolver.resolve(symbol)&.id
      end.to_set

      previously_seen = account.holdings
        .where(account_provider_id: provider_link.id)
        .where.not(security_id: present_security_ids.to_a)
        .includes(:security)
        .to_a
        .uniq(&:security_id)

      previously_seen.each do |holding|
        import_adapter.import_holding(
          security: holding.security,
          quantity: 0,
          amount: 0,
          currency: target_currency,
          date: Date.current,
          price: 0,
          cost_basis: nil,
          external_id: "coinspot_absent_#{holding.security_id}_#{Date.current}",
          account_provider_id: provider_link.id,
          source: "coinspot",
          delete_future_holdings: false
        )
      end
    end

    # Logs when a holding's amount/price was converted from AUD using a rate
    # that wasn't for the exact requested date (or no rate at all).
    def log_stale_rate(symbol, field, rate_date)
      Rails.logger.warn(
        "CoinspotAccount::HoldingsProcessor - stale FX rate for #{field} symbol=#{symbol} rate_date=#{rate_date || "unknown"}"
      )
    end
end
