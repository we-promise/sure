# One history response per invocation. Checkpoints advance only with the shared
# batch transaction, including both legs of each P2P order.
module Provider::AccountData::Binance::History
  WINDOWS = { "spot" => 86_400_000, "futures" => 604_800_000 }.freeze
  P2P_WINDOW = 2_592_000_000
  FUTURES_LOOKBACK = 15_552_000_000

  def fetch_activities(account:, cursor: nil, window: nil)
    ensure_requests_available!
    raise Provider::AccountData::UnsupportedCapability, "Binance history requires its combined account" unless account[:external_id] == "combined"
    state = cursor ? decode_state(cursor, "activities") : nil
    state = initial_history_state(account, state, window) if state.nil? || state["phase"] == "checkpoint"
    evidence = {}
    if state["phase"] == "p2p"
      result = checked_page(client.get_p2p_page(trade_type: state.fetch("side"), start_time: state.fetch("window_start"),
        end_time: state.fetch("window_end"), page: state.fetch("page")))
      records = result[:items].flat_map { |row| normalize_p2p(row) }
      timestamps = result[:items].map { |row| epoch_ms(normalized_object(row).fetch(:createTime)) }
      state["p2p_after"] = [ state["p2p_after"], *timestamps ].compact.max
      evidence = { "resource" => "p2p", "side" => state["side"], "response" => result[:evidence] || result[:items] }
      advance_p2p!(state, result[:next_cursor])
    elsif state["phase"] == "trades"
      task = state.fetch("tasks").fetch(state.fetch("task_index"))
      request = trade_request(state, task)
      begin
        result = checked_page(client.get_trades_page(task.fetch("pair"), market: task.fetch("market"), **request))
        records = result[:items].map do |row|
          record, prices = normalize_trade(row, pair: task.fetch("pair"), market: task.fetch("market"))
          (evidence["valuations"] ||= []).concat(prices)
          record
        end
        evidence.merge!("market" => task["market"], "pair" => task["pair"], "response" => result[:evidence] || result[:items])
        advance_trades!(state, task, request, result[:items])
      rescue Provider::Binance::InvalidSymbolError
        records = []
        evidence = { "market" => task["market"], "pair" => task["pair"], "unavailable_symbol" => true }
        finish_trade_task!(state)
      end
    else
      raise ArgumentError
    end
    complete = state["phase"] == "checkpoint"
    continuation = complete ? nil : encode_state(state)
    Provider::AccountData::Page.new(records: records, complete: complete, mode: "delta", next_cursor: continuation,
      progress_cursor: continuation, checkpoint_cursor: complete ? encode_state(state) : nil, evidence: evidence,
      coverage: { "end" => state.fetch("observed_at"), "scope" => "configured_pair_history" })
  rescue Provider::Binance::RateLimitError
    @rate_limited = true
    raise Provider::AccountData::IncompletePage, "Binance history was rate limited", cause: nil
  rescue ArgumentError, TypeError, KeyError, NoMethodError, IndexError, JSON::ParserError
    raise Provider::AccountData::InvalidResponse, "Invalid Binance activity page", cause: nil
  end

  def normalize_trade(raw, pair:, market:)
    raise ArgumentError unless %w[spot futures].include?(market)
    pair = asset_symbol(pair)
    quote = Provider::AccountData::Binance::QUOTES.find { |currency| pair.end_with?(currency) } || "USDT"
    symbol = pair.end_with?(quote) ? pair.delete_suffix(quote) : pair
    asset_symbol(symbol)
    data = normalized_object(raw)
    id = trade_id(data.fetch(:id))
    date = Time.at(epoch_ms(data.fetch(:time)) / 1000).in_time_zone(@timezone).to_date
    quantity = normalized_decimal(data.fetch(:qty))
    price = normalized_decimal(data.fetch(:price))
    value = normalized_decimal(data.fetch(:quoteQty))
    raise ArgumentError unless quantity.positive? && !price.negative? && !value.negative?
    buyer = data.key?(:isBuyer) ? data[:isBuyer] : data[:buyer]
    raise ArgumentError unless [ true, false ].include?(buyer)
    conversion, evidence = price_in_usd(quote, date: date)
    price_usd = Provider::AccountData::Binance::STABLECOINS.include?(quote) ? price : (price * conversion).round(8)
    amount_usd = (Provider::AccountData::Binance::STABLECOINS.include?(quote) ? value : (value * conversion).round(8)).round(2)
    commission = normalized_decimal(data.fetch(:commission))
    raise ArgumentError if commission.negative?
    fee = if commission.zero?
      BigDecimal("0")
    else
      fee_asset = asset_symbol(data[:commissionAsset])
      if Provider::AccountData::Binance::STABLECOINS.include?(fee_asset)
        commission
      elsif fee_asset == symbol
        (commission * price_usd).round(8)
      else
        fee_price, fee_evidence = price_in_usd(fee_asset, date: date, allow_fx: false)
        evidence = { "quote" => evidence, "commission" => fee_evidence }
        (commission * fee_price).round(8)
      end
    end
    label = buyer ? "Buy" : "Sell"
    record = Ingestion::Record.activity(external_id: "binance_#{market}_#{pair}_#{id}", activity_type: buyer ? "buy" : "sell",
      name: "#{label} #{quantity.round(8)} #{symbol}", quantity: buyer ? quantity : -quantity,
      price: price_usd, amount: buyer ? -amount_usd : amount_usd, currency: "USD", date: date,
      security: security_descriptor(symbol), metadata: { fee: fee, investment_activity_label: label, update_policy: "insert_only" })
    [ record, [ evidence ] ]
  rescue ArgumentError, TypeError, KeyError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Binance trade", cause: nil
  end

  def normalize_p2p(raw)
    data = normalized_object(raw)
    id = "binance_p2p_#{normalized_id(data[:orderNumber])}"
    funding_id = "#{id}_funding"
    raise ArgumentError unless %w[BUY SELL].include?(data[:tradeType])
    buyer = data[:tradeType] == "BUY"
    date = Time.at(epoch_ms(data.fetch(:createTime)) / 1000).in_time_zone(@timezone).to_date
    currency = normalized_currency(data.fetch(:fiat))
    value = normalized_decimal(data.fetch(:totalPrice))
    price = normalized_decimal(data.fetch(:unitPrice))
    gross = normalized_decimal(data.fetch(:amount))
    net = data[:takerAmount].nil? ? gross : normalized_decimal(data[:takerAmount])
    commission = data[:takerCommission].nil? ? BigDecimal("0") : normalized_decimal(data[:takerCommission])
    raise ArgumentError unless net.positive? && gross.positive? && !price.negative? && !value.negative? && !commission.negative?
    symbol = asset_symbol(data.fetch(:asset))
    label = buyer ? "Buy" : "Sell"
    group = { id: id, policy: "insert_pair_if_absent", members: [
      { external_id: id, financial_type: "Trade" }, { external_id: funding_id, financial_type: "Transaction" }
    ] }
    trade = Ingestion::Record.activity(external_id: id, activity_type: buyer ? "buy" : "sell", date: date,
      name: "P2P #{label} #{gross.round(8)} #{symbol}", currency: currency, amount: buyer ? value : -value,
      quantity: buyer ? net : -net, price: price, security: security_descriptor(symbol), metadata: {
        fee: (commission * price).round(2), investment_activity_label: label, update_policy: "insert_only", atomic_group: group
      })
    funding = Ingestion::Record.activity(external_id: funding_id, activity_type: buyer ? "contribution" : "withdrawal", date: date,
      name: "P2P #{buyer ? 'Payment' : 'Receipt'} (#{currency})", currency: currency, amount: buyer ? -value : value,
      metadata: { investment_activity_label: "", update_policy: "insert_only", atomic_group: group })
    buyer ? [ funding, trade ] : [ trade, funding ]
  rescue ArgumentError, TypeError, KeyError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Binance P2P order", cause: nil
  end

  private
    def initial_history_state(account, previous, window)
      seed = previous || @cached_history.deep_stringify_keys
      ids = seed.fetch("ids", { "spot" => {}, "futures" => {} })
      raise ArgumentError unless ids.is_a?(Hash) && ids.keys.sort == %w[futures spot] && ids.values.all? { |pairs| pairs.is_a?(Hash) }
      ids = ids.to_h do |market, pairs|
        [ market, pairs.to_h { |pair, id| [ asset_symbol(pair), trade_id(id) ] } ]
      end
      sources = normalized_object(account[:metadata] || {}).fetch(:portfolio_sources, {})
      current = normalized_object(sources).values.flat_map { |raw| Array(normalized_object(raw)[:assets]).map { |row| normalized_object(row)[:symbol] } }
      historical = ids.values.flat_map(&:keys).map { |pair| pair.sub(/(?:USDT|BUSD|FDUSD|BTC|ETH|BNB)\z/, "") }
      symbols = (current + historical).compact.uniq.map { |symbol| asset_symbol(symbol) }
        .reject { |symbol| Provider::AccountData::Binance::STABLECOINS.include?(symbol) }
      tasks = symbols.flat_map { |symbol| Provider::AccountData::Binance::QUOTES.flat_map { |quote| %w[spot futures].map { |market| { "pair" => "#{symbol}#{quote}", "market" => market } } } }
      end_ms = @observed_at.to_i * 1000
      explicit = window && (window[:explicit_start] || window["explicit_start"])
      start_ms = Time.iso8601(window[:start] || window["start"]).to_i * 1000 if explicit
      p2p_after = seed["p2p_after"] && epoch_ms(seed["p2p_after"])
      first = p2p_after || start_ms || end_ms - P2P_WINDOW
      first = [ first, end_ms ].min
      { "kind" => "activities", "observed_at" => observed_time, "end_ms" => end_ms,
        "phase" => "p2p", "side" => "BUY", "page" => 1, "window_start" => first,
        "window_end" => [ first + P2P_WINDOW, end_ms ].min, "p2p_after" => p2p_after,
        "start_ms" => start_ms, "ids" => ids.deep_dup, "tasks" => tasks, "task_index" => 0, "trade_cursor" => nil }
    end

    def advance_p2p!(state, next_page)
      if next_page
        page = positive_integer(next_page)
        raise ArgumentError unless page > state["page"]
        state["page"] = page
      elsif state["side"] == "BUY"
        state.merge!("side" => "SELL", "page" => 1)
      elsif state["window_end"] < state["end_ms"]
        first = state["window_end"] + 1
        state.merge!("side" => "BUY", "page" => 1, "window_start" => first, "window_end" => [ first + P2P_WINDOW, state["end_ms"] ].min)
      else
        state["phase"] = state["tasks"].empty? ? "checkpoint" : "trades"
      end
    end

    def trade_request(state, task)
      market, pair = task.fetch("market"), task.fetch("pair")
      cursor = state["trade_cursor"]
      unless cursor
        last = state.fetch("ids").fetch(market)[pair]
        if last
          cursor = { "from_id" => trade_id(last) + 1 }
        else
          first = state["start_ms"] || state["end_ms"] - WINDOWS.fetch(market)
          first = [ first, state["end_ms"] - FUTURES_LOOKBACK ].max if market == "futures"
          cursor = { "start_time" => [ first, state["end_ms"] ].min }
        end
        state["trade_cursor"] = cursor
      end
      if cursor.key?("from_id")
        { from_id: trade_id(cursor["from_id"]) }
      else
        first = epoch_ms(cursor.fetch("start_time"))
        { start_time: first, end_time: [ first + WINDOWS.fetch(market) - 1, state["end_ms"] ].min }
      end
    end

    def advance_trades!(state, task, request, rows)
      ids = rows.map { |row| trade_id(normalized_object(row).fetch(:id)) }
      raise ArgumentError unless ids.uniq == ids
      if request[:from_id] && ids.any? { |id| id < request[:from_id] }
        raise Provider::AccountData::IncompletePage, "Binance trade ID continuation did not advance"
      end
      previous = state.fetch("ids").fetch(task["market"])[task["pair"]]
      state["ids"][task["market"]][task["pair"]] = [ previous, *ids ].compact.max if ids.any?
      if rows.size == 1000
        # Switching to fromId avoids dropping trades sharing the last row's
        # millisecond. Binance forbids combining ID and time-window parameters.
        state["trade_cursor"] = { "from_id" => ids.max + 1 }
      elsif request[:end_time] && request[:end_time] < state["end_ms"]
        state["trade_cursor"] = { "start_time" => request[:end_time] + 1 }
      else
        finish_trade_task!(state)
      end
    end

    def finish_trade_task!(state)
      state["task_index"] += 1
      state["trade_cursor"] = nil
      state["phase"] = "checkpoint" if state["task_index"] >= state["tasks"].size
    end

    def trade_id(value)
      raise ArgumentError unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d+\z/))
      number = value.to_i
      raise ArgumentError if number.negative?
      number
    end

    def validate_history_state!(state)
      unless state.keys.sort == %w[end_ms ids kind observed_at p2p_after page phase side start_ms task_index tasks trade_cursor window_end window_start] &&
          %w[p2p trades checkpoint].include?(state["phase"]) && %w[BUY SELL].include?(state["side"]) &&
          state["page"].is_a?(Integer) && state["page"].positive? &&
          %w[end_ms window_start window_end].all? { |key| state[key].is_a?(Integer) && state[key] >= 0 } &&
          state["window_start"] <= state["window_end"] && state["window_end"] <= state["end_ms"] &&
          %w[start_ms p2p_after].all? { |key| state[key].nil? || (state[key].is_a?(Integer) && state[key] >= 0) }
        raise ArgumentError
      end
      ids = state["ids"]
      raise ArgumentError unless ids.is_a?(Hash) && ids.keys.sort == %w[futures spot] && ids.values.all? { |value| value.is_a?(Hash) }
      ids.each_value do |pairs|
        pairs.each do |pair, id|
          asset_symbol(pair)
          raise ArgumentError unless id.is_a?(Integer) && id >= 0
        end
      end
      tasks = state["tasks"]
      unless tasks.is_a?(Array) && tasks.all? { |task| task.is_a?(Hash) && task.keys.sort == %w[market pair] && %w[spot futures].include?(task["market"]) } &&
          state["task_index"].is_a?(Integer) && state["task_index"].between?(0, tasks.size)
        raise ArgumentError
      end
      tasks.each { |task| asset_symbol(task["pair"]) }
      raise ArgumentError if state["phase"] == "trades" && state["task_index"] >= tasks.size
      cursor = state["trade_cursor"]
      if cursor
        unless cursor.is_a?(Hash) && (cursor.keys == [ "from_id" ] || cursor.keys == [ "start_time" ]) &&
            cursor.values.first.is_a?(Integer) && cursor.values.first >= 0
          raise ArgumentError
        end
      end
    end

    def epoch_ms(value)
      trade_id(value)
    end
end
