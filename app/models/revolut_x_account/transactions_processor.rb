# frozen_string_literal: true

# Maps the rows RevolutXItem::Importer stored in raw_transactions_payload to
# entries. Coins move units, so every crypto leg becomes a Trade: a buy or
# sell carries its fiat leg as the amount, and any other movement has no cash
# side and is an amount-0 Trade priced at that day's stored price (as
# KrakenAccount::LedgerProcessor records ledger movements). A crypto-to-crypto
# swap is a Sell and a Buy when both coins have a price that day, else a
# Sweep Out and Sweep In, so an unknown value books no gain or loss. Fiat
# moving on its own is cash and becomes a Transaction (negative = inflow).
#
# Amounts are the net leg amounts of the list endpoint; fees are not itemized.
# import_transaction gives a Contribution the investment_contribution kind,
# as it does for every investment provider.
class RevolutXAccount::TransactionsProcessor
  SOURCE = "revolut_x"
  VOID_STATUSES = %w[cancelled failed reverted].freeze
  ENTRY_SUFFIXES = [ "", "_funding", "_in", "_out" ].freeze

  def initialize(revolut_x_account)
    @revolut_x_account = revolut_x_account
  end

  def process
    return unless account && history_complete?

    warm_prices
    rows.each do |row|
      next if held_back?(row)

      process_row(row)
    rescue StandardError => e
      report("Revolut X transaction #{row["id"]} not imported: #{e.message}", row, level: "error")
      # Writing later rows would put them ahead of this one in the replay
      # order, so the run stops here and the sync records the failure.
      raise
    end
  end

  private

    attr_reader :revolut_x_account

    def account
      revolut_x_account.current_account
    end

    def item
      revolut_x_account.revolut_x_item
    end

    def family_currency
      item.family.currency
    end

    # Writes only after a walk that fetched every window: a cut walk stores
    # the newer part of a day first, and rows written in a later run get a
    # later created_at, so a same-day buy would then replay after its sell.
    def history_complete?
      synced_through = item.transactions_synced_through
      fetched_at = revolut_x_account.raw_transactions_payload.to_h["fetched_at"]
      synced_through.present? && (fetched_at.blank? || Time.iso8601(fetched_at) <= synced_through)
    end

    # Oldest first: holdings replay trades by (date, created_at), so a same-day
    # buy must be written before the sell it funds.
    def rows
      @rows ||= revolut_x_account.raw_transactions_payload.to_h.fetch("transactions", {}).values
        .sort_by { |row| order_key(row) }
    end

    def order_key(row)
      [ row["created_date"].to_i, row["id"].to_s ]
    end

    # A pending trade row is written in the sync where it completes, so a
    # later same-day trade written before it would replay ahead of it. Such a
    # trade waits, and the day is written in one run once the pending row
    # resolves.
    def held_back?(row)
      return false unless row["status"] == "completed" && trade_row?(row)

      first_pending = first_pending_trade_by_date[entry_date(row)]
      first_pending.present? && (order_key(row) <=> first_pending).positive?
    end

    def first_pending_trade_by_date
      @first_pending_trade_by_date ||= rows.select { |row| pending?(row) && trade_row?(row) }
        .each_with_object({}) { |row, firsts| firsts[entry_date(row)] ||= order_key(row) }
    end

    # Rows that write a Trade: a mapped type with a crypto leg.
    def trade_row?(row)
      %w[buy sell receive send reward].include?(row["type"]) &&
        [ row["source"], row["destination"] ].any? { |leg| leg.is_a?(Hash) && !item.fiat_currency?(leg["currency"]) }
    end

    # stake and un_stake map to nothing: the balance total already includes
    # staked units, so they move nothing Sure tracks.
    def process_row(row)
      return void_entries(row) if VOID_STATUSES.include?(row["status"])
      return unless %w[pending completed].include?(row["status"])

      case row["type"]
      when "buy", "sell"
        process_exchange(row)
      when "receive"
        process_movement(row, row["destination"], inflow: true, cash_label: "Contribution", crypto_label: Trade::TRANSFER_LABEL, kind: "funds_movement")
      when "send"
        process_movement(row, row["source"], inflow: false, cash_label: "Withdrawal", crypto_label: Trade::TRANSFER_LABEL, kind: "funds_movement")
      when "reward"
        process_movement(row, row["destination"], inflow: true, cash_label: "Dividend", crypto_label: "Dividend", kind: "standard")
      end
    end

    def process_movement(row, leg, inflow:, cash_label:, crypto_label:, kind:)
      qty = leg_amount(leg)
      return if qty.zero?

      symbol = leg["currency"].to_s.upcase
      name = "#{row["type"].capitalize} #{format_qty(qty)} #{symbol}"

      if item.fiat_currency?(symbol)
        write_transaction(row, "", amount: inflow ? -qty : qty, currency: symbol, kind: kind, label: cash_label, name: name)
      elsif !pending?(row) # Sure has no pending Trade; it is written once completed.
        security = resolve_security(symbol, row)
        return unless security

        write_unpriced_trade(row, "", security: security, price: stored_price(security, entry_date(row)),
                             qty: inflow ? qty : -qty, label: crypto_label, name: name)
      end
    end

    # The direction comes from which leg is fiat, not from the type.
    def process_exchange(row)
      return if pending?(row)

      source, destination = row["source"], row["destination"]
      source_qty, destination_qty = leg_amount(source), leg_amount(destination)
      return report_unmapped(row) if source_qty.zero? || destination_qty.zero?

      source_symbol = source["currency"].to_s.upcase
      destination_symbol = destination["currency"].to_s.upcase
      source_fiat = item.fiat_currency?(source_symbol)
      destination_fiat = item.fiat_currency?(destination_symbol)

      if source_fiat && !destination_fiat && here?(destination)
        write_exchange_trade(row, symbol: destination_symbol, qty: destination_qty, cash: source_qty, currency: source_symbol, label: "Buy")
        unless here?(source)
          write_transaction(row, "_funding", amount: -source_qty, currency: source_symbol, kind: "funds_movement",
                            label: "Contribution", name: "Deposit #{format_qty(source_qty)} #{source_symbol}")
        end
      elsif !source_fiat && destination_fiat && here?(source)
        write_exchange_trade(row, symbol: source_symbol, qty: -source_qty, cash: -destination_qty, currency: destination_symbol, label: "Sell")
        unless here?(destination)
          write_transaction(row, "_funding", amount: destination_qty, currency: destination_symbol, kind: "funds_movement",
                            label: "Withdrawal", name: "Withdrawal #{format_qty(destination_qty)} #{destination_symbol}")
        end
      elsif !source_fiat && !destination_fiat && here?(source) && here?(destination)
        process_crypto_swap(row, source_symbol, source_qty, destination_symbol, destination_qty)
      else
        report_unmapped(row)
      end
    end

    # Both legs are amount-0 Trades priced on the day. Without both prices the
    # swap's value is unknown, so the pair is a sweep (an internal movement):
    # a Sell at price 0 would book the whole out leg as a realized loss.
    def process_crypto_swap(row, source_symbol, source_qty, destination_symbol, destination_qty)
      date = entry_date(row)
      out_security = resolve_security(source_symbol, row)
      in_security = resolve_security(destination_symbol, row)
      out_price = out_security && stored_price(out_security, date)
      in_price = in_security && stored_price(in_security, date)
      out_label, in_label = out_price && in_price ? %w[Sell Buy] : [ "Sweep Out", "Sweep In" ]

      if out_security
        write_unpriced_trade(row, "_out", security: out_security, price: out_price, qty: -source_qty,
                             label: out_label, name: "Sell #{format_qty(source_qty)} #{source_symbol}")
      end
      if in_security
        write_unpriced_trade(row, "_in", security: in_security, price: in_price, qty: destination_qty,
                             label: in_label, name: "Buy #{format_qty(destination_qty)} #{destination_symbol}")
      end
    end

    # A buy or sell: the fiat leg is the trade's amount, and sets its price.
    def write_exchange_trade(row, symbol:, qty:, cash:, currency:, label:)
      security = resolve_security(symbol, row)
      return unless security

      write_trade(row, "", security: security, qty: qty, amount: cash, currency: currency, price: (cash / qty).abs,
                  label: label, name: "#{label} #{format_qty(qty.abs)} #{symbol}")
    end

    # A crypto movement with no cash side. amount stays 0, because the balance
    # calculator reads a trade's amount as cash; the units and the price on the
    # day carry the value.
    def write_unpriced_trade(row, suffix, security:, price:, qty:, label:, name:)
      write_trade(row, suffix, security: security, qty: qty, amount: 0, currency: family_currency, price: price || 0,
                  label: label, name: name, price_missing: price.nil?)
    end

    def write_trade(row, suffix, security:, qty:, amount:, currency:, price:, label:, name:, price_missing: false)
      entry = account.entries.find_or_initialize_by(external_id: external_id(row, suffix), source: SOURCE) do |new_entry|
        new_entry.entryable = Trade.new
      end
      return if entry.persisted? && entry.protected_from_sync?

      entry.entryable.assign_attributes(
        security: security,
        qty: qty,
        price: price,
        currency: currency,
        investment_activity_label: label,
        extra: extra(row, price_missing: price_missing)
      )
      entry.assign_attributes(date: entry_date(row), amount: amount, currency: currency, name: name)
      entry.save!
    end

    def write_transaction(row, suffix, amount:, currency:, kind:, label:, name:)
      import_adapter.import_transaction(
        external_id: external_id(row, suffix),
        amount: amount,
        currency: currency,
        date: entry_date(row),
        name: name,
        source: SOURCE,
        kind: kind,
        investment_activity_label: label,
        extra: extra(row),
        replace_extra_namespaces: [ SOURCE ],
        # Each row has its own id; an amount/date match would let one row claim another's entry.
        allow_heuristic_matching: false
      )
    end

    # A row that did not go through takes back whatever an earlier sync wrote
    # for it, while it was pending or before it was reverted.
    def void_entries(row)
      ids = ENTRY_SUFFIXES.map { |suffix| external_id(row, suffix) }
      account.entries.where(source: SOURCE, external_id: ids).find_each do |entry|
        entry.destroy! unless entry.protected_from_sync?
      end
    end

    # One bulk price request per coin over the payload's date span, so the
    # per-row price lookup is a database read.
    def warm_prices
      spans = {}
      rows.each do |row|
        next unless row["status"] == "completed"

        date = entry_date(row)
        [ row["source"], row["destination"] ].each do |leg|
          symbol = leg.is_a?(Hash) ? leg["currency"].to_s.upcase : nil
          next if symbol.blank? || item.fiat_currency?(symbol)

          span = (spans[symbol] ||= [ date, date ])
          span[0] = date if date < span[0]
          span[1] = date if date > span[1]
        end
      end

      spans.each do |symbol, (from, to)|
        Onchain::SecurityResolver.resolve(symbol: symbol)&.import_provider_prices(start_date: from, end_date: to)
      rescue StandardError => e
        Rails.logger.warn "RevolutXAccount::TransactionsProcessor - could not warm prices for #{symbol}: #{e.message}"
      end
    end

    def stored_price(security, date)
      price = security.prices.find_by(date: date)
      return nil if price&.price.blank?

      Money.new(price.price, price.currency).exchange_to(family_currency, date: date).amount
    rescue Money::ConversionError
      nil
    end

    def resolve_security(symbol, row)
      security = Onchain::SecurityResolver.resolve(symbol: symbol, name: item.raw_payload.to_h.dig("currencies", symbol, "name"))
      report("Revolut X transaction #{row["id"]} not imported: #{symbol} is not a supported asset", row) unless security
      security
    end

    def report_unmapped(row)
      report("Revolut X #{row["type"]} #{row["id"]} not imported: no crypto leg in this account", row)
    end

    def report(message, row, level: "warn")
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: SOURCE,
        family: item.family,
        account_provider: revolut_x_account.account_provider,
        metadata: { revolut_x_item_id: item.id, transaction_id: row["id"], type: row["type"], status: row["status"] }
      )
    end

    def extra(row, price_missing: false)
      meta = {
        "transaction_id" => row["id"],
        "type" => row["type"],
        "status" => row["status"],
        "source_account_type" => row.dig("source", "account", "type"),
        "destination_account_type" => row.dig("destination", "account", "type")
      }
      meta["pending"] = true if pending?(row)
      meta["price_missing"] = true if price_missing
      { SOURCE => meta }
    end

    # A leg with no account type is this account's own.
    def here?(leg)
      [ nil, "revolut_x" ].include?(leg.dig("account", "type"))
    end

    def leg_amount(leg)
      leg.is_a?(Hash) ? leg["amount"].to_d.abs : 0.to_d
    end

    def pending?(row)
      row["status"] == "pending"
    end

    def entry_date(row)
      Time.zone.at(row["created_date"].to_i / 1000r).to_date
    end

    def external_id(row, suffix)
      "revolut_x_#{row["id"]}#{suffix}"
    end

    def format_qty(qty)
      qty.to_d.round(8).to_s("F").sub(/\.?0+\z/, "")
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end
end
