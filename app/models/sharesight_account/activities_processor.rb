class SharesightAccount::ActivitiesProcessor
  include SharesightAccount::DataHelpers

  # Trade types we book as trades. Capital returns go in as cash. Everything
  # else (splits, bonus issues, consolidations, cost base adjustments,
  # transfers) changes units or cost with no price we can use, so it's logged
  # and skipped. The holdings snapshot still has the right number of units.
  TRADE_LABELS = {
    "BUY" => "Buy",
    "OPENING_BALANCE" => "Buy",
    "SELL" => "Sell"
  }.freeze

  CAPITAL_RETURN = "CAPITAL_RETURN".freeze
  OPENING_BALANCE = "OPENING_BALANCE".freeze

  # Sharesight creates some records itself (dividends, DRP allotments,
  # maturities) and leaves them unconfirmed, with no id, until you confirm them.
  # Its holdings and value already count them, so we book them under this
  # prefix and swap them out once the confirmed record turns up with an id.
  PROVISIONAL_PREFIX = "sharesight_unconfirmed_".freeze

  BOOKED_STATES = %w[confirmed unconfirmed].freeze

  # How much cash a record moved in the investment account, so CashRouter can
  # settle it somewhere else. kind is :trade or :dividend. matchable is false
  # when no bank would ever see it (opening balances). leftover is true for
  # what's left of a reinvested dividend, which the registry often keeps for
  # the next reinvestment, so it might never reach a bank either.
  Movement = Data.define(:key, :kind, :date, :currency, :amount, :matchable, :leftover, :description)

  attr_reader :movements

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
    @provisional_ids = []
    @provisional_counts = Hash.new(0)
    @movements = []
  end

  def process
    return { trades: 0, dividends: 0, transactions: 0 } unless account.present?

    remove_entries_settings_exclude

    capital_returns, trades = booked_trades.partition { |trade| trade["transaction_type"].to_s.upcase == CAPITAL_RETURN }

    trade_count = trades.sum { |trade| process_trade(trade) ? 1 : 0 }
    dividend_count = booked(@sharesight_account.raw_payouts_payload, "paid_on").sum { |payout| process_payout(payout) ? 1 : 0 }
    transaction_count = capital_returns.sum { |trade| process_capital_return(trade) ? 1 : 0 }
    transaction_count += Array(@sharesight_account.raw_cash_transactions_payload).sum do |transaction|
      process_cash_transaction(transaction) ? 1 : 0
    end

    remove_replaced_provisional_entries

    { trades: trade_count, dividends: dividend_count, transactions: transaction_count }
  end

  private

    def account
      @sharesight_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def portfolio_currency
      @sharesight_account.currency
    end

    def booked_trades
      @booked_trades ||= booked(@sharesight_account.raw_trades_payload, "transaction_date")
    end

    # Confirmed and unconfirmed records from the sync start date up to today.
    # Future unconfirmed ones are just announcements, like a dividend that
    # hasn't been paid yet.
    def booked(records, date_key)
      Array(records).select do |record|
        date = parse_date(record[date_key])
        BOOKED_STATES.include?(record.fetch("state", "confirmed").to_s) && date.present? && date <= Date.current &&
          !@sharesight_account.before_sync_start?(date)
      end
    end

    # The record's id if it has one. Otherwise a provisional key made from what
    # the record is about, numbered if two records end up with the same key.
    def external_id_for(kind, record, *identity)
      return "sharesight_#{kind}_#{record['id']}" if record["id"].present?

      base = "#{PROVISIONAL_PREFIX}#{kind}_#{identity.join('_')}"
      count = (@provisional_counts[base] += 1)
      (count == 1 ? base : "#{base}_#{count}").tap { |id| @provisional_ids << id }
    end

    def remove_replaced_provisional_entries
      account.entries
        .where(source: "sharesight")
        .where("external_id LIKE ?", "#{Entry.sanitize_sql_like(PROVISIONAL_PREFIX)}%")
        .where.not(external_id: @provisional_ids)
        .destroy_all
    end

    # Clean up entries from earlier syncs that the current settings leave out.
    def remove_entries_settings_exclude
      entries = account.entries.where(source: "sharesight").where.not(entryable_type: "Valuation")

      if @sharesight_account.sync_start_date
        entries.where(entries: { date: ...@sharesight_account.sync_start_date }).destroy_all
      end

      if @sharesight_account.dividends_skipped?
        entries.where(entryable_type: "Transaction").where(external_id_like_any(%w[payout capital_return])).destroy_all
      end

      # Cash account movements only belong here while the broker holds the cash.
      entries.where(external_id_like_any(%w[cash])).find_each do |entry|
        entry.destroy! unless @sharesight_account.holds_cash_at_broker_on?(entry.date)
      end
    end

    def external_id_like_any(kinds)
      patterns = kinds.flat_map { |kind| [ "sharesight_#{kind}_", "#{PROVISIONAL_PREFIX}#{kind}_" ] }
      clause = patterns.map { "entries.external_id LIKE ?" }.join(" OR ")
      [ clause, *patterns.map { |prefix| "#{Entry.sanitize_sql_like(prefix)}%" } ]
    end

    def record_movement(entries, kind:, matchable:, leftover: false)
      entries = Array(entries).compact
      return if entries.empty?

      first = entries.first
      @movements << Movement.new(
        key: first.external_id.delete_prefix("sharesight_"),
        kind: kind,
        date: first.date,
        currency: first.currency,
        amount: entries.sum(&:amount),
        matchable: matchable,
        leftover: leftover,
        description: first.name
      )
    end

    def process_trade(trade)
      type = trade["transaction_type"].to_s.upcase
      label = TRADE_LABELS[type]
      unless label
        log_skipped_trade(trade, type)
        return false
      end

      quantity = parse_decimal(trade["quantity"])&.abs
      date = parse_date(trade["transaction_date"])
      return false if quantity.nil? || quantity.zero? || date.nil?

      external_id = external_id_for("trade", trade, trade["holding_id"], trade["transaction_date"], type, quantity.to_s("F"))
      security = resolve_security(trade["symbol"], trade["market"])
      return false unless security

      # Sharesight's exchange_rate is instrument currency per unit of portfolio
      # currency. Sure's trade rate is the other way round.
      sharesight_rate = parse_decimal(trade["exchange_rate"])
      sharesight_rate = nil unless sharesight_rate&.positive?
      currency, price = trade_price(trade, type, quantity, sharesight_rate)
      return false if price.nil?

      fee = trade_fee(trade, currency, sharesight_rate, date)
      gross = quantity * price
      signed_quantity = label == "Sell" ? -quantity : quantity

      entry = import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: signed_quantity,
        price: price,
        amount: (label == "Sell" ? -gross : gross) + fee,
        currency: currency,
        date: date,
        source: "sharesight",
        activity_label: label,
        exchange_rate: currency != portfolio_currency && sharesight_rate ? (1 / sharesight_rate).to_f : nil,
        fee: fee
      )
      record_movement(entry, kind: :trade, matchable: type != OPENING_BALANCE)

      true
    rescue => e
      log_failure("trade", trade["id"], e)
      false
    end

    # The instrument's currency, if Sharesight or the market tells us.
    def instrument_currency(record)
      @sharesight_account.holding_currencies[record["holding_id"].to_s] || market_currency(record["market"])
    end

    # Trades are booked in the instrument's currency. If we don't know it (or
    # it's crypto) we fall back to the portfolio's and convert the price with
    # the trade's rate.
    def trade_price(trade, type, quantity, sharesight_rate)
      price = parse_decimal(trade["price"])
      price = nil if price&.zero?

      # An opening balance might only have a cost base, in the portfolio's
      # currency. Without the trade's rate we can't convert it, so keep it in the
      # portfolio's currency.
      if price.nil? && type == OPENING_BALANCE
        cost_base = parse_decimal(trade["cost_base"])
        return [ nil, nil ] unless cost_base
        return [ portfolio_currency, cost_base / quantity ] unless sharesight_rate

        price = cost_base * sharesight_rate / quantity
      end
      return [ nil, nil ] if price.nil?

      currency = instrument_currency(trade)
      return [ currency, price ] if currency

      [ portfolio_currency, sharesight_rate ? price / sharesight_rate : price ]
    end

    # Brokerage is usually charged in the portfolio's currency. Convert it with
    # the trade's rate when we can, otherwise Sure's rate for that day.
    def trade_fee(trade, currency, sharesight_rate, date)
      fee = parse_decimal(trade["brokerage"]) || BigDecimal("0")
      fee_currency = parse_currency(trade["brokerage_currency_code"]) || currency
      return fee if fee.zero? || fee_currency == currency

      if sharesight_rate && fee_currency == portfolio_currency
        fee * sharesight_rate
      elsif sharesight_rate && currency == portfolio_currency
        fee / sharesight_rate
      else
        Money.new(fee, fee_currency).exchange_to(currency, date: date).amount
      end
    rescue Money::ConversionError
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Left the #{fee_currency} brokerage on Sharesight trade #{trade['id']} out: no rate to #{currency} for #{date}",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight"
      )
      BigDecimal("0")
    end

    # A capital return pays cash back without changing the units. Sure can't
    # lower the cost base, so we only book the cash. The trade's value is in the
    # portfolio's currency; capital_return_value is the fallback.
    def process_capital_return(trade)
      return false if @sharesight_account.dividends_skipped?

      amount = parse_decimal(trade["value"])&.abs
      currency = portfolio_currency
      unless amount&.positive?
        amount = parse_decimal(trade["capital_return_value"])
        currency = instrument_currency(trade) || portfolio_currency
      end
      date = parse_date(trade["transaction_date"])
      return false unless amount&.positive? && date

      external_id = external_id_for("capital_return", trade, trade["holding_id"], trade["transaction_date"])
      security = resolve_security(trade["symbol"], trade["market"])

      entry = import_adapter.import_transaction(
        external_id: external_id,
        amount: -amount,
        currency: currency,
        date: date,
        name: security ? "Capital return from #{security.ticker}" : "Capital return",
        source: "sharesight",
        investment_activity_label: "Other",
        extra: {
          security_id: security&.id,
          sharesight: { trade_id: trade["id"], symbol: trade["symbol"], market: trade["market"] }.compact
        }
      )
      record_movement(entry, kind: :dividend, matchable: true)

      true
    rescue => e
      log_failure("capital return", trade["id"], e)
      false
    end

    # If dividends aren't imported, a reinvested one still buys units. Those go
    # in with no cash, since the dividend that paid for them isn't here.
    def process_payout(payout)
      date = parse_date(payout["paid_on"])
      return false unless date

      external_id = external_id_for("payout", payout, payout["holding_id"], payout["paid_on"])
      security = resolve_security(payout["symbol"], payout["market"])
      currency = parse_currency(payout["currency"]) || @sharesight_account.holding_currencies[payout["holding_id"].to_s] || portfolio_currency
      amount = parse_decimal(payout["amount"])

      skipped = @sharesight_account.dividends_skipped?
      dividend = nil
      if amount&.positive? && !skipped
        dividend = import_adapter.import_transaction(
          external_id: external_id,
          amount: -amount,
          currency: currency,
          date: date,
          name: security ? "Dividend from #{security.ticker}" : "Dividend",
          source: "sharesight",
          investment_activity_label: "Dividend",
          extra: {
            security_id: security&.id,
            sharesight: { payout_id: payout["id"], symbol: payout["symbol"], market: payout["market"] }.compact
          }
        )
      end

      reinvestment = import_reinvestment(payout, security, currency, date, paid_for: !skipped)
      record_movement([ dividend, reinvestment ], kind: :dividend, matchable: true, leftover: reinvestment.present?) unless skipped
      dividend.present?
    rescue => e
      log_failure("payout", payout["id"], e)
      false
    end

    # A reinvested dividend buys units. Some portfolios record the allotment as
    # a trade too, so don't book it twice.
    def import_reinvestment(payout, security, currency, date, paid_for:)
      drp = payout["drp_trade_attributes"] || {}
      return unless security && drp["dividend_reinvested"]

      quantity = parse_decimal(drp["quantity"])&.abs
      price = parse_decimal(drp["price"])
      return unless quantity&.positive? && price&.positive?
      return if allotment_already_traded?(payout, quantity)

      import_adapter.import_trade(
        external_id: external_id_for("drp", payout, payout["holding_id"], payout["paid_on"]),
        security: security,
        quantity: quantity,
        price: price,
        amount: paid_for ? quantity * price : 0,
        currency: currency,
        date: date,
        source: "sharesight",
        activity_label: "Reinvestment"
      )
    end

    def allotment_already_traded?(payout, quantity)
      booked_trades.any? do |trade|
        trade["holding_id"].to_s == payout["holding_id"].to_s &&
          parse_date(trade["transaction_date"]) == parse_date(payout["paid_on"]) &&
          parse_decimal(trade["quantity"])&.abs == quantity
      end
    end

    # Deposits, withdrawals, interest and fees from a Sharesight cash account,
    # while the broker holds the cash. Skips the cash side of trades and
    # payouts, since those already book it.
    def process_cash_transaction(transaction)
      return false if transaction["id"].blank?
      return false if transaction["trade_id"].present? || transaction["payout_id"].present?

      amount = parse_decimal(transaction["amount"])
      date = parse_date(transaction["date_time"].to_s.first(10))
      return false if amount.nil? || amount.zero? || date.nil?
      return false if @sharesight_account.before_sync_start?(date) || !@sharesight_account.holds_cash_at_broker_on?(date)

      label = cash_transaction_label(transaction, amount)

      import_adapter.import_transaction(
        external_id: "sharesight_cash_#{transaction['id']}",
        amount: -amount,
        currency: parse_currency(transaction["currency"]) || portfolio_currency,
        date: date,
        name: transaction["description"].presence || label,
        source: "sharesight",
        investment_activity_label: label
      )

      true
    rescue => e
      log_failure("cash transaction", transaction["id"], e)
      false
    end

    def cash_transaction_label(transaction, amount)
      type = transaction.dig("cash_account_transaction_type", "name").to_s.upcase

      if type.include?("INTEREST")
        "Interest"
      elsif type.include?("FEE")
        "Fee"
      elsif amount.positive?
        "Contribution"
      else
        "Withdrawal"
      end
    end

    def log_skipped_trade(trade, type)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "SharesightAccount::ActivitiesProcessor - Skipped #{type} trade #{trade['id']} " \
                 "(#{trade['symbol']} on #{trade['transaction_date']}): Sure has no equivalent",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight",
        metadata: { trade_id: trade["id"], sharesight_account_id: @sharesight_account.id }
      )
    end

    def log_failure(kind, id, error)
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "SharesightAccount::ActivitiesProcessor - Failed to process #{kind} #{id}: #{error.message}",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight",
        metadata: { id: id, sharesight_account_id: @sharesight_account.id }
      )
    end
end
