# frozen_string_literal: true

class QuestradeAccount::ActivitiesProcessor
  include QuestradeAccount::DataHelpers

  # Questrade groups activities by `type` (category) and `action` (sub-action,
  # e.g. Buy/Sell/CON/FCH). We route on `type`, then use `action` for direction.
  #
  # Sign convention: Questrade `netAmount` is +money-in / -money-out, but Sure
  # stores transactions as -inflow / +outflow, so cash signed_amount = -netAmount.
  TRADE_TYPE = "Trades"

  # Questrade `type` -> Sure investment activity label (cash transactions)
  CASH_TYPE_TO_LABEL = {
    "Deposits"         => "Contribution",
    "Withdrawals"      => "Withdrawal",
    "Dividends"        => "Dividend",
    "Interest"         => "Interest",
    "Fees and rebates" => "Fee"
  }.freeze

  # Still unmapped: FX conversions (cash currency exchanges) and corporate
  # actions. Skipped with a log rather than imported wrong.
  UNSUPPORTED_TYPES = [ "FX conversion", "Corporate actions" ].freeze

  # Norbert's Gambit / in-kind transfers: shares journaled between symbols or
  # currencies with no cash impact. Recorded as zero-cost "Transfer" trades.
  JOURNAL_TYPES = [ "Other", "Transfers" ].freeze

  def initialize(questrade_account)
    @questrade_account = questrade_account
  end

  def process
    return { trades: 0, transactions: 0 } unless account.present?

    @trades_count = 0
    @transactions_count = 0

    activities.each do |raw|
      process_activity(raw.with_indifferent_access)
    rescue => e
      Rails.logger.error "QuestradeAccount::ActivitiesProcessor - Failed to process activity: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    end

    { trades: @trades_count, transactions: @transactions_count }
  end

  private

    def account
      @questrade_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # raw_activities_payload may be the array itself or the { activities: [...] }
    # hash returned by Provider::Questrade#get_activities.
    def activities
      payload = @questrade_account.raw_activities_payload
      payload = payload.with_indifferent_access[:activities] if payload.is_a?(Hash)
      Array(payload)
    end

    def process_activity(data)
      type = data[:type].to_s.strip
      return if type.blank?

      if type == TRADE_TYPE
        process_trade(data)
      elsif CASH_TYPE_TO_LABEL.key?(type)
        process_cash_activity(data, CASH_TYPE_TO_LABEL[type])
      elsif JOURNAL_TYPES.include?(type)
        if journal?(data)
          process_journal(data)
        else
          Rails.logger.info "QuestradeAccount::ActivitiesProcessor - Skipping non-journal '#{type}'"
        end
      elsif UNSUPPORTED_TYPES.include?(type)
        Rails.logger.info "QuestradeAccount::ActivitiesProcessor - Skipping unsupported type '#{type}'"
      else
        Rails.logger.warn "QuestradeAccount::ActivitiesProcessor - Unmapped activity type '#{type}'"
      end
    end

    # Questrade activities carry no unique id, so synthesize a stable one from
    # the immutable fields to keep re-syncs idempotent.
    def external_id(data, prefix)
      digest = Digest::SHA256.hexdigest(
        [ data[:transactionDate], data[:action], data[:symbolId], data[:quantity], data[:netAmount], data[:description] ].join("|")
      )
      "questrade_#{prefix}_#{digest.first(24)}"
    end

    def process_trade(data)
      ticker = data[:symbol].to_s.strip
      return if ticker.blank?

      security = resolve_security(ticker, { name: data[:description], currency: data[:currency] })
      return unless security

      quantity = parse_decimal(data[:quantity])
      price = parse_decimal(data[:price])
      return if quantity.nil? || quantity.zero?

      sell = data[:action].to_s.casecmp("Sell").zero?
      signed_quantity = sell ? -quantity.abs : quantity.abs
      # Buy => positive cost, Sell => negative (matches Sure's trade convention).
      amount = price ? signed_quantity * price : parse_decimal(data[:netAmount])&.abs
      return if amount.nil?

      date = parse_date(data[:tradeDate]) || parse_date(data[:transactionDate]) || Date.current
      currency = extract_currency(data, fallback: account.currency)

      result = import_adapter.import_trade(
        external_id: external_id(data, "trade"),
        security: security,
        quantity: signed_quantity,
        price: price,
        amount: amount,
        currency: currency,
        date: date,
        name: data[:description].presence || "#{sell ? 'Sell' : 'Buy'} #{ticker}",
        source: "questrade",
        activity_label: sell ? "Sell" : "Buy"
      )
      @trades_count += 1 if result

      import_commission(data, ticker, date, currency)
    end

    def import_commission(data, ticker, date, currency)
      commission = parse_decimal(data[:commission])
      return if commission.nil? || commission.zero?

      result = import_adapter.import_transaction(
        external_id: external_id(data, "fee"),
        amount: commission.abs, # money out
        currency: currency,
        date: date,
        name: "Commission for #{ticker}",
        source: "questrade",
        investment_activity_label: "Fee"
      )
      @transactions_count += 1 if result
    end

    def journal?(data)
      data[:symbol].to_s.strip.present? && !(parse_decimal(data[:quantity]) || 0).zero?
    end

    # A journal (Norbert's Gambit / transfer) moves shares with no cash impact.
    # Recorded as a zero-cost Transfer trade; the holding's cost basis still
    # comes from the positions snapshot.
    def process_journal(data)
      ticker = data[:symbol].to_s.strip
      security = resolve_security(ticker, { name: data[:description], currency: data[:currency] })
      return unless security

      quantity = parse_decimal(data[:quantity])
      return if quantity.nil? || quantity.zero?

      date = parse_date(data[:tradeDate]) || parse_date(data[:transactionDate]) || Date.current
      currency = extract_currency(data, fallback: account.currency)

      result = import_adapter.import_trade(
        external_id: external_id(data, "journal"),
        security: security,
        quantity: quantity,
        price: 0,
        amount: 0,
        currency: currency,
        date: date,
        name: data[:description].presence || "Journal #{ticker}",
        source: "questrade",
        activity_label: "Transfer"
      )
      @trades_count += 1 if result
    end

    def process_cash_activity(data, label)
      net = parse_decimal(data[:netAmount])
      return if net.nil?

      signed_amount = -net # Questrade +in / -out  ->  Sure -in / +out
      date = parse_date(data[:settlementDate]) ||
             parse_date(data[:transactionDate]) ||
             parse_date(data[:tradeDate]) ||
             Date.current
      currency = extract_currency(data, fallback: account.currency)

      symbol = data[:symbol].to_s.strip
      security = symbol.present? ? resolve_security(symbol, { name: data[:description], currency: data[:currency] }) : nil

      name = data[:description].presence || (symbol.present? ? "#{label} - #{symbol}" : label)

      result = import_adapter.import_transaction(
        external_id: external_id(data, "cash"),
        amount: signed_amount,
        currency: currency,
        date: date,
        name: name,
        source: "questrade",
        investment_activity_label: label,
        extra: { security_id: security&.id }.compact
      )
      @transactions_count += 1 if result
    end
end
