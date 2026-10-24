# frozen_string_literal: true

# Records a buy/sell of a security in an investment (or crypto-exchange) account.
#
# It writes through the same Trade::CreateForm that the app's own "New trade"
# form and the public API (Api::V1::TradesController#create) use, so the signed
# quantity, the entry amount (qty * price + fee), the saved-attribute lock and
# the post-create account sync behave exactly as they do for a trade entered by
# hand.
#
# Exposed on the shared Assistant.function_classes registry, so it is callable
# from both the /mcp endpoint and the in-app assistant.
class Assistant::Function::CreateTrade < Assistant::Function
  SUPPORTED_TYPES = %w[buy sell].freeze

  class << self
    # The tool's stable name; this is the MCP function identifier callers use.
    def name
      "create_trade"
    end

    # Human/LLM-facing description of what the tool does and how to call it.
    def description
      <<~INSTRUCTIONS
        Records a buy or sell of a security in one of the user's investment or
        crypto-exchange accounts. The entry is created through the same path the
        app's trade form uses, so the quantity sign, the entry amount
        (qty * price + fee), the cost-basis lock and the account sync all behave
        as they do for a trade entered by hand.

        Ticker: prefer the combobox form "TICKER|MIC" (e.g. "AAPL|XNAS",
        "PETR4|BVMF") so the security resolves to the right listing. A plain
        ticker is also accepted. For assets the price provider does not know
        (private holdings, real-estate funds), pass `manual_ticker` instead: it
        is stored as an offline security and never priced by a provider.

        Only buy and sell are handled here. Dividends, interest, fees and
        deposits/withdrawals are recorded through the app's own trade form.

        Example:

        ```
        create_trade({
          account_id: "abc123-...",
          date: "2026-10-10",
          type: "buy",
          ticker: "AAPL|XNAS",
          qty: 10,
          price: 214.5,
          fee: 4.9
        })
        ```
      INSTRUCTIONS
    end
  end

  # Not strict: the tool validates its own inputs and returns structured error
  # hashes instead of raising, so a bad call is reported back to the model.
  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id date type qty price],
      properties: {
        account_id: {
          type: "string",
          description: "UUID of the investment or crypto account. The user must be able to write to it (owner or full-control share)."
        },
        date: {
          type: "string",
          description: "ISO 8601 date (YYYY-MM-DD) of the trade."
        },
        type: {
          type: "string",
          enum: SUPPORTED_TYPES,
          description: "Trade side: buy or sell."
        },
        ticker: {
          type: "string",
          description: "Security ticker, preferably in \"TICKER|MIC\" form (e.g. \"AAPL|XNAS\")."
        },
        manual_ticker: {
          type: "string",
          description: "Offline/unpriced asset symbol. Use instead of `ticker` when the price provider does not know the asset."
        },
        qty: {
          type: "number",
          description: "Positive quantity of shares/units. The sign is derived from `type`."
        },
        price: {
          type: "number",
          description: "Unit price in the trade currency. Must be positive."
        },
        fee: {
          type: "number",
          description: "Optional brokerage fee, added to the entry amount."
        },
        currency: {
          type: "string",
          description: "Optional ISO 4217 code. Defaults to the account's currency."
        }
      }
    )
  end

  def call(params = {})
    account = resolve_account(params["account_id"])
    return error("account_not_found", "No writable account with that id.") unless account

    unless account.supports_trades?
      return error("unsupported_account", "Only investment and crypto exchange accounts can record trades.")
    end

    type = params["type"].to_s.strip.downcase
    return error("invalid_type", "type must be one of #{SUPPORTED_TYPES.join(', ')}.") unless SUPPORTED_TYPES.include?(type)

    date = parse_date(params["date"])
    return error("invalid_date", "date must be an ISO 8601 date (YYYY-MM-DD).") unless date

    qty = parse_decimal(params["qty"])
    price = parse_decimal(params["price"])
    return error("invalid_quantity", "qty must be a positive number.") unless qty&.positive?
    return error("invalid_price", "price must be a positive number.") unless price&.positive?

    ticker = params["ticker"].to_s.strip.presence
    manual_ticker = params["manual_ticker"].to_s.strip.presence
    return error("security_required", "Provide `ticker` or `manual_ticker`.") if ticker.blank? && manual_ticker.blank?

    currency = (params["currency"].to_s.strip.presence || account.currency.presence || family.primary_currency_code).to_s.upcase
    return error("invalid_currency", "currency must be a valid ISO 4217 code.") unless valid_currency?(currency)

    fee = parse_decimal(params["fee"])
    fee = BigDecimal(0) if fee.nil?
    return error("invalid_fee", "fee must be a non-negative number.") if fee.negative?

    # Mirrors Api::V1::TradesController#create: the form signs the quantity from
    # `type` and builds the entry, resolving/creating the security on the way.
    entry = Trade::CreateForm.new(
      account: account,
      date: date,
      currency: currency,
      qty: qty,
      price: price,
      fee: fee,
      ticker: ticker,
      manual_ticker: manual_ticker,
      type: type
    ).create

    unless entry&.persisted?
      messages = entry.respond_to?(:errors) ? entry.errors.full_messages.join("; ") : nil
      return error("validation_failed", messages.presence || "Trade could not be created.")
    end

    {
      success: true,
      created: true,
      trade: serialize(entry),
      message: "Recorded #{entry.name} (#{format_money(entry)} on #{date.iso8601})."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    # A writable account, scoped the same way CreateTransaction scopes its
    # accounts (owner or full-control share). Nil is reported as not_found.
    def resolve_account(account_id)
      return nil unless valid_uuid?(account_id)

      family.accounts.writable_by(user).find_by(id: account_id)
    end

    def serialize(entry)
      trade = entry.entryable

      {
        id: trade.id,
        entry_id: entry.id,
        date: entry.date,
        name: entry.name,
        side: trade.qty.to_d.negative? ? "sell" : "buy",
        qty: trade.qty.to_d.abs.to_f,
        price: trade.price.to_d.to_f,
        fee: trade.fee.to_d.to_f,
        amount: format_money(entry),
        currency: entry.currency,
        account: entry.account.name,
        security: trade.security && {
          id: trade.security_id,
          ticker: trade.security.ticker,
          name: trade.security.name
        }
      }
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def parse_decimal(value)
      return nil if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def valid_currency?(code)
      Money::Currency.new(code)
      true
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      false
    end

    def format_money(entry)
      entry.amount_money.format
    rescue StandardError
      "#{entry.amount} #{entry.currency}"
    end

    def error(key, message, extras = {})
      { success: false, error: key, message: message }.merge(extras)
    end
end
