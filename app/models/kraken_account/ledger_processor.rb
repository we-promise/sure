# frozen_string_literal: true

# Processes Kraken Ledger entries (deposits, withdrawals, staking rewards, Earn
# income, standalone fees) stored in KrakenAccount#raw_transactions_payload["ledgers"].
#
# Kraken TradesHistory already handles spot buy/sell trades; ledger entries with
# type="trade" are therefore skipped here to avoid double-counting.  Internal
# sub-account transfers (type="transfer") and margin events (type="margin",
# "rollover", "settled") are also skipped.
#
# Fiat entries are cash and become Transactions, with Sure's sign convention:
# negative = inflow/income, positive = outflow/expense, so deposits and rewards
# are negative and withdrawals and fees positive.
#
# Crypto entries are not cash. They move units, so they become Trades carrying a
# quantity and the price on the day, with a zero amount -- see
# process_crypto_ledger_entry.
class KrakenAccount::LedgerProcessor
  include KrakenAccount::UsdConverter

  # Ledger types we import.
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
    # The name comes along so a principal already holding its fee can be told
    # from one still owed it, without a lookup per ledger row.
    existing = account.entries
                      .where(source: "kraken")
                      .where("external_id LIKE 'kraken_ledger_%'")
                      .pluck(:external_id, :name, :user_modified)
    @existing_external_ids = existing.map(&:first).to_set
    @existing_principals = existing.to_h { |external_id, name, user_modified| [ external_id, [ name, user_modified ] ] }

    warm_crypto_prices

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
      normalized  = normalizer.normalize(raw_asset)
      symbol      = normalized[:symbol]
      base_symbol = normalized[:price_symbol]
      fiat        = fiat?(base_symbol)

      # A crypto fee is paid in the units themselves, so it only reduces the
      # quantity; there is no second cash movement to split out.
      split_fee = fiat && SPLIT_FEE_TYPES.include?(type) && !raw_fee.zero?
      abs_impact = split_fee ? raw_amount.abs : (raw_amount - raw_fee).abs

      unless fiat
        process_crypto_ledger_entry(
          external_id: external_id, ledger_id: ledger_id, ledger: ledger, type: type,
          raw_asset: raw_asset, base_symbol: base_symbol, symbol: symbol,
          qty: abs_impact, date: date
        )
        return
      end

      # The principal is in from an earlier pass, or there is none: a correction
      # row can carry a fee against a zero amount. Either way the fee is checked
      # on its own external_id, so a later sync can still create the missing
      # half -- pricing it can fail on one sync and succeed on the next --
      # without duplicating the one it has.
      if abs_impact.zero? || @existing_external_ids.include?(external_id)
        if split_fee && !@existing_external_ids.include?("#{external_id}_fee") &&
           principal_awaits_fee?(external_id, raw_amount, symbol)
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

    # Crypto moves units, not cash. A staking reward does not put euros in the
    # account -- it puts coins in it -- and a deposit or withdrawal of coin is a
    # position change with no cash leg at all. Recorded as a Transaction the
    # quantity is lost entirely, so Holding::ReverseCalculator has nothing to
    # reverse and carries today's position backwards through history, while the
    # cash balance moves by an amount that never existed.
    #
    # `amount` is deliberately zero: Balance::BaseCalculator classifies a trade by
    # its amount regardless of label, so anything else would reintroduce the
    # phantom cash. The units and their price carry the value instead.
    def process_crypto_ledger_entry(external_id:, ledger_id:, ledger:, type:, raw_asset:, base_symbol:, symbol:, qty:, date:)
      security = resolve_security(base_symbol)
      return unless security

      price, price_missing = unit_price_on(security, base_symbol, date)
      signed_qty = inflow?(type) ? qty.abs : -qty.abs

      account.entries.create!(
        date: date,
        name: build_name(type, qty, symbol),
        amount: 0,
        currency: target_currency,
        external_id: external_id,
        source: "kraken",
        entryable: Trade.new(
          security: security,
          qty: signed_qty,
          price: price,
          currency: target_currency,
          investment_activity_label: crypto_activity_label(type),
          extra: build_extra(ledger_id, ledger, raw_asset, price_missing)
        )
      )

      @existing_external_ids << external_id
    end

    # A coin arriving from outside has a cost nothing here knows, so it is a
    # Transfer and the basis becomes unknown from that date -- the same treatment
    # an inbound share transfer already gets. A reward is acquired at the market
    # price on the day, which is both its basis and the income it represents.
    def crypto_activity_label(type)
      case type
      when "deposit", "withdrawal" then Trade::TRANSFER_LABEL
      when "staking"               then "Dividend"
      when "earn"                  then "Interest"
      when "fee"                   then "Fee"
      end
    end

    def fiat?(base_symbol)
      KrakenAccount::FIAT_CURRENCIES.include?(base_symbol.to_s.upcase)
    end

    # One bulk request per asset for the span the ledger covers, the same call
    # MarketDataImporter makes, so that the per-entry lookup below is a
    # database read. Left to find_or_fetch_price it was one provider request
    # per entry -- thousands on a first import.
    def warm_crypto_prices
      spans = {}
      raw_ledgers.each_value do |ledger|
        next unless SUPPORTED_TYPES.include?(ledger["type"].to_s.downcase)

        base_symbol = normalizer.normalize(ledger["asset"].to_s)[:price_symbol]
        next if base_symbol.blank? || fiat?(base_symbol)

        date = Time.zone.at(ledger["time"].to_d).to_date
        span = (spans[base_symbol] ||= [ date, date ])
        span[0] = date if date < span[0]
        span[1] = date if date > span[1]
      end

      spans.each do |base_symbol, (from, to)|
        security = resolve_security(base_symbol)
        security&.import_provider_prices(start_date: from, end_date: to)
      rescue StandardError => e
        Rails.logger.warn "KrakenAccount::LedgerProcessor - could not warm prices for #{base_symbol}: #{e.message}"
      end
    end

    def resolve_security(base_symbol)
      KrakenAccount::SecurityResolver.resolve("CRYPTO:#{base_symbol}", base_symbol)
    end

    # The price on the day the units moved, not the price today. Falls back to
    # the balance snapshot's price, which is what the whole processor used to
    # use, and flags the entry so the staleness is visible in `extra`.
    def unit_price_on(security, base_symbol, date)
      price = security.prices.find_by(date: date)
      if price&.price.present?
        converted = Money.new(price.price, price.currency).exchange_to(target_currency).amount
        return [ converted, false ]
      end

      fallback, = resolve_amount(1.to_d, base_symbol, date)
      [ fallback || 0, true ]
    rescue StandardError
      fallback, = resolve_amount(1.to_d, base_symbol, date)
      [ fallback || 0, true ]
    end

    # Kraken's fee is always a cost, so it is an outflow whichever way the principal
    # moved. Its own external_id keeps it idempotent alongside the principal entry.
    # An entry written before fees were split holds the fee inside it: adding the
    # fee entry now would charge it twice. Only a principal already standing on
    # its own is owed one -- which happens when pricing the fee failed on an
    # earlier sync. The two are told apart by the native quantity the entry was
    # charged, which its name carries. Not by the stored amount: a crypto row is
    # converted at the current spot price, so recomputing it later scales the
    # candidates while the stored figure stays where it was, and after any real
    # price move nearness decides nothing.
    def principal_awaits_fee?(external_id, raw_amount, symbol)
      stored_name, user_modified = @existing_principals[external_id]
      return true if stored_name.nil? # no principal at all: a correction row carrying only a fee
      return false if user_modified

      charged = charged_quantity(stored_name, symbol)
      return false if charged.nil?

      charged == raw_amount.abs.round(8)
    end

    # The quantity out of "Withdrawal 0.501 BTC", compared as a number so a name
    # written when the formatting differed -- "500.0" against today's "500" --
    # still reads. Nil unless the name is one this class built for this symbol,
    # which leaves a renamed entry alone.
    def charged_quantity(name, symbol)
      parts = name.to_s.split(" ")
      return nil unless parts.length >= 3 && parts.last == symbol

      BigDecimal(parts[-2], exception: false)&.round(8)
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
