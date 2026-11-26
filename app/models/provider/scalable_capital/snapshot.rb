class Provider::ScalableCapital::Snapshot
  CURRENCY = "EUR"
  ZONE = "Europe/Berlin"
  FINAL_STATUSES = %w[FILLED FINAL_FILL SETTLED EXECUTED COMPLETED].freeze
  FILL_STATES = %w[FILLED FINAL_FILL PARTIAL_FILL EXECUTED].freeze
  ROUNDING_TOLERANCE = 0.01.to_d
  INFLOWS = %w[INTEREST DISTRIBUTION DIVIDEND TAX_RETURN DEPOSIT TRANSFER_IN CASH_TRANSFER_IN POCKET_MONEY REINVESTMENT_DISTRIBUTION REINVESTMENT_POCKET_MONEY].freeze
  OUTFLOWS = %w[FEE TAX WITHDRAWAL TRANSFER_OUT CASH_TRANSFER_OUT].freeze
  TRADE_TYPES = %w[BUY SELL SINGLE SAVINGS_PLAN REINVESTMENT IPO].freeze
  SECURITY_TRANSFER_TYPES = %w[TRANSFER_IN TRANSFER_OUT].freeze
  SWAP_TYPES = %w[SWAP_IN SWAP_OUT].freeze
  ISIN_PATTERN = /\A[A-Z]{2}[A-Z0-9]{10}\z/

  attr_reader :broker_account_id, :savings_id, :skipped, :through

  def initialize(client, item, identity: nil, through: Time.at(Time.current.to_i).utc)
    @client = client
    @item = item
    @identity = identity
    @through = through
    @skipped = 0
    @trade_details = {}
  end

  def fetch
    overview = @client.overview(@item.portfolio_id) if @item.portfolio_id
    @broker_account_id = overview ? overview["account_id"] : @identity
    raise invalid unless @broker_account_id.is_a?(String) && @broker_account_id.present?
    if @item.broker_account_id && @item.broker_account_id != @broker_account_id
      raise Provider::ScalableCapital::AuthenticationError, "Sign in with the original Scalable account"
    end

    snapshots = overview ? brokerage(overview) : []
    snapshots << savings if @item.savings_id || @item.auto_discover_savings?
    snapshots.compact
  end

  private

    def brokerage(overview)
      overview_data = broker_result(overview)
      reject_crypto! if decimal(overview_data.dig("valuation", "crypto"))&.nonzero?

      cash = decimal(broker_result(@client.cash(@item.portfolio_id))["cash_balance"])
      raise invalid unless cash

      inventory = broker_result(@client.holdings(@item.portfolio_id))
      inventory_date = Time.current.in_time_zone(ZONE).to_date
      positions = positions(inventory)
      # The overview's valuation can refer to an older inventory. Use the
      # holdings observation for both the balance and the position snapshots.
      holdings_value = positions.sum { |position| position.fetch(:amount) }

      trades, cash_events = history(:brokerage, @item.broker_history_start).partition { |row| row.key?(:isin) }
      [
        { kind: :brokerage, date: inventory_date, balance: holdings_value, cash: 0, positions: positions, entries: trades },
        { kind: :cash, date: local_today, balance: cash, cash: cash, positions: [], entries: cash_events }
      ]
    end

    def positions(inventory)
      holdings = inventory["items"]
      raise invalid unless holdings.is_a?(Array)
      Array(inventory["crypto_items"]).each do |row|
        reject_crypto! if decimal(row.dig("position", "filled"))&.nonzero?
      end

      positions = holdings.filter_map { |row| position(row) }
      raise invalid unless positions.map { |row| row.fetch(:isin) }.uniq.size == positions.size

      positions
    end

    def savings
      data = @client.overnight(@item.savings_id)
      @savings_id = data["savings_account_id"]
      raise invalid unless ScalableCapitalItem.valid_source_id?(@savings_id)
      return if @item.savings_id.nil? && data.dig("account", "owner_kind") == "junior"

      balance = decimal(savings_result(data)["balance"])
      raise invalid if balance.nil? || balance.negative?
      return if balance.zero? && @item.savings_synced_through.nil?

      { kind: :savings, date: local_today, balance: balance, cash: balance, positions: [],
        entries: history(:savings, @item.savings_synced_through) }
    rescue Provider::ScalableCapital::NoOvernightAccount
      raise if @item.savings_id
    end

    def history(kind, checkpoint)
      lower_bound = checkpoint&.utc || (through - 90.days)
      return [] if lower_bound >= through

      entries = {}
      # The CLI sends whole seconds and the remote lower bound may be exclusive.
      # Read one extra second, then apply an exact half-open window locally.
      read_history(kind, lower_bound - 1.second) do |data, rows|
        kind == :brokerage ? broker_result(data) : savings_result(data)
        @skipped += 1 if kind == :brokerage && data.dig("result", "crypto", "items").present?

        rows.each do |row|
          raise invalid unless row.is_a?(Hash)
          final_status = FINAL_STATUSES.include?(row["status"]) || (kind == :savings && row["status"] == "CONFIRMED")
          next unless row["is_cancellation"] == false && final_status

          time = timestamp(row["last_event_datetime"])
          unless time
            if event_type(row)
              raise Provider::ScalableCapital::InvalidResponse, "Scalable returned an unreadable timestamp for a supported transaction"
            end
            @skipped += 1
            next
          end
          next if time < lower_bound || time >= through

          id = row["id"]
          raise invalid unless id.is_a?(String) && id.present? && id.bytesize <= 220
          next if entries.key?(id)

          type = event_type(row)
          parsed = type && event(row, time, id, type)
          entries[id] = parsed == :included_in_trade ? nil : parsed
          next if parsed == :included_in_trade

          @skipped += 1 unless entries[id]
        end
      end
      resolve_swaps(entries)
    end

    def read_history(kind, since, &block)
      if kind == :brokerage
        @client.broker_transactions(@item.portfolio_id, since: since, before: through, &block)
      else
        @client.overnight_transactions(@savings_id, since: since, before: through, &block)
      end
    end

    def event_type(row)
      return unless row["currency"] == CURRENCY

      case row["summary_type"]
      when "BrokerSecurityTransactionSummary"
        return :trade if TRADE_TYPES.include?(row["security_transaction_type"] || row["type"])
        return
      when "BrokerNonTradeSecurityTransactionSummary"
        security_type = row["non_trade_security_transaction_type"]
        return :security_transfer if SECURITY_TRANSFER_TYPES.include?(security_type)
        return :swap if SWAP_TYPES.include?(security_type)
      end

      type = row["cash_transaction_type"] || row["non_trade_security_transaction_type"] || row["type"]
      type if INFLOWS.include?(type) || OUTFLOWS.include?(type)
    end

    def event(row, time, id, type)
      return trade(row, time, id) if type == :trade
      return security_transfer(row, time, id) if type == :security_transfer
      return { swap_type: row["non_trade_security_transaction_type"], occurred_at: time } if type == :swap

      amount = decimal(row["amount"])&.abs
      raise Provider::ScalableCapital::InvalidResponse, "Scalable returned an unreadable amount for a supported cash transaction" unless amount
      if @item.portfolio_id && %w[FEE TAX].include?(type) && row["related_isin"].present? && already_in_trade?(id, type, amount)
        return :included_in_trade
      end

      label = { "INTEREST" => "Interest", "DIVIDEND" => "Dividend", "DISTRIBUTION" => "Dividend", "FEE" => "Fee" }[type]
      { external_id: id, date: time.to_date, name: text(row["description"]) || type.humanize,
        amount: INFLOWS.include?(type) ? -amount : amount, investment_activity_label: label }
    end

    def security_transfer(row, time, id)
      isin = text(row["isin"])
      shares = decimal(row["quantity"])&.abs
      raise invalid unless isin&.match?(ISIN_PATTERN) && shares&.positive?

      outgoing = row["non_trade_security_transaction_type"] == "TRANSFER_OUT"
      { external_id: id, date: time.to_date, occurred_at: time, isin: isin, quantity: outgoing ? -shares : shares,
        price: 0, amount: 0, fee: 0, activity_label: "Transfer" }
    end

    def trade(summary, event_time, id)
      detail = trade_detail(id)
      raise invalid unless detail["id"] == id && detail["currency"] == CURRENCY
      return if detail["is_cancellation"] == true
      if (summary["security_transaction_type"] || summary["type"]) == "IPO"
        return if detail["is_pending"] != false || !detail["security_trade"].is_a?(Hash)
        return unless detail["security_trade"]["side"] == "BUY" && FINAL_STATUSES.include?(detail["security_trade"]["status"])
      end
      raise invalid unless detail["is_pending"] == false && detail["is_cancellation"] == false

      trade = detail["security_trade"]
      raise invalid unless trade.is_a?(Hash) && FINAL_STATUSES.include?(trade["status"])

      isin = text(detail.dig("security", "isin")) || text(summary["isin"])
      quantity = decimal(trade.dig("number_of_shares", "filled"))
      price = decimal(trade["average_price"])
      net = decimal(trade["total_amount"])&.abs
      side = trade["side"]
      raise invalid unless isin&.match?(ISIN_PATTERN) && quantity&.positive? && price&.positive? && net && %w[BUY SELL].include?(side)

      buy = side == "BUY"
      fee = reconciled_fee(trade["trade_transaction_amounts"], gross: quantity * price, net: net, buy: buy)
      raise invalid if fee.nil?

      time = execution_time(detail["history"]) || event_time
      { external_id: id, date: time.to_date, occurred_at: time, isin: isin, security_name: text(detail.dig("security", "name")),
        quantity: buy ? quantity : -quantity, price: price, amount: buy ? net : -net, fee: fee }
    end

    def resolve_swaps(entries)
      imported = Set.new
      entries.flat_map do |id, entry|
        next [] unless entry
        next [ entry ] unless entry[:swap_type]
        next [] if imported.include?(id)

        pair = swap_pair(id, entry)
        if pair && pair.none? { |leg| imported.include?(leg.fetch(:external_id)) }
          ids = pair.pluck(:external_id)
          imported.merge(ids)
          pair.map { |leg| leg.merge(related_trade_ids: ids) }
        else
          @skipped += 1
          []
        end
      end
    end

    def swap_pair(id, summary)
      detail = trade_detail(id)
      incoming = summary.fetch(:swap_type) == "SWAP_IN"
      leg = swap_leg(detail, incoming, summary[:occurred_at])
      return unless leg

      linked_ids = Array(detail["linked_transaction_ids"]).select { |linked_id| valid_transaction_id?(linked_id) && linked_id != id }.uniq
      return unless linked_ids.one?

      counterpart = trade_detail(linked_ids.first)
      return unless Array(counterpart["linked_transaction_ids"]).include?(id)

      other_leg = swap_leg(counterpart, !incoming, nil)
      return if !other_leg || leg[:isin] == other_leg[:isin]
      return if (leg[:price] * leg[:quantity] + other_leg[:price] * other_leg[:quantity]).abs > ROUNDING_TOLERANCE

      [ leg, other_leg ]
    end

    def swap_leg(detail, incoming, fallback_time)
      return unless detail["currency"] == CURRENCY && detail["is_pending"] == false && detail["is_cancellation"] == false

      swap = detail["non_trade_security"]
      return unless swap.is_a?(Hash) && swap["non_trade_security_transaction_type"] == (incoming ? "SWAP_IN" : "SWAP_OUT")

      isin = text(swap["isin"]) || text(detail.dig("security", "isin"))
      quantity = decimal(swap["quantity"])&.abs
      price = decimal(swap["average_price"])
      total = decimal(swap["total_amount"])&.abs
      time = timestamp(detail["last_event_datetime"]) || fallback_time
      return unless isin&.match?(ISIN_PATTERN) && quantity&.positive? && price&.positive? && total&.positive? && time && time < through
      return if (quantity * price - total).abs > ROUNDING_TOLERANCE

      { external_id: detail.fetch("id"), date: time.to_date, occurred_at: time, isin: isin,
        security_name: text(detail.dig("security", "name")), quantity: incoming ? quantity : -quantity,
        price: price, amount: 0, fee: 0, activity_label: "Exchange" }
    end

    def valid_transaction_id?(id)
      id.is_a?(String) && id.present? && id.bytesize <= 220
    end

    def trade_detail(id)
      @trade_details[id] ||= broker_result(@client.trade(@item.portfolio_id, id)).tap do |detail|
        raise invalid unless detail["id"] == id
      end
    end

    def already_in_trade?(id, type, amount)
      cash_detail = trade_detail(id)

      Array(cash_detail["linked_transaction_ids"]).any? do |linked_id|
        next false unless valid_transaction_id?(linked_id) && linked_id != id

        detail = trade_detail(linked_id)

        trade = detail["security_trade"]
        next false unless detail["currency"] == CURRENCY && detail["is_pending"] == false && detail["is_cancellation"] == false &&
          trade.is_a?(Hash) && FINAL_STATUSES.include?(trade["status"]) && %w[BUY SELL].include?(trade["side"])

        amounts = trade["trade_transaction_amounts"]
        next false unless amounts.is_a?(Hash)

        keys = type == "TAX" ? %w[tax_amount] : %w[transaction_fee venue_fee crypto_spread_fee]
        next false unless keys.any? { |key| decimal(amounts[key]) == amount }

        quantity = decimal(trade.dig("number_of_shares", "filled"))
        price = decimal(trade["average_price"])
        net = decimal(trade["total_amount"])&.abs
        quantity&.positive? && price&.positive? && net &&
          !reported_fee(amounts, gross: quantity * price, net: net, buy: trade["side"] == "BUY").nil?
      end
    end

    def execution_time(history)
      Array(history).filter_map do |event|
        timestamp(event["timestamp"]) if event.is_a?(Hash) && FILL_STATES.include?(event["state"])
      end.max
    end

    def reconciled_fee(amounts, gross:, net:, buy:)
      if amounts.is_a?(Hash)
        fee = reported_fee(amounts, gross: gross, net: net, buy: buy)
        return fee unless fee.nil?
      end

      adjustment = buy ? net - gross : gross - net
      [ adjustment, 0 ].max if adjustment >= -ROUNDING_TOLERANCE
    end

    def reported_fee(amounts, gross:, net:, buy:)
      fee_values = amounts.values_at("transaction_fee", "venue_fee", "crypto_spread_fee").compact
      return if fee_values.empty? && amounts["tax_amount"].nil?

      fees = fee_values.map { |value| decimal(value) }
      tax = decimal(amounts["tax_amount"] || 0)
      market_value = decimal(amounts["market_valuation"] || gross)
      return unless tax && market_value && (market_value - gross).abs <= ROUNDING_TOLERANCE
      return unless fees.all? { |fee| fee && !fee.negative? }

      fee = fees.sum(0.to_d)
      expected_net = buy ? market_value + fee + tax : market_value - fee - tax
      fee if (expected_net - net).abs <= ROUNDING_TOLERANCE
    end

    def position(row)
      raise invalid unless row.is_a?(Hash)
      quantity = decimal(row["quantity"])
      return if quantity&.zero?

      isin = text(row["isin"])
      amount = decimal(row["valuation"])
      raise invalid unless isin&.match?(ISIN_PATTERN) && quantity&.positive? &&
        row["valuation_currency"] == CURRENCY && amount && !amount.negative?

      cost_basis = decimal(row["fifo_price"])
      { isin: isin, security_name: text(row["name"]), quantity: quantity, amount: amount,
        price: amount / quantity, cost_basis: (cost_basis if cost_basis&.positive?) }
    end

    def broker_result(data)
      result(data, "portfolio_id", @item.portfolio_id).tap do
        raise invalid unless data["account_id"] == @broker_account_id
      end
    end

    def savings_result(data)
      result(data, "savings_account_id", @item.savings_id || @savings_id).tap do
        raise invalid unless data.dig("account", "owner_kind") == @item.savings_owner_kind && data.dig("account", "is_active") == true
      end
    end

    def result(data, id_field, expected_id)
      raise invalid unless data.is_a?(Hash) && data[id_field] == expected_id && data["result"].is_a?(Hash)
      data["result"]
    end

    def decimal(value)
      return unless value.is_a?(String) || value.is_a?(Numeric)
      number = BigDecimal(value.to_s, exception: false)
      number if number&.finite?
    end

    def local_today
      through.in_time_zone(ZONE).to_date
    end

    def timestamp(value)
      return unless value.is_a?(String)
      Time.find_zone!(ZONE).iso8601(value)
    rescue ArgumentError
      nil
    end

    def text(value)
      value.strip.presence if value.is_a?(String)
    end

    def invalid
      Provider::ScalableCapital::InvalidResponse.new("Scalable returned missing, stale or inconsistent account data")
    end

    def reject_crypto!
      raise Provider::ScalableCapital::InvalidResponse, "Broker portfolios with crypto positions are not supported"
    end
end
