class SnaptradeAccount::ActivitiesProcessor
  include SnaptradeAccount::DataHelpers

  # Two legs whose units differ by no more than this are taken to cancel:
  # providers can report the same quantity with a float's rounding.
  CANCELLING_QUANTITY_TOLERANCE = BigDecimal("0.000001")

  # Declarative configuration for SnapTrade activity types.
  # Defines category (:trade, :unit_dependent, :share_movement, or :cash), investment activity label
  # (trade_label, when given, labels a row imported as a trade instead), quantity signing convention
  # (:buy, :sell, or :preserve), and amount handling (:unconditional, :if_absent, or nil).
  ACTIVITY_RULES = {
    # Buys
    "BUY" => { category: :trade, label: "Buy", sign: :buy },

    # Sells
    "SELL" => { category: :trade, label: "Sell", sign: :sell },

    # Reinvestments
    "REI" => { category: :trade, label: "Reinvestment", sign: :buy },
    "REINVEST" => { category: :trade, label: "Reinvestment", sign: :buy },

    # Options
    "OPTION_BUY" => { category: :trade, label: "Buy", sign: :buy },
    "OPTION_SELL" => { category: :trade, label: "Sell", sign: :sell },
    "OPTIONASSIGNMENT" => { category: :trade, label: "Other", sign: :sell },
    "ASSIGNED" => { category: :trade, label: "Other", sign: :sell },
    "OPTIONEXERCISE" => { category: :trade, label: "Other", sign: :preserve },
    "EXERCISED" => { category: :trade, label: "Other", sign: :preserve },
    "OPTIONEXPIRATION" => { category: :trade, label: "Other", sign: :preserve, zero_amount: :unconditional },
    "EXPIRED" => { category: :trade, label: "Other", sign: :preserve, zero_amount: :unconditional },

    # Stock dividends and splits
    "STOCK_DIVIDEND" => { category: :trade, label: "Dividend", sign: :buy, zero_amount: :unconditional },
    "SPLIT" => { category: :trade, label: "Other", sign: :buy, zero_amount: :unconditional },
    "REVERSE_SPLIT" => { category: :trade, label: "Other", sign: :sell, zero_amount: :unconditional },
    "SPLIT_REVERSE" => { category: :trade, label: "Other", sign: :sell, zero_amount: :unconditional },
    "SPINOFF" => { category: :trade, label: "Other", sign: :buy, zero_amount: :unconditional },
    "SPIN_OFF" => { category: :trade, label: "Other", sign: :buy, zero_amount: :unconditional },

    # Asset transfers
    "EXTERNAL_ASSET_TRANSFER_IN" => { category: :trade, label: "Transfer", sign: :buy, zero_amount: :unconditional },
    "EXTERNAL_ASSET_TRANSFER_OUT" => { category: :trade, label: "Transfer", sign: :sell, zero_amount: :unconditional },
    "INTERNAL_ASSET_TRANSFER_IN" => { category: :trade, label: "Transfer", sign: :buy, zero_amount: :unconditional },
    "INTERNAL_ASSET_TRANSFER_OUT" => { category: :trade, label: "Transfer", sign: :sell, zero_amount: :unconditional },

    # Unit-dependent types:
    # When units are present and non-zero, treated as a trade preserving signed units.
    # When units are nil/zero, treated as a cash activity.
    "ADJUSTMENT" => { category: :unit_dependent, label: "Other", sign: :preserve, zero_amount: :unconditional, cash_flow: :invert },
    "STOCK_MERGER" => { category: :unit_dependent, label: "Other", sign: :preserve, zero_amount: :if_absent, cash_flow: :invert },
    "MERGER" => { category: :unit_dependent, label: "Other", sign: :preserve, zero_amount: :if_absent, cash_flow: :invert },
    "CORP_ACTION" => { category: :unit_dependent, label: "Other", sign: :preserve, zero_amount: :if_absent, cash_flow: :invert },

    # Share-movement types (a journal, a transfer or an unclassified activity can move cash or shares):
    # When units are present and non-zero and the row carries no cash, treated as shares moving
    # in or out, such as a stock plan depositing vested shares: a zero-cash trade with signed units,
    # labelled Transfer because the shares were neither bought nor sold.
    # Otherwise treated as a cash activity, since beside cash what the units mean is unknown
    # (a 401(k) payroll contribution arrives as a TRANSFER with units and its cash amount).
    "JOURNAL" => { category: :share_movement, label: "Other", trade_label: "Transfer", sign: :preserve, zero_amount: :unconditional },
    "OTHER" => { category: :share_movement, label: "Other", trade_label: "Transfer", sign: :preserve, zero_amount: :unconditional },
    "TRANSFER" => { category: :share_movement, label: "Transfer", sign: :preserve, zero_amount: :unconditional, cash_flow: :invert },
    "TRANSFER_IN" => { category: :share_movement, label: "Transfer", sign: :buy, zero_amount: :unconditional, cash_flow: :inflow },
    "TRANSFER_OUT" => { category: :share_movement, label: "Transfer", sign: :sell, zero_amount: :unconditional, cash_flow: :outflow },

    # Cash activities
    "DIVIDEND" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "DIV" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "CONTRIBUTION" => { category: :cash, label: "Contribution", cash_flow: :inflow },
    "WITHDRAWAL" => { category: :cash, label: "Withdrawal", cash_flow: :outflow },
    "INTERNAL_CASH_TRANSFER_IN" => { category: :cash, label: "Transfer", cash_flow: :inflow },
    "INTERNAL_CASH_TRANSFER_OUT" => { category: :cash, label: "Transfer", cash_flow: :outflow },
    "INTEREST" => { category: :cash, label: "Interest", cash_flow: :inflow },
    "FEE" => { category: :cash, label: "Fee", cash_flow: :outflow },
    "TAX" => { category: :cash, label: "Fee", cash_flow: :outflow },
    "CASH" => { category: :cash, label: "Contribution", cash_flow: :inflow },
    "REBATE" => { category: :cash, label: "Other", cash_flow: :inflow },
    "RETURN_OF_CAPITAL" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "DISTRIBUTION" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "SUBSTITUTE_DIVIDEND" => { category: :cash, label: "Dividend", cash_flow: :inflow }
  }.freeze

  SNAPTRADE_TYPE_TO_LABEL = ACTIVITY_RULES.transform_values { |r| r[:label] }.freeze

  def initialize(snaptrade_account)
    @snaptrade_account = snaptrade_account
  end

  def process
    activities_data = @snaptrade_account.raw_activities_payload
    return { trades: 0, transactions: 0 } if activities_data.blank?

    Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Processing #{activities_data.size} activities"

    @trades_count = 0
    @transactions_count = 0
    @cancelled_movement_ids = cancelled_share_movement_ids(activities_data)

    activities_data.each do |activity_data|
      process_activity(activity_data.with_indifferent_access)
    rescue => e
      activity = activity_data.is_a?(Hash) ? activity_data.with_indifferent_access : {}
      capture_debug_log(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process activity #{activity[:id]}: #{e.message}",
        metadata: {
          activity_id: activity[:id]&.to_s,
          activity_type: activity[:type],
          error_class: e.class.name,
          backtrace: e.backtrace&.first(5)
        }
      )
    end

    { trades: @trades_count, transactions: @transactions_count }
  end

  private

    def account
      @snaptrade_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Support-relevant events go to /settings/debug rather than the Rails log
    def capture_debug_log(message:, category: "provider_sync", level: "warn", metadata: {})
      DebugLogEntry.capture(
        category: category,
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "snaptrade",
        family: @snaptrade_account.snaptrade_item.family,
        account_provider: @snaptrade_account.account_provider,
        metadata: { snaptrade_account_id: @snaptrade_account.id }.merge(metadata)
      )
    end

    def capture_skipped_trade(reason, description, external_id:, activity_type:, ticker: nil)
      capture_debug_log(
        message: "Skipping trade #{external_id}: #{description}",
        metadata: { activity_id: external_id, activity_type: activity_type, ticker: ticker, reason: reason }.compact
      )
    end

    def process_activity(data)
      # Ensure we have indifferent access
      data = data.with_indifferent_access if data.is_a?(Hash)

      activity_type = (data[:type] || data["type"])&.upcase
      return if activity_type.blank?

      # Get external ID for deduplication
      external_id = (data[:id] || data["id"]).to_s
      return if external_id.blank?

      Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Processing activity: type=#{activity_type}, id=#{external_id}"

      # Determine if this is a trade or cash activity
      if @cancelled_movement_ids.include?(external_id)
        remove_cancelled_movement(external_id)
      elsif trade_activity?(activity_type, data)
        process_trade(data, activity_type, external_id)
      else
        process_cash_activity(data, activity_type, external_id)
      end
    end

    def trade_activity?(activity_type, data = {})
      rule = ACTIVITY_RULES[activity_type]
      return false unless rule

      case rule[:category]
      when :trade
        true
      when :unit_dependent
        nonzero_units?(data)
      when :share_movement
        # Only rows that name no cash at all, which the cash path skips
        nonzero_units?(data) && !carries_cash?(data)
      else
        false
      end
    end

    def units(data)
      parse_decimal(data[:units]) || parse_decimal(data["units"]) ||
        parse_decimal(data[:quantity]) || parse_decimal(data["quantity"])
    end

    def nonzero_units?(data)
      units(data)&.nonzero? ? true : false
    end

    def carries_cash?(data)
      !cash_amount(data).nil?
    end

    def signed_quantity(quantity, rule)
      case rule[:sign]
      when :preserve
        quantity
      when :sell
        -quantity.abs
      else
        quantity.abs
      end
    end

    # Trades are dated by settlement. A share movement has no settlement cycle
    # of its own, and a brokerage can date a deposit after the sale of the very
    # shares it delivered, which would leave the history short of them in
    # between. Shares coming in take the earlier of the two dates and shares
    # going out the later, so a trade dated between the two falls after a
    # deposit and before a withdrawal, never the other way round.
    def activity_date_for(data, rule, quantity)
      settlement_date = parse_date(data[:settlement_date]) || parse_date(data["settlement_date"])
      trade_date = parse_date(data[:trade_date]) || parse_date(data["trade_date"])

      date = if rule[:category] == :share_movement
        dates = [ settlement_date, trade_date ].compact
        quantity.negative? ? dates.max : dates.min
      else
        settlement_date || trade_date
      end

      date || Date.current
    end

    # Share movements that undo each other: two legs moving the same number of
    # shares of one security in opposite directions on the same day, such as a
    # journal between two parts of the account. Together they move nothing,
    # and imported, the inbound leg would still leave the position's cost basis
    # unknown until it is sold out, so neither is imported. Only pairs are
    # matched: three legs that net to nothing are all imported.
    #
    # A leg whose stored trade is protected from sync stays, so it is left out
    # of the matching and its counterpart is imported too: together they still
    # move nothing. A protected cash entry holds no shares, and its leg is
    # matched as usual.
    def cancelled_share_movement_ids(activities_data)
      legs = activities_data.filter_map do |activity_data|
        next unless activity_data.is_a?(Hash)

        data = activity_data.with_indifferent_access
        activity_type = data[:type].to_s.upcase
        rule = ACTIVITY_RULES[activity_type]
        next unless rule && rule[:category] == :share_movement && trade_activity?(activity_type, data)

        # Matched on the ticker the trade would be booked on, as two rows of
        # one security can carry its symbol in different shapes
        ticker, = trade_ticker_and_symbol_data(data)
        next if ticker.blank? || data[:id].blank?

        qty = signed_quantity(units(data), rule)
        # The legs of a journal carry the same dates, but a leg out is booked on
        # the later of them, so legs are matched on the date a leg in would take
        { id: data[:id].to_s, day: [ ticker.to_s.upcase, activity_date_for(data, rule, qty.abs) ], qty: qty }
      rescue => e
        # A row the matching cannot read is left to the import below, which
        # skips and logs it, rather than failing every other row with it
        Rails.logger.warn("SnaptradeAccount::ActivitiesProcessor - Not matching activity #{activity_data.try(:[], "id")} as a share movement: #{e.class}")
        nil
      end

      kept_ids = protected_trade_ids(legs.map { |leg| leg[:id] })
      legs = legs.reject { |leg| kept_ids.include?(leg[:id]) }

      legs.group_by { |leg| leg[:day] }.each_value.with_object(Set.new) do |day_legs, ids|
        inbound, outbound = day_legs.partition { |leg| leg[:qty].positive? }

        outbound.each do |out_leg|
          in_leg = inbound.find { |leg| (leg[:qty] + out_leg[:qty]).abs <= CANCELLING_QUANTITY_TOLERANCE }
          next unless in_leg

          inbound.delete(in_leg)
          ids << in_leg[:id] << out_leg[:id]
        end
      end
    end

    # The ticker an activity trades, the symbol data to resolve it with and
    # the option contract's data: the contract's ticker when the row names
    # one, else the symbol's, whose shape differs between activities and
    # holdings.
    def trade_ticker_and_symbol_data(data)
      ticker, option_data = option_ticker_and_data(data)

      # Extract and normalize symbol data
      # SnapTrade activities have DIFFERENT structure than holdings:
      #   activity.symbol.symbol = "MSTR" (ticker string directly)
      #   activity.symbol.description = name
      # Holdings have deeper nesting: symbol.symbol.symbol = ticker
      raw_symbol_wrapper = data["symbol"] || data[:symbol] || {}
      symbol_wrapper = raw_symbol_wrapper.is_a?(Hash) ? raw_symbol_wrapper.with_indifferent_access : {}

      # Get the symbol field - could be a string (ticker) or nested object
      raw_symbol_data = symbol_wrapper["symbol"] || symbol_wrapper[:symbol]

      # Determine ticker based on data type
      if raw_symbol_data.is_a?(String)
        # Activities: symbol.symbol is the ticker string directly
        fallback_ticker = raw_symbol_data
        underlying_symbol_data = symbol_wrapper # Use the wrapper for description, etc.
      elsif raw_symbol_data.is_a?(Hash)
        # Holdings structure: symbol.symbol is an object with symbol inside
        underlying_symbol_data = raw_symbol_data.with_indifferent_access
        fallback_ticker = underlying_symbol_data["symbol"] || underlying_symbol_data[:symbol]
        fallback_ticker = underlying_symbol_data["raw_symbol"] if fallback_ticker.is_a?(Hash)
      else
        fallback_ticker = nil
        underlying_symbol_data = {}
      end

      if ticker.present?
        # When option_symbol is present, use option_data but merge in underlying symbol
        # metadata as fallback (e.g. exchange, currency, ticker) when option_symbol lacks them.
        symbol_data = underlying_symbol_data.merge(option_data).with_indifferent_access
      else
        ticker = fallback_ticker
        symbol_data = underlying_symbol_data
      end

      [ ticker, symbol_data, option_data ]
    end

    # The ids of the stored trades among these that a sync must leave in place
    def protected_trade_ids(external_ids)
      return Set.new if external_ids.empty?

      account.entries.trades.where(source: "snaptrade", external_id: external_ids)
        .select(&:protected_from_sync?).to_set(&:external_id)
    end

    # A leg imported before the one that cancels it arrived would otherwise
    # stay behind: a trade moving shares on its own, or, stored as cash while
    # the row carried some, cash the row no longer reports.
    def remove_cancelled_movement(external_id)
      entry = account.entries.find_by(external_id: external_id, source: "snaptrade")
      return if entry.nil? || entry.protected_from_sync?

      Rails.logger.info("SnaptradeAccount::ActivitiesProcessor - Removing share movement #{external_id}, cancelled by its counterpart")
      entry.destroy!
    end

    def process_trade(data, activity_type, external_id)
      # Check `option_symbol` first: if present, this is an option contract trade.
      # Prioritizing `option_symbol` prevents brokerages like Robinhood (which populate
      # plain `symbol` with the underlying equity) from importing options as common stock.
      ticker, symbol_data, option_data = trade_ticker_and_symbol_data(data)

      # Must have a symbol for trades
      if ticker.blank?
        capture_skipped_trade("missing_symbol", "no symbol", external_id: external_id, activity_type: activity_type)
        return
      end

      # Resolve security
      security = resolve_security(ticker, symbol_data, account: account, account_provider_id: @snaptrade_account.account_provider&.id)
      unless security
        capture_skipped_trade("unresolved_security", "security could not be resolved",
                              external_id: external_id, activity_type: activity_type, ticker: ticker)
        return
      end

      # Parse trade values
      quantity = units(data)
      price = parse_decimal(data[:price]) || parse_decimal(data["price"])
      amount = parse_decimal(data[:amount]) || parse_decimal(data["amount"]) ||
               parse_decimal(data[:trade_value]) || parse_decimal(data["trade_value"])
      fee = (parse_decimal(data[:fee]) || parse_decimal(data["fee"]))&.abs

      if quantity.nil?
        capture_skipped_trade("missing_quantity", "no quantity",
                              external_id: external_id, activity_type: activity_type, ticker: ticker)
        return
      end

      rule = ACTIVITY_RULES[activity_type] || {}

      # Determine sign based on activity type (sell-side should be negative)
      quantity = signed_quantity(quantity, rule)

      # SnapTrade reports option `units` in contracts while quoting `price` per
      # underlying share. Normalize `price` to per-contract so `qty * price`
      # represents total contract value across all downstream consumers.
      multiplier = contract_multiplier(symbol_data, option_data)
      price *= multiplier if price

      case rule[:zero_amount]
      when :unconditional
        amount = BigDecimal("0.0")
        price = price.presence || BigDecimal("0.0")
      when :if_absent
        if amount&.nonzero?
          amount = quantity.negative? ? -amount.abs : amount.abs
        else
          amount = BigDecimal("0.0")
          price = price.presence || BigDecimal("0.0")
        end
      else
        amount = if amount&.nonzero?
          quantity.negative? ? -amount.abs : amount.abs
        elsif price
          # Same convention as a manually entered trade: the fee adds to a buy's
          # cost and comes out of a sell's proceeds.
          quantity * price + (fee || 0)
        end
      end

      if amount.nil?
        capture_skipped_trade("missing_amount", "no amount, and no price to derive it from",
                              external_id: external_id, activity_type: activity_type, ticker: ticker)
        return
      end

      if price.nil? && !quantity.zero?
        price = (amount - (fee || 0)) / quantity
        capture_debug_log(
          level: "info",
          message: "Derived missing price for trade #{external_id} from its amount and quantity",
          metadata: {
            activity_id: external_id,
            activity_type: activity_type,
            ticker: ticker,
            reason: "derived_price",
            quantity: quantity.to_s("F"),
            amount: amount.to_s("F"),
            fee: fee&.to_s("F"),
            derived_price: price.to_s("F")
          }.compact
        )
      end

      # Get the activity date
      activity_date = activity_date_for(data, rule, quantity)

      # Extract currency - handle both nested object and string
      currency_data = data[:currency] || data["currency"] || symbol_data[:currency] || symbol_data["currency"]
      currency = if currency_data.is_a?(Hash)
        currency_data.with_indifferent_access[:code]
      elsif currency_data.is_a?(String)
        currency_data
      else
        account.currency
      end

      description = data[:description] || data["description"] || "#{activity_type} #{ticker}"

      Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Importing trade: #{ticker} qty=#{quantity} price=#{price} amount=#{amount} fee=#{fee} date=#{activity_date}"

      return unless reclassify_entry_if_needed(external_id, "Trade")

      result = import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: quantity,
        price: price,
        amount: amount,
        fee: fee,
        currency: currency,
        date: activity_date,
        name: description,
        source: "snaptrade",
        activity_label: rule[:trade_label] || label_from_type(activity_type)
      )
      @trades_count += 1 if result

      # Recorded once, on first import: for these types the units are the only
      # sign that the row moves shares, so support can see which rows were read that way
      if rule[:category] == :share_movement && result&.previously_new_record?
        capture_debug_log(
          level: "info",
          message: "Imported #{activity_type} activity #{external_id} as a share movement of #{quantity.to_s('F')} #{ticker}",
          metadata: { activity_id: external_id, activity_type: activity_type, ticker: ticker, quantity: quantity.to_s("F"), reason: "share_movement" }
        )
      end
    end

    def process_cash_activity(data, activity_type, external_id)
      amount = cash_amount(data)
      return if amount.nil? || amount.zero?

      # Get the activity date
      activity_date = parse_date(data[:settlement_date]) || parse_date(data["settlement_date"]) ||
                      parse_date(data[:trade_date]) || parse_date(data["trade_date"]) || Date.current

      # Build description
      raw_symbol_data = data[:symbol] || data["symbol"] || {}
      symbol_data = raw_symbol_data.is_a?(Hash) ? raw_symbol_data.with_indifferent_access : {}
      symbol = symbol_data[:symbol] || symbol_data["symbol"] || symbol_data[:ticker]
      option_ticker, = option_ticker_and_data(data)
      symbol = option_ticker if option_ticker.present?
      description = data[:description] || data["description"] || build_description(activity_type, symbol)

      # Normalize amount sign for certain activity types
      amount = normalize_cash_amount(amount, activity_type)

      # Extract currency - handle both nested object and string
      currency_data = data[:currency] || data["currency"]
      currency = if currency_data.is_a?(Hash)
        currency_data.with_indifferent_access[:code]
      elsif currency_data.is_a?(String)
        currency_data
      else
        account.currency
      end

      Rails.logger.info "SnaptradeAccount::ActivitiesProcessor - Importing cash activity: type=#{activity_type} amount=#{amount} date=#{activity_date}"

      return unless reclassify_entry_if_needed(external_id, "Transaction")

      result = import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: activity_date,
        name: description,
        source: "snaptrade",
        investment_activity_label: label_from_type(activity_type)
      )
      @transactions_count += 1 if result
    end

    # The cash a row names: its amount, or its net amount when the amount is
    # missing or zero. Nil when it names none.
    def cash_amount(data)
      [ data[:amount], data["amount"], data[:net_amount], data["net_amount"] ]
        .map { |value| parse_decimal(value) }
        .find { |amount| amount&.nonzero? }
    end

    def reclassify_entry_if_needed(external_id, expected_type)
      return true if external_id.blank?

      existing = account.entries.find_by(external_id: external_id, source: "snaptrade")
      return true unless existing && existing.entryable_type != expected_type

      if existing.protected_from_sync?
        capture_debug_log(
          message: "Skipping reclassification of protected entry #{existing.id} (#{external_id})",
          metadata: { activity_id: external_id, reason: "protected" }
        )
        return false
      end

      Rails.logger.info("SnaptradeAccount::ActivitiesProcessor - Reclassifying activity #{external_id} from #{existing.entryable_type} to #{expected_type}")
      existing.destroy!
      true
    end

    def normalize_cash_amount(amount, activity_type)
      rule = ACTIVITY_RULES[activity_type] || {}

      case rule[:cash_flow]
      when :outflow
        amount.abs   # Money out should be positive in Sure
      when :inflow
        -amount.abs  # Money in should be negative in Sure
      when :invert
        # Direction is not encoded in the type (unlike TRANSFER_IN/TRANSFER_OUT), so the
        # provider's sign is the only directional signal available. SnapTrade signs these
        # from the account's perspective (positive = money in), which is the inverse of
        # Sure's convention, so invert it rather than passing it through unchanged.
        # Passing it through stored a 401k contribution as a positive amount, which
        # Entry#classification reads as an expense and ReverseCalculator reads as a
        # value decrease — a correct current balance with a declining history (issue #2756).
        -amount
      else
        amount
      end
    end

    def build_description(activity_type, symbol)
      type_label = label_from_type(activity_type)
      if symbol.present?
        "#{type_label} - #{symbol}"
      else
        type_label
      end
    end

    def label_from_type(activity_type)
      normalized_type = activity_type&.upcase
      label = SNAPTRADE_TYPE_TO_LABEL[normalized_type]

      if label.nil? && normalized_type.present?
        # Record unmapped activity types for visibility - helps identify new types to add
        capture_debug_log(
          message: "Unmapped activity type '#{normalized_type}'. Consider adding to SNAPTRADE_TYPE_TO_LABEL mapping.",
          metadata: { activity_type: normalized_type }
        )
      end

      label || "Other"
    end

    def option_ticker_and_data(data)
      raw_option_symbol = data["option_symbol"] || data[:option_symbol]
      return [ nil, nil ] unless raw_option_symbol.is_a?(Hash)

      option_symbol_data = raw_option_symbol.with_indifferent_access
      ticker = option_symbol_data[:ticker]
      return [ nil, nil ] if ticker.blank?

      [ ticker, option_symbol_data ]
    end
end
