class TinkoffInvestAccount::ActivitiesProcessor
  include TinkoffInvestAccount::DataHelpers

  BUY_TYPES = %w[BUY BUY_CARD].freeze
  SELL_TYPES = %w[SELL SELL_CARD].freeze
  BOND_REPAYMENT_TYPES = %w[BOND_REPAYMENT BOND_REPAYMENT_FULL].freeze
  DIVIDEND_TYPES = %w[DIVIDEND DIVIDEND_TRANSFER].freeze
  INTEREST_TYPES = %w[COUPON OVERNIGHT].freeze
  FEE_TYPES = %w[
    BROKER_FEE SERVICE_FEE MARGIN_FEE SUCCESS_FEE TRACK_MFEE TRACK_PFEE
    CASH_COMMISSION EXCHANGE_COMMISSION OUT_STAMP_DUTY FEE
  ].freeze
  TAX_TYPES = %w[
    TAX DIVIDEND_TAX BENEFIT_TAX SECURITY_TAX TAX_PROGRESSIVE
    TAX_DIVIDEND_PROGRESSIVE TAX_COUPON_PROGRESSIVE TAX_REFUND
    TAX_CORRECTION TAX_CORRECTION_PROGRESSIVE TAX_CORRECTION_COUPON
  ].freeze
  INPUT_TYPES = %w[INPUT INP_MULTI INPUT_SWIFT].freeze
  OUTPUT_TYPES = %w[OUTPUT OUT_MULTI OUTPUT_SWIFT].freeze

  EXECUTED_STATES = [ "", "EXECUTED", "OPERATION_STATE_EXECUTED" ].freeze

  def initialize(tinkoff_invest_account)
    @tinkoff_invest_account = tinkoff_invest_account
  end

  def process
    return { trades: 0, dividends: 0, transactions: 0 } unless account.present?

    counts = { trades: 0, dividends: 0, transactions: 0 }

    Array(@tinkoff_invest_account.raw_operations_payload).each do |op|
      kind = process_operation(op)
      counts[kind] += 1 if kind
    end

    counts
  end

  private

    def account
      @tinkoff_invest_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def portfolio_currency
      @tinkoff_invest_account.currency || "RUB"
    end

    def sync_start_date
      @tinkoff_invest_account.tinkoff_invest_item.sync_start_date&.to_date
    end

    def executed?(op)
      EXECUTED_STATES.include?(op["state"].to_s.strip.upcase)
    end

    def normalize_op_type(raw_type)
      raw_type.to_s.strip.upcase.delete_prefix("OPERATION_TYPE_")
    end

    def extract_quantity(op)
      raw_q = op["quantity"]
      if raw_q.present? && raw_q.to_s != "0"
        parsed = parse_decimal(raw_q)
        return parsed.abs if parsed && !parsed.zero?
      end

      trades = Array(op["trades"])
      return BigDecimal("0") if trades.empty?

      trades.sum(BigDecimal("0")) { |t| (parse_decimal(t["quantity"]) || BigDecimal("0")).abs }
    end

    def process_operation(op)
      return nil unless executed?(op)

      op_id = op["id"].to_s.strip
      return nil if op_id.blank?

      op_date = parse_date(op["date"])
      return nil unless op_date
      return nil if sync_start_date && op_date < sync_start_date

      op_type = normalize_op_type(op["type"])
      external_id = "tinkoff_invest_op_#{op_id}"

      payment, currency = parse_money(op["payment"], portfolio_currency)
      payment ||= BigDecimal("0")
      price, = parse_money(op["price"], currency)
      accrued_int, = parse_money(op["accruedInt"], currency)
      qty = extract_quantity(op)

      meta = op["resolved_instrument"] || {}
      ticker = (meta["ticker"].presence || op["ticker"].presence).to_s.strip.upcase
      security = resolve_security_for_op(op, meta, ticker)

      if trade_operation?(op_type, qty)
        return import_trade_operation(op, op_id, op_type, op_date, external_id, security, ticker, qty, price, accrued_int, payment, currency)
      end

      if BOND_REPAYMENT_TYPES.include?(op_type)
        return import_bond_repayment_cash(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency)
      end

      import_cash_operation(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency)
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "TinkoffInvestAccount::ActivitiesProcessor - Failed to process operation #{op['id']}: #{e.message}",
        source: "tinkoff_invest",
        family: @tinkoff_invest_account.tinkoff_invest_item.family,
        provider_key: "tinkoff_invest",
        metadata: { operation_id: op["id"], tinkoff_invest_account_id: @tinkoff_invest_account.id }
      )
      nil
    end

    def resolve_security_for_op(op, meta, ticker)
      return nil if ticker.blank?

      resolve_security(
        ticker: ticker,
        exchange_operating_mic: meta["exchange_operating_mic"],
        country_code: meta["country_code"],
        name: meta["name"].presence || op["name"].presence || ticker,
        logo_url: meta["logo_url"]
      )
    end

    def trade_operation?(op_type, qty)
      BUY_TYPES.include?(op_type) ||
        SELL_TYPES.include?(op_type) ||
        (BOND_REPAYMENT_TYPES.include?(op_type) && qty.positive?)
    end

    def import_trade_operation(_op, _op_id, op_type, op_date, external_id, security, _ticker, qty, price, accrued_int, payment, currency)
      return nil unless qty.positive? && security

      is_buy = BUY_TYPES.include?(op_type)
      signed_qty = is_buy ? qty : -qty

      mag_amount = if !payment.zero?
        payment.abs
      else
        unit_p = price ? price.abs : BigDecimal("0")
        (qty * unit_p) + (accrued_int ? accrued_int.abs : BigDecimal("0"))
      end

      unit_price = price&.positive? ? price.abs : (mag_amount / qty)
      signed_amount = is_buy ? mag_amount : -mag_amount

      import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: signed_qty,
        price: unit_price,
        amount: signed_amount,
        currency: currency,
        date: op_date,
        source: "tinkoff_invest",
        activity_label: is_buy ? "Buy" : "Sell"
      )

      :trades
    end

    def import_bond_repayment_cash(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency)
      return nil if payment.zero?

      name = ticker.present? ? "Bond principal repayment (#{ticker})" : (op["name"].presence || op["description"].presence || "Bond repayment")

      import_adapter.import_transaction(
        external_id: external_id,
        amount: -payment,
        currency: currency,
        date: op_date,
        name: name,
        source: "tinkoff_invest",
        investment_activity_label: "Other",
        notes: "T-Invest #{op_type} (#{op_id})",
        extra: operation_extra(op_id, op_type, ticker, security)
      )

      :transactions
    end

    def import_cash_operation(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency)
      return nil if payment.zero?

      label, kind, name = classify_cash_operation(op, op_type, ticker, payment)
      sure_amount = cash_amount_for_sure(op_type, payment)

      import_adapter.import_transaction(
        external_id: external_id,
        amount: sure_amount,
        currency: currency,
        date: op_date,
        name: name,
        kind: kind,
        source: "tinkoff_invest",
        investment_activity_label: label,
        notes: operation_notes(op_type, op_id, ticker),
        extra: operation_extra(op_id, op_type, ticker, security)
      )

      label == "Dividend" ? :dividends : :transactions
    end

    def classify_cash_operation(op, op_type, ticker, payment)
      desc = op["name"].presence || op["description"].presence

      if DIVIDEND_TYPES.include?(op_type)
        [ "Dividend", "standard", ticker.present? ? "Dividend from #{ticker}" : (desc || "Dividend") ]
      elsif INTEREST_TYPES.include?(op_type)
        default_name = op_type == "COUPON" && ticker.present? ? "Coupon from #{ticker}" : "Interest"
        [ "Interest", "standard", desc || default_name ]
      elsif FEE_TYPES.include?(op_type)
        [ "Fee", "standard", desc || "Brokerage fee (#{op_type})" ]
      elsif TAX_TYPES.include?(op_type)
        if payment.positive?
          [ "Other", "standard", desc || "Tax refund" ]
        else
          [ "Fee", "standard", desc || "Tax (#{op_type})" ]
        end
      elsif INPUT_TYPES.include?(op_type)
        [ "Contribution", "investment_contribution", desc || "Brokerage deposit" ]
      elsif OUTPUT_TYPES.include?(op_type)
        [ "Withdrawal", "funds_movement", desc || "Brokerage withdrawal" ]
      else
        [ "Other", "standard", desc || "T-Invest #{op_type}" ]
      end
    end

    # Sure convention: cash inflow is negative, cash outflow is positive.
    def cash_amount_for_sure(op_type, payment)
      return -payment.abs if INPUT_TYPES.include?(op_type)
      return payment.abs if OUTPUT_TYPES.include?(op_type)

      -payment
    end

    def operation_notes(op_type, op_id, ticker)
      base = "T-Invest #{op_type} (#{op_id})"
      ticker.present? ? "#{base} [#{ticker}]" : base
    end

    def operation_extra(op_id, op_type, ticker, security)
      {
        security_id: security&.id,
        tinkoff_invest: {
          operation_id: op_id,
          type: op_type,
          ticker: ticker.presence
        }.compact
      }.compact
    end
end
