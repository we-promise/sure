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
      return if account.entries.exists?(external_id: external_id, source: "kraken")

      type = trade["type"].to_s.downcase
      return unless %w[buy sell].include?(type)

      pair = trade["pair"].to_s
      base_symbol, quote_symbol = infer_pair_symbols(pair, trade)
      return if base_symbol.blank?

      # `vol` is gross. When the fee is taken in the base asset -- an order-level
      # choice Kraken makes per fill -- the units that actually moved are fewer,
      # and TradesHistory gives no way to tell: it reports every fee converted to
      # the quote currency, with no fee-currency field. The ledger is where the
      # truth is, so prefer it and fall back to `vol`.
      qty = ledger_qty_for(txid, base_symbol) || trade["vol"].to_d
      return if qty.zero?

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
      entry_amount = type == "buy" ? cost : -cost
      label = type == "buy" ? "Buy" : "Sell"

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

    # A trade's ledger rows carry its txid in `refid`, one row per asset moved.
    # The row for the base asset holds what was really received or given up:
    # Kraken applies `balance = previous + amount - fee`, so a fee charged in the
    # base asset is already netted out there and nowhere else.
    def ledger_qty_for(txid, base_symbol)
      rows = ledgers_by_refid[txid.to_s]
      return nil if rows.blank?

      wanted = KrakenAccount::SecurityResolver.canonical_asset(base_symbol)
      row = rows.find do |ledger|
        KrakenAccount::SecurityResolver.canonical_asset(ledger["asset"]) == wanted
      end
      return nil if row.nil?

      net = (row["amount"].to_d - row["fee"].to_d).abs
      net.zero? ? nil : net
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
