# frozen_string_literal: true

class KrakenAccount::Processor
  include KrakenAccount::UsdConverter

  attr_reader :kraken_account

  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    return unless kraken_account.current_account.present?

    KrakenAccount::HoldingsProcessor.new(kraken_account).process
    process_account!
    process_trades
    KrakenAccount::LedgerProcessor.new(kraken_account).process

    # The account was created, and anchored, before any of this history
    # existed. Now that it does, the anchor has to precede it.
    kraken_account.current_account.ensure_opening_anchor_precedes_entries
  end

  private

    def target_currency
      kraken_account.kraken_item&.family&.currency
    end

    def process_account!
      account = kraken_account.current_account
      amount, stale, rate_date = convert_from_usd((kraken_account.current_balance || 0).to_d, date: Date.current)

      account.update!(
        balance: amount,
        cash_balance: 0,
        currency: target_currency
      )

      kraken_account.update!(extra: kraken_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date, Date.current)))
    end

    def process_trades
      # Built per pass: one made before an earlier pass's inserts would miss
      # them, and import those trades twice.
      @existing_trade_entries = nil

      raw_trades.each do |txid, trade|
        process_trade(txid, trade)
      end
    rescue StandardError => e
      Rails.logger.error "KrakenAccount::Processor - trade processing failed: #{e.message}"
    end

    def raw_trades
      kraken_account.raw_transactions_payload&.dig("trades") || {}
    end

    def process_trade(txid, trade)
      account = kraken_account.current_account
      return unless account

      external_id = "kraken_trade_#{txid}"
      existing = existing_trade_entries[external_id]

      type = trade["type"].to_s.downcase
      return unless %w[buy sell].include?(type)

      pair = trade["pair"].to_s
      base_symbol, quote_symbol = infer_pair_symbols(pair, trade)
      return if base_symbol.blank?

      ledger_qty, ledger_cash = ledger_values_for(txid, base_symbol, quote_symbol)

      return reconcile_with_ledger(existing, txid, ledger_qty, ledger_cash, type, base_symbol, quote_symbol) if existing

      # `vol` is gross. When the fee is taken in the base asset -- an order-level
      # choice Kraken makes per fill -- the units that actually moved are fewer,
      # and TradesHistory gives no way to tell: it reports every fee converted to
      # the quote currency, with no fee-currency field. The ledger is where the
      # truth is, so prefer it and fall back to `vol`. A ledger net of zero is
      # an answer -- a small fill whose units all went on the fee -- and is
      # recorded, since its cash still moved.
      qty = ledger_qty || trade["vol"].to_d
      return if ledger_qty.nil? && qty.zero?

      price = trade["price"].to_d
      cost = trade["cost"].presence&.to_d
      cost ||= (qty * price).round(8)
      fee = trade["fee"].presence&.to_d || 0
      currency = quote_symbol.presence || "USD"
      date = Time.zone.at(trade["time"].to_d).to_date
      security = KrakenAccount::SecurityResolver.resolve(base_symbol)
      return unless security

      # Sure's convention is positive = money out, so a buy is +cost and a sell
      # -cost: the sign of the quantity, with Kraken's `cost` as the magnitude.
      # `cost` is the fill's actual cash figure and can differ from `vol * price`
      # by rounding, so it is kept rather than recomputed.
      trade_qty = type == "buy" ? qty : -qty
      # Same reasoning as the quantity: `cost` is what the fill was worth, not
      # what left the account. A fee charged in the quote currency comes out on
      # top of it, and the ledger's quote row nets the two already -- whichever
      # currency the fee was actually taken in.
      entry_amount = ledger_cash || (type == "buy" ? cost : -cost)
      label = type == "buy" ? "Buy" : "Sell"
      capture_partial_ledger(txid, ledger_qty, ledger_cash, base_symbol, quote_symbol)

      account.entries.create!(
        date: date,
        name: "#{label} #{qty.round(8)} #{base_symbol}",
        amount: entry_amount,
        currency: currency,
        external_id: external_id,
        source: "kraken",
        notes: trade["ordertxid"].presence,
        entryable: Trade.new(
          security: security,
          qty: trade_qty,
          price: price,
          currency: currency,
          fee: fee,
          investment_activity_label: label
        )
      )
    rescue StandardError => e
      Rails.logger.error "KrakenAccount::Processor - failed to process trade #{txid}: #{e.message}"
    end

    # A trade imported before its ledger rows were available -- before the API
    # key was granted "Query ledger entries", or before the ledger backfill
    # reached it -- holds TradesHistory's gross `vol` and `cost`. Once the rows
    # arrive, correct it from them, as a fresh import would have. Only what the
    # ledger answers is touched, an unchanged entry is not rewritten, and one the
    # user edited or locked is left alone.
    #
    # Each value is corrected on its own: a fee taken in the base asset leaves the
    # quote row equal to `cost`, and one taken in the quote leaves the base row
    # equal to `vol`, so a trade whose second row has not arrived yet is not made
    # any less right by taking the first.
    def reconcile_with_ledger(entry, txid, qty, cash, type, base_symbol, quote_symbol)
      # Checked before the entryable is touched, so a sync with no ledger rows
      # costs no query per trade.
      return if qty.nil? && cash.nil?
      return if entry.protected_from_sync?

      trade = entry.entryable
      return unless trade.is_a?(Trade)

      signed_qty = qty && (type == "buy" ? qty : -qty)

      qty_changed = signed_qty && signed_qty != trade.qty
      cash_changed = cash && cash != entry.amount
      return unless qty_changed || cash_changed

      capture_partial_ledger(txid, qty, cash, base_symbol, quote_symbol)

      label = type == "buy" ? "Buy" : "Sell"
      # Entry.transaction, not entry.transaction: delegated_type makes the
      # instance method the Transaction entryable accessor.
      Entry.transaction do
        trade.update!(qty: signed_qty) if qty_changed
        entry.update!(
          amount: cash_changed ? cash : entry.amount,
          name: qty_changed ? "#{label} #{qty.round(8)} #{base_symbol}" : entry.name
        )
      end
    end

    # Every existing trade entry for this payload, with its Trade, in one query
    # rather than two per fill.
    def existing_trade_entries
      @existing_trade_entries ||= begin
        external_ids = raw_trades.keys.map { |txid| "kraken_trade_#{txid}" }
        kraken_account.current_account.entries
          .where(source: "kraken", external_id: external_ids)
          .includes(:entryable)
          .index_by(&:external_id)
      end
    end

    # The ledger's quantity and cash for a trade, nil where it has no row.
    def ledger_values_for(txid, base_symbol, quote_symbol)
      [ ledger_qty_for(txid, base_symbol), ledger_cash_for(txid, quote_symbol) ]
    end

    # A trade moves two assets, so a ledger holding only one of its rows -- a
    # partial response, or the backfill's page cap falling between them --
    # leaves the trade half ledger, half TradesHistory. Recorded for support when
    # the trade is written, not on every sync that finds it unchanged.
    def capture_partial_ledger(txid, qty, cash, base_symbol, quote_symbol)
      return if qty.nil? == cash.nil?

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Kraken ledger has only the #{qty.nil? ? quote_symbol : base_symbol} row of trade #{txid}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_account.kraken_item&.family,
        metadata: { txid: txid.to_s, base: base_symbol, quote: quote_symbol, account_id: kraken_account.current_account&.id }
      )
    end

    # A trade's ledger rows carry its txid in `refid`, one row per asset moved.
    # The row for the base asset holds what was really received or given up:
    # Kraken applies `balance = previous + amount - fee`, so a fee charged in the
    # base asset is already netted out there and nowhere else.
    def ledger_qty_for(txid, base_symbol)
      row = ledger_row_for(txid, base_symbol)
      return nil if row.nil?

      (row["amount"].to_d - row["fee"].to_d).abs
    end

    # The quote-currency side of the same trade: what actually moved in or out of
    # the cash balance. Sure's sign convention is the ledger's inverted -- there a
    # buy shows the quote asset leaving as a negative amount; here money out is
    # positive.
    #
    # Rounded to what `entries.amount` stores: a crypto-quoted pair's ledger
    # carries more decimals than the column, and unrounded it would never equal
    # the stored figure, sending every unchanged trade down the update path on
    # every sync.
    def ledger_cash_for(txid, quote_symbol)
      return nil if quote_symbol.blank?

      row = ledger_row_for(txid, quote_symbol)
      return nil if row.nil?

      (-(row["amount"].to_d - row["fee"].to_d)).round(Entry.columns_hash["amount"].scale)
    end

    def ledger_row_for(txid, symbol)
      rows = ledgers_by_refid[txid.to_s]
      return nil if rows.blank?

      wanted = KrakenAccount::SecurityResolver.canonical_asset(symbol)
      rows.find { |ledger| KrakenAccount::SecurityResolver.canonical_asset(ledger["asset"]) == wanted }
    end

    def ledgers_by_refid
      @ledgers_by_refid ||= begin
        ledgers = kraken_account.raw_transactions_payload&.dig("ledgers") || {}
        ledgers.values.group_by { |ledger| ledger["refid"].to_s }
      end
    end

    def infer_pair_symbols(pair, trade)
      pair_metadata = kraken_account.raw_payload&.dig("pair_metadata") || {}
      metadata = pair_metadata[pair] || pair_metadata.values.find { |candidate| candidate["altname"].to_s == pair }
      normalizer = KrakenAccount::AssetNormalizer.new(kraken_account.raw_payload&.dig("asset_metadata") || {})

      if metadata
        base = normalizer.normalize(metadata["base"])[:symbol]
        quote = normalizer.normalize(metadata["quote"])[:symbol]
        return [ base, quote ]
      end

      altname = trade["pair"].to_s
      %w[USDT USDC USD EUR GBP BTC ETH].each do |quote|
        next unless altname.end_with?(quote)

        return [ normalizer.normalize(altname.delete_suffix(quote))[:symbol], quote ]
      end

      [ altname, "USD" ]
    end
end
