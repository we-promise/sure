# frozen_string_literal: true

class IndexaCapitalAccount::ActivitiesProcessor
  include IndexaCapitalAccount::DataHelpers

  # Map provider activity types to Sure activity labels
  # TODO: Customize for your provider's activity types
  ACTIVITY_TYPE_TO_LABEL = {
    "BUY" => "Buy",
    "SELL" => "Sell",
    "DIVIDEND" => "Dividend",
    "DIV" => "Dividend",
    "CONTRIBUTION" => "Contribution",
    "WITHDRAWAL" => "Withdrawal",
    "TRANSFER_IN" => "Transfer",
    "TRANSFER_OUT" => "Transfer",
    "TRANSFER" => "Transfer",
    "INTEREST" => "Interest",
    "FEE" => "Fee",
    "TAX" => "Fee",
    "REINVEST" => "Reinvestment",
    "SPLIT" => "Other",
    "MERGER" => "Other",
    "OTHER" => "Other"
  }.freeze

  # Activity types that result in Trade records (involves securities)
  TRADE_TYPES = %w[BUY SELL REINVEST].freeze

  # Sell-side activity types (quantity should be negative)
  SELL_SIDE_TYPES = %w[SELL].freeze

  # Activity types that result in Transaction records (cash movements)
  CASH_TYPES = %w[DIVIDEND DIV CONTRIBUTION WITHDRAWAL TRANSFER_IN TRANSFER_OUT TRANSFER INTEREST FEE TAX].freeze

  def initialize(indexa_capital_account)
    @indexa_capital_account = indexa_capital_account
  end

  def process
    activities_data = @indexa_capital_account.raw_activities_payload
    return { trades: 0, transactions: 0 } if activities_data.blank?

    Rails.logger.info "IndexaCapitalAccount::ActivitiesProcessor - Processing #{activities_data.size} activities"

    @trades_count = 0
    @transactions_count = 0

    activities_data.each do |activity_data|
      process_activity(activity_data.with_indifferent_access)
    rescue => e
      Rails.logger.error "IndexaCapitalAccount::ActivitiesProcessor - Failed to process activity: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    end

    { trades: @trades_count, transactions: @transactions_count }
  end

  private

    def account
      @indexa_capital_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_activity(data)
      # TODO: Customize activity type field name
      activity_type = (data[:type] || data[:activity_type])&.upcase
      return if activity_type.blank?

      # Get external ID for deduplication
      external_id = (data[:id] || data[:transaction_id]).to_s
      return if external_id.blank?

      Rails.logger.info "IndexaCapitalAccount::ActivitiesProcessor - Processing activity: type=#{activity_type}, id=#{external_id}"

      # Determine if this is a trade or cash activity
      if trade_activity?(activity_type)
        process_trade(data, activity_type, external_id)
      else
        process_cash_activity(data, activity_type, external_id)
      end
    end

    def trade_activity?(activity_type)
      TRADE_TYPES.include?(activity_type)
    end

    def process_trade(data, activity_type, external_id)
      # TODO: Customize ticker extraction based on your provider's format
      ticker = data[:symbol] || data[:ticker]
      if ticker.blank?
        Rails.logger.warn "IndexaCapitalAccount::ActivitiesProcessor - Skipping trade without symbol: #{external_id}"
        return
      end

      # Resolve security
      security = resolve_security(ticker, data)
      return unless security

      # TODO: Customize field names based on your provider's format
      quantity = parse_decimal(data[:units]) || parse_decimal(data[:quantity])
      price = parse_decimal(data[:price])

      if quantity.nil?
        Rails.logger.warn "IndexaCapitalAccount::ActivitiesProcessor - Skipping trade without quantity: #{external_id}"
        return
      end

      # Determine sign based on activity type (sell-side should be negative)
      quantity = if SELL_SIDE_TYPES.include?(activity_type)
        -quantity.abs
      else
        quantity.abs
      end

      # Calculate amount
      amount = if price
        quantity * price
      else
        parse_decimal(data[:amount]) || parse_decimal(data[:trade_value])
      end

      if amount.nil?
        Rails.logger.warn "IndexaCapitalAccount::ActivitiesProcessor - Skipping trade without amount: #{external_id}"
        return
      end

      # Get the activity date
      # TODO: Customize date field names
      activity_date = parse_date(data[:settlement_date]) ||
                      parse_date(data[:trade_date]) ||
                      parse_date(data[:date]) ||
                      Date.current

      currency = extract_currency(data, fallback: account.currency)
      description = data[:description] || "#{activity_type} #{ticker}"

      Rails.logger.info "IndexaCapitalAccount::ActivitiesProcessor - Importing trade: #{ticker} qty=#{quantity} price=#{price} date=#{activity_date}"

      result = import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: quantity,
        price: price,
        amount: amount,
        currency: currency,
        date: activity_date,
        name: description,
        source: "indexa_capital",
        activity_label: label_from_type(activity_type)
      )
      @trades_count += 1 if result
    end

    def process_cash_activity(data, activity_type, external_id)
      # TODO: Customize amount field names
      amount = parse_decimal(data[:amount]) ||
               parse_decimal(data[:net_amount])
      return if amount.nil?
      # Note: Zero-amount transactions (splits, free shares) are allowed

      # Get the activity date
      # TODO: Customize date field names
      activity_date = parse_date(data[:settlement_date]) ||
                      parse_date(data[:trade_date]) ||
                      parse_date(data[:date]) ||
                      Date.current

      # Build description
      symbol = data[:symbol] || data[:ticker]
      description = data[:description] || build_description(activity_type, symbol)

      # Normalize amount sign for certain activity types
      amount = normalize_cash_amount(amount, activity_type)

      currency = extract_currency(data, fallback: account.currency)

      Rails.logger.info "IndexaCapitalAccount::ActivitiesProcessor - Importing cash activity: type=#{activity_type} amount=#{amount} date=#{activity_date}"

      result = import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: activity_date,
        name: description,
        source: "indexa_capital",
        investment_activity_label: label_from_type(activity_type)
      )
      @transactions_count += 1 if result
    end

    def normalize_cash_amount(amount, activity_type)
      case activity_type
      when "WITHDRAWAL", "TRANSFER_OUT", "FEE", "TAX"
        -amount.abs  # These should be negative (money out)
      when "CONTRIBUTION", "TRANSFER_IN", "DIVIDEND", "DIV", "INTEREST"
        amount.abs   # These should be positive (money in)
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
      label = ACTIVITY_TYPE_TO_LABEL[normalized_type]

      if label.nil? && normalized_type.present?
        Rails.logger.warn(
          "IndexaCapitalAccount::ActivitiesProcessor - Unmapped activity type '#{normalized_type}' " \
          "for account #{@indexa_capital_account.id}. Consider adding to ACTIVITY_TYPE_TO_LABEL mapping."
        )
      end

      label || "Other"
    end
end
