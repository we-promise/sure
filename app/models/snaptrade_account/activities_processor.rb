class SnaptradeAccount::ActivitiesProcessor
  include SnaptradeAccount::DataHelpers

  # Declarative configuration for SnapTrade activity types.
  # Defines category (:trade, :unit_dependent, or :cash), investment activity label,
  # quantity signing convention (:buy, :sell, or :preserve), and amount handling (:unconditional, :if_absent, or nil).
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

    # Cash activities
    "DIVIDEND" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "DIV" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "CONTRIBUTION" => { category: :cash, label: "Contribution", cash_flow: :inflow },
    "WITHDRAWAL" => { category: :cash, label: "Withdrawal", cash_flow: :outflow },
    "TRANSFER" => { category: :cash, label: "Transfer", cash_flow: :invert },
    "TRANSFER_IN" => { category: :cash, label: "Transfer", cash_flow: :inflow },
    "TRANSFER_OUT" => { category: :cash, label: "Transfer", cash_flow: :outflow },
    "INTERNAL_CASH_TRANSFER_IN" => { category: :cash, label: "Transfer", cash_flow: :inflow },
    "INTERNAL_CASH_TRANSFER_OUT" => { category: :cash, label: "Transfer", cash_flow: :outflow },
    "INTEREST" => { category: :cash, label: "Interest", cash_flow: :inflow },
    "FEE" => { category: :cash, label: "Fee", cash_flow: :outflow },
    "TAX" => { category: :cash, label: "Fee", cash_flow: :outflow },
    "CASH" => { category: :cash, label: "Contribution", cash_flow: :inflow },
    "REBATE" => { category: :cash, label: "Other", cash_flow: :inflow },
    "RETURN_OF_CAPITAL" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "DISTRIBUTION" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "SUBSTITUTE_DIVIDEND" => { category: :cash, label: "Dividend", cash_flow: :inflow },
    "JOURNAL" => { category: :cash, label: "Other" },
    "OTHER" => { category: :cash, label: "Other" }
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
      if trade_activity?(activity_type, data)
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
        units = parse_decimal(data[:units]) || parse_decimal(data["units"]) ||
                parse_decimal(data[:quantity]) || parse_decimal(data["quantity"])
        units&.nonzero? ? true : false
      else
        false
      end
    end

    def process_trade(data, activity_type, external_id)
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
        ticker = raw_symbol_data
        symbol_data = symbol_wrapper # Use the wrapper for description, etc.
      elsif raw_symbol_data.is_a?(Hash)
        # Holdings structure: symbol.symbol is an object with symbol inside
        symbol_data = raw_symbol_data.with_indifferent_access
        ticker = symbol_data["symbol"] || symbol_data[:symbol]
        ticker = symbol_data["raw_symbol"] if ticker.is_a?(Hash)
      else
        ticker = nil
        symbol_data = {}
      end

      # Must have a symbol for trades
      if ticker.blank?
        capture_skipped_trade("missing_symbol", "no symbol", external_id: external_id, activity_type: activity_type)
        return
      end

      # Resolve security
      security = resolve_security(ticker, symbol_data)
      unless security
        capture_skipped_trade("unresolved_security", "security could not be resolved",
                              external_id: external_id, activity_type: activity_type, ticker: ticker)
        return
      end

      # Parse trade values
      quantity = parse_decimal(data[:units]) || parse_decimal(data["units"]) ||
                 parse_decimal(data[:quantity]) || parse_decimal(data["quantity"])
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
      quantity = case rule[:sign]
      when :preserve
        quantity
      when :sell
        -quantity.abs
      else
        quantity.abs
      end

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
      activity_date = parse_date(data[:settlement_date]) || parse_date(data["settlement_date"]) ||
                      parse_date(data[:trade_date]) || parse_date(data["trade_date"]) || Date.current

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
        activity_label: label_from_type(activity_type)
      )
      @trades_count += 1 if result
    end

    def process_cash_activity(data, activity_type, external_id)
      amount = parse_decimal(data[:amount]) || parse_decimal(data["amount"]) ||
               parse_decimal(data[:net_amount]) || parse_decimal(data["net_amount"])
      return if amount.nil? || amount.zero?

      # Get the activity date
      activity_date = parse_date(data[:settlement_date]) || parse_date(data["settlement_date"]) ||
                      parse_date(data[:trade_date]) || parse_date(data["trade_date"]) || Date.current

      # Build description
      raw_symbol_data = data[:symbol] || data["symbol"] || {}
      symbol_data = raw_symbol_data.is_a?(Hash) ? raw_symbol_data.with_indifferent_access : {}
      symbol = symbol_data[:symbol] || symbol_data["symbol"] || symbol_data[:ticker]
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
end
