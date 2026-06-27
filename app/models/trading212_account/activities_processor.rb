class Trading212Account::ActivitiesProcessor
  include Trading212Account::DataHelpers

  # T212 transaction types that map to cash flows
  DEPOSIT_TYPE = "DEPOSIT".freeze
  WITHDRAWAL_TYPE = "WITHDRAWAL".freeze
  INTEREST_TYPE = "INTEREST".freeze
  FEE_TYPE = "FEE".freeze

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    return { trades: 0, dividends: 0, transactions: 0 } unless account.present?

    trade_count = Array(@trading212_account.raw_orders_payload).sum do |order|
      process_order(order.with_indifferent_access) ? 1 : 0
    end

    dividend_count = Array(@trading212_account.raw_dividends_payload).sum do |dividend|
      process_dividend(dividend.with_indifferent_access) ? 1 : 0
    end

    transaction_count = Array(@trading212_account.raw_transactions_payload).sum do |transaction|
      process_cash_transaction(transaction.with_indifferent_access) ? 1 : 0
    end

    { trades: trade_count, dividends: dividend_count, transactions: transaction_count }
  end

  private

    def account
      @trading212_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def currency
      @trading212_account.currency
    end

    def process_order(raw)
      # T212 orders response is {order: {...}, fill: {...}}
      order = (raw[:order] || {}).with_indifferent_access
      fill  = (raw[:fill]  || {}).with_indifferent_access

      return false unless order[:status].to_s.upcase == "FILLED"

      instrument = (order[:instrument] || {}).with_indifferent_access
      t212_ticker = instrument[:ticker].presence || order[:ticker].to_s
      return false if t212_ticker.blank?

      filled_quantity = parse_decimal(fill[:quantity])
      fill_price      = parse_decimal(fill[:price])
      net_value       = parse_decimal(fill.dig(:walletImpact, :netValue)) ||
                        parse_decimal(order[:filledValue])

      return false unless filled_quantity && fill_price
      return false if filled_quantity.zero?

      isin     = instrument[:isin].presence
      ticker   = standard_ticker(t212_ticker)
      name     = instrument[:name].presence || ticker
      security = resolve_security_direct(isin, ticker, name)
      return false unless security

      is_buy         = order[:side].to_s.upcase == "BUY"
      activity_label = is_buy ? "Buy" : "Sell"
      signed_quantity = is_buy ? filled_quantity : -filled_quantity
      amount = net_value ? net_value.abs : (fill_price * filled_quantity.abs)
      amount = is_buy ? amount : -amount

      instrument_ccy = instrument[:currency].presence || currency
      date           = parse_date(fill[:filledAt] || order[:createdAt]) || Date.current
      order_id       = (fill[:id] || order[:id]).to_s
      external_id    = "trading212_order_#{order_id}"

      import_adapter.import_trade(
        external_id:    external_id,
        security:       security,
        quantity:       signed_quantity,
        price:          fill_price,
        amount:         amount,
        currency:       instrument_ccy,
        date:           date,
        name:           build_order_name(security.ticker, signed_quantity),
        source:         "trading212",
        activity_label: activity_label
      )

      true
    rescue => e
      Rails.logger.error(
        "Trading212Account::ActivitiesProcessor - Failed to process order #{raw.dig(:order, :id)}: #{e.message}"
      )
      false
    end

    def process_dividend(dividend)
      reference = dividend[:reference].to_s
      return false if reference.blank?

      amount = parse_decimal(dividend[:amount])
      return false unless amount && amount > 0

      t212_ticker = dividend[:ticker].to_s
      security = t212_ticker.present? ? resolve_security_for_ticker(t212_ticker) : nil

      date = parse_date(dividend[:paidOn]) || Date.current

      import_adapter.import_transaction(
        external_id: "trading212_dividend_#{reference}",
        amount: -amount.abs,
        currency: currency,
        date: date,
        name: build_dividend_name(security),
        source: "trading212",
        investment_activity_label: "Dividend",
        extra: {
          security_id: security&.id,
          trading212: {
            reference: reference,
            ticker: t212_ticker,
            quantity: dividend[:quantity],
            gross_amount_per_share: dividend[:grossAmountPerShare],
            type: dividend[:type]
          }.compact
        }
      )

      true
    rescue => e
      Rails.logger.error(
        "Trading212Account::ActivitiesProcessor - Failed to process dividend #{dividend[:reference]}: #{e.message}"
      )
      false
    end

    def process_cash_transaction(transaction)
      reference = transaction[:reference].to_s
      return false if reference.blank?

      type = transaction[:type].to_s.upcase
      amount = parse_decimal(transaction[:amount])
      return false unless amount && !amount.zero?

      label, signed_amount = classify_transaction(type, amount)
      return false unless label

      date = parse_date(transaction[:dateTime]) || Date.current

      import_adapter.import_transaction(
        external_id: "trading212_transaction_#{reference}",
        amount: signed_amount,
        currency: currency,
        date: date,
        name: label,
        source: "trading212",
        investment_activity_label: label,
        extra: {
          trading212: {
            reference: reference,
            type: type,
            amount: transaction[:amount]
          }.compact
        }
      )

      true
    rescue => e
      Rails.logger.error(
        "Trading212Account::ActivitiesProcessor - Failed to process transaction #{transaction[:reference]}: #{e.message}"
      )
      false
    end

    def classify_transaction(type, amount)
      case type
      when DEPOSIT_TYPE
        [ "Contribution", -amount.abs ]
      when WITHDRAWAL_TYPE
        [ "Withdrawal", amount.abs ]
      when INTEREST_TYPE
        [ "Interest", -amount.abs ]
      when FEE_TYPE
        [ "Fee", amount.abs ]
      end
    end

    def build_order_name(ticker, signed_quantity)
      action = signed_quantity.negative? ? "Sell" : "Buy"
      "#{action} #{signed_quantity.abs} shares of #{ticker}"
    end

    def build_dividend_name(security)
      security ? "Dividend from #{security.ticker}" : "Dividend"
    end
end
