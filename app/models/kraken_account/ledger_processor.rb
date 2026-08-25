# frozen_string_literal: true

# Processes Kraken Ledger entries (deposits, withdrawals, staking rewards, Earn
# income, standalone fees) stored in KrakenAccount#raw_transactions_payload["ledgers"].
#
# Kraken TradesHistory already handles spot buy/sell trades; ledger entries with
# type="trade" are therefore skipped here to avoid double-counting.  Internal
# sub-account transfers (type="transfer") and margin events (type="margin",
# "rollover", "settled") are also skipped.
#
# Sign convention (Sure): negative = inflow/income, positive = outflow/expense.
# Deposits and rewards are negative; withdrawals and fees are positive.
class KrakenAccount::LedgerProcessor
  include KrakenAccount::UsdConverter

  # Ledger types we import as Transaction entries.
  SUPPORTED_TYPES = %w[deposit withdrawal staking earn fee].freeze

  # Ledger types we intentionally ignore (handled elsewhere or out of scope).
  SKIP_TYPES = %w[trade transfer margin rollover settled adjustment].freeze

  # Kraken Earn internal subtypes that represent fund movements, not income.
  EARN_INTERNAL_SUBTYPES = %w[allocation deallocation].freeze

  def initialize(kraken_account)
    @kraken_account = kraken_account
    @normalizer = KrakenAccount::AssetNormalizer.new(raw_payload&.dig("asset_metadata") || {})
  end

  def process
    return unless account.present?

    # Idempotency: load existing Kraken *ledger* external IDs once and test
    # membership in memory, instead of an EXISTS query per ledger entry (a full
    # sync can carry up to ~10k entries — see MAX_LEDGER_PAGES in the importer).
    # Scoped to the kraken_ledger_ prefix so trade entries aren't loaded.
    @existing_external_ids = account.entries
                                    .where(source: "kraken")
                                    .where("external_id LIKE 'kraken_ledger_%'")
                                    .pluck(:external_id)
                                    .to_set

    raw_ledgers.each do |ledger_id, ledger|
      process_ledger_entry(ledger_id, ledger)
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process ledger entry #{ledger_id}: #{e.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_account.kraken_item&.family,
        metadata: { ledger_id: ledger_id, error_class: e.class.name }
      )
    end
  end

  private

    attr_reader :kraken_account, :normalizer

    def account
      kraken_account.current_account
    end

    def target_currency
      kraken_account.kraken_item&.family&.currency
    end

    def raw_payload
      kraken_account.raw_payload
    end

    def raw_ledgers
      kraken_account.raw_transactions_payload&.dig("ledgers") || {}
    end

    def process_ledger_entry(ledger_id, ledger)
      type    = ledger["type"].to_s.downcase
      subtype = ledger["subtype"].to_s.downcase

      return if SKIP_TYPES.include?(type)
      return unless SUPPORTED_TYPES.include?(type)

      # Skip Earn allocation/deallocation — these are internal fund movements, not income.
      return if type == "earn" && EARN_INTERNAL_SUBTYPES.include?(subtype)

      external_id = "kraken_ledger_#{ledger_id}"
      return if @existing_external_ids.include?(external_id)

      raw_asset  = ledger["asset"].to_s
      raw_amount = ledger["amount"].to_d
      raw_fee    = ledger["fee"].to_d
      date       = Time.zone.at(ledger["time"].to_d).to_date

      # Compute the total balance impact: Kraken applies amount - fee to the balance.
      # abs_impact captures the full magnitude of the cash movement for this event.
      abs_impact = (raw_amount - raw_fee).abs
      return if abs_impact.zero?

      normalized = normalizer.normalize(raw_asset)
      symbol     = normalized[:symbol]

      entry_amount, price_missing = resolve_amount(abs_impact, symbol, date)
      return if entry_amount.nil?

      # Sure sign convention: inflow = negative, outflow = positive.
      signed_amount = inflow?(type) ? -entry_amount.abs : entry_amount.abs

      name  = build_name(type, abs_impact, symbol)
      label = activity_label(type)
      kind  = transaction_kind(type)
      extra = build_extra(ledger_id, ledger, raw_asset, price_missing)

      account.entries.create!(
        date: date,
        name: name,
        amount: signed_amount,
        currency: target_currency,
        external_id: external_id,
        source: "kraken",
        entryable: Transaction.new(
          kind: kind,
          investment_activity_label: label,
          extra: extra
        )
      )

      @existing_external_ids << external_id
    end

    # Returns [family_currency_amount, price_missing_bool] or [nil, nil] on hard failure.
    def resolve_amount(abs_impact, symbol, date)
      return [ abs_impact, false ] if symbol == target_currency

      if KrakenAccount::FIAT_CURRENCIES.include?(symbol)
        resolve_fiat_amount(abs_impact, symbol, date)
      else
        resolve_crypto_amount(abs_impact, symbol, date)
      end
    end

    def resolve_fiat_amount(abs_impact, symbol, date)
      if symbol == "USD"
        converted, stale, = convert_from_usd(abs_impact, date: date)
        return [ converted, stale ]
      end

      # Non-USD fiat: bridge through USD
      rate_to_usd = ExchangeRate.find_or_fetch_rate(from: symbol, to: "USD", date: date)
      return [ nil, nil ] unless rate_to_usd

      usd_amount = abs_impact * rate_to_usd.rate.to_d
      converted, stale, = convert_from_usd(usd_amount, date: date)
      [ converted, stale ]
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Fiat rate fetch failed for #{symbol}: #{e.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_account.kraken_item&.family,
        metadata: { symbol: symbol, date: date.to_s, error_class: e.class.name }
      )
      [ nil, nil ]
    end

    def resolve_crypto_amount(abs_impact, symbol, date)
      price_usd = stored_price_usd(symbol)

      if price_usd.nil?
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "No price available for #{symbol} on #{date}; amount recorded as 0",
          source: self.class.name,
          provider_key: "kraken",
          family: kraken_account.kraken_item&.family,
          metadata: { symbol: symbol, date: date.to_s }
        )
        return [ 0.to_d, true ]
      end

      usd_amount = abs_impact * price_usd
      converted, stale, = convert_from_usd(usd_amount, date: date)
      [ converted, stale ]
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Crypto price resolution failed for #{symbol}: #{e.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_account.kraken_item&.family,
        metadata: { symbol: symbol, date: date.to_s, error_class: e.class.name }
      )
      [ 0.to_d, true ]
    end

    # Use the current spot price cached in raw_payload["assets"] by the Importer.
    # This is the price at last sync time, not at entry date — a best-effort
    # approximation; precise historical pricing is a future enhancement.
    def stored_price_usd(symbol)
      assets = raw_payload&.dig("assets") || []
      asset  = assets.find do |a|
        (a["symbol"] || a[:symbol]).to_s.upcase == symbol.upcase
      end
      price = asset&.dig("price_usd") || asset&.dig(:price_usd)
      price.present? ? price.to_d : nil
    end

    # True when the ledger event represents money flowing INTO the account.
    def inflow?(type)
      case type
      when "deposit", "staking", "earn" then true
      when "withdrawal", "fee"          then false
      else false
      end
    end

    def build_name(type, abs_impact, symbol)
      qty = abs_impact.to_d.round(8).to_s("F").sub(/\.?0+\z/, "")
      case type
      when "deposit"    then "Deposit #{qty} #{symbol}"
      when "withdrawal" then "Withdrawal #{qty} #{symbol}"
      when "staking"    then "Staking reward #{qty} #{symbol}"
      when "earn"       then "Earn reward #{qty} #{symbol}"
      when "fee"        then "Fee #{qty} #{symbol}"
      else "#{type.capitalize} #{qty} #{symbol}"
      end
    end

    def activity_label(type)
      case type
      when "deposit"    then "Contribution"
      when "withdrawal" then "Withdrawal"
      when "staking"    then "Dividend"
      when "earn"       then "Interest"
      when "fee"        then "Fee"
      end
    end

    def transaction_kind(type)
      case type
      when "deposit", "withdrawal" then "funds_movement"
      else "standard"
      end
    end

    def build_extra(ledger_id, ledger, raw_asset, price_missing)
      meta = {
        "ledger_id"  => ledger_id,
        "refid"      => ledger["refid"],
        "raw_asset"  => raw_asset,
        "raw_amount" => ledger["amount"],
        "fee_native" => ledger["fee"],
        "type"       => ledger["type"],
        "subtype"    => ledger["subtype"]
      }
      meta["price_missing"] = true if price_missing
      { "kraken" => meta }
    end
end
