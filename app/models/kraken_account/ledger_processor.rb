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

  # Types whose fee is charged on top of a movement with an external counterparty,
  # and so must stay a separate entry for transfer matching to work.
  SPLIT_FEE_TYPES = %w[deposit withdrawal].freeze

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
      # Already in, and nothing more to add for it: skip before any parsing. A
      # split-fee type is the exception, checked further down once the fee is
      # known -- its second entry may still be owed.
      return if @existing_external_ids.include?(external_id) && !SPLIT_FEE_TYPES.include?(type)

      raw_asset  = ledger["asset"].to_s
      raw_amount = ledger["amount"].to_d
      raw_fee    = ledger["fee"].to_d
      date       = Time.zone.at(ledger["time"].to_d).to_date

      # Kraken applies amount - fee to the balance, and reports the two separately.
      # Deposits and withdrawals are emitted as two entries so the movement keeps the
      # figure the counterparty actually sees: a bank records the transfer net of
      # Kraken's fee, and Transfer requires both legs to sum to zero, so folding the
      # fee in here makes the entry permanently unmatchable. Other ledger types have
      # no counterparty to reconcile against and keep the combined figure.
      split_fee = SPLIT_FEE_TYPES.include?(type) && !raw_fee.zero?
      abs_impact = split_fee ? raw_amount.abs : (raw_amount - raw_fee).abs

      normalized = normalizer.normalize(raw_asset)
      symbol     = normalized[:symbol]

      # The principal is in from an earlier pass, or there is none: a correction
      # row can carry a fee against a zero amount. Either way the fee is checked
      # on its own external_id, so a later sync can still create the missing
      # half -- pricing it can fail on one sync and succeed on the next --
      # without duplicating the one it has.
      if abs_impact.zero? || @existing_external_ids.include?(external_id)
        if split_fee && principal_awaits_fee?(external_id, raw_amount, raw_fee, symbol, date)
          process_ledger_fee(external_id, ledger_id, ledger, raw_fee, symbol, date)
        end
        return
      end

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

      process_ledger_fee(external_id, ledger_id, ledger, raw_fee, symbol, date) if split_fee
    end

    # Kraken's fee is always a cost, so it is an outflow whichever way the principal
    # moved. Its own external_id keeps it idempotent alongside the principal entry.
    # An entry written before fees were split holds the fee inside it: adding the
    # fee entry now would charge it twice. Only a principal already standing on
    # its own is owed one -- which happens when pricing the fee failed on an
    # earlier sync. Told apart by which of the two figures the stored amount is
    # nearer to, so a rate that has moved since cannot turn one into the other,
    # and ties go to leaving it alone.
    def principal_awaits_fee?(external_id, raw_amount, raw_fee, symbol, date)
      entry = account.entries.find_by(external_id: external_id)
      return true if entry.nil? # no principal at all: a correction row carrying only a fee
      return false if entry.user_modified?

      split, = resolve_amount(raw_amount.abs, symbol, date)
      legacy, = resolve_amount((raw_amount - raw_fee).abs, symbol, date)
      return false if split.nil? || legacy.nil?

      stored = entry.amount.abs
      (stored - split.abs).abs < (stored - legacy.abs).abs
    end

    def process_ledger_fee(principal_external_id, ledger_id, ledger, raw_fee, symbol, date)
      fee_external_id = "#{principal_external_id}_fee"
      return if @existing_external_ids.include?(fee_external_id)

      fee_amount, price_missing = resolve_amount(raw_fee.abs, symbol, date)
      return if fee_amount.nil? || fee_amount.zero?

      account.entries.create!(
        date: date,
        name: build_name("fee", raw_fee.abs, symbol),
        amount: fee_amount.abs,
        currency: target_currency,
        external_id: fee_external_id,
        source: "kraken",
        entryable: Transaction.new(
          kind: transaction_kind("fee"),
          investment_activity_label: activity_label("fee"),
          extra: build_extra(ledger_id, ledger, ledger["asset"].to_s, price_missing)
        )
      )

      @existing_external_ids << fee_external_id
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
