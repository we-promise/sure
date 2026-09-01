# frozen_string_literal: true

class CoinspotAccount::HoldingsProcessor
  include CoinspotAccount::AudConverter

  # Initializes with the CoinspotAccount whose latest balance snapshot
  # (raw_payload) will be turned into holdings.
  def initialize(coinspot_account)
    @coinspot_account = coinspot_account
  end

  # Imports every non-AUD asset in the account's latest balance snapshot as a
  # holding, then zeroes out any previously-imported holding whose security
  # is absent from that snapshot (sold/transferred away entirely). No-op for
  # accounts not yet linked to a Crypto Sure account. Swallows errors rather
  # than raising so one bad snapshot doesn't abort the wider sync.
  def process
    return unless account&.accountable_type == "Crypto"

    raw_assets.each { |asset| process_asset(asset) }
    mark_absent_provider_holdings_zero!
  rescue StandardError => e
    Rails.logger.error "CoinspotAccount::HoldingsProcessor - error: #{e.message}"
    nil
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

    # The `assets` array from the account's last-synced balance snapshot.
    def raw_assets
      coinspot_account.raw_payload&.dig("assets") || []
    end

    # Resolves one raw balance-snapshot asset to a Security and imports it as
    # a holding for today. Skips AUD (cash, not a holding) and anything
    # missing a symbol, balance, or AUD amount. A single asset's failure is
    # logged and skipped rather than aborting the rest of the snapshot.
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
    rescue StandardError => e
      Rails.logger.error "CoinspotAccount::HoldingsProcessor - failed asset symbol=#{symbol.presence || "unknown"}: #{e.message}"
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
