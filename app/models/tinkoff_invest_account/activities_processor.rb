require "digest"

class TinkoffInvestAccount::ActivitiesProcessor
  include TinkoffInvestAccount::DataHelpers

  attr_reader :failed_operations

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
    @failed_operations = []
    @seen_reconciliation_keys = Set.new
  end

  def process
    return { trades: 0, dividends: 0, transactions: 0 } unless account.present?

    counts = { trades: 0, dividends: 0, transactions: 0 }
    @failed_operations = []
    @seen_reconciliation_keys = Set.new

    Array(@tinkoff_invest_account.raw_operations_payload).each do |op|
      kind = process_operation(op)
      counts[kind] += 1 if kind
    end

    if @failed_operations.any?
      @tinkoff_invest_account.update!(raw_operations_payload: @failed_operations)
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

    def extract_trades_array(op)
      raw_trades = op["trades"].presence || op.dig("tradesInfo", "trades")
      Array(raw_trades)
    end

    def extract_trade_numbers(op)
      extract_trades_array(op).filter_map { |t| t["num"].to_s.strip.presence }.uniq.sort
    end

    def extract_quantity(op)
      raw_q = op["quantity"]
      if raw_q.present? && raw_q.to_s != "0"
        parsed = parse_decimal(raw_q)
        return parsed.abs if parsed && !parsed.zero?
      end

      trades = extract_trades_array(op)
      return BigDecimal("0") if trades.empty?

      trades.sum(BigDecimal("0")) { |t| (parse_decimal(t["quantity"]) || BigDecimal("0")).abs }
    end

    def process_operation(op)
      return nil unless executed?(op)

      op_id = op["id"].to_s.strip
      op_date = parse_date(op["date"])
      return nil unless op_date
      return nil if sync_start_date && op_date < sync_start_date

      op_type = normalize_op_type(op["type"])
      payment, currency = parse_money(op["payment"], portfolio_currency)
      payment ||= BigDecimal("0")
      price, = parse_money(op["price"], currency)
      accrued_int, = parse_money(op["accruedInt"], currency)
      qty = extract_quantity(op)
      trade_nums = extract_trade_numbers(op)

      return nil if op_id.blank? && trade_nums.empty?

      meta = op["resolved_instrument"] || {}
      ticker = (meta["ticker"].presence || op["ticker"].presence).to_s.strip.upcase
      security = resolve_security_for_op(op, meta, ticker)

      reconciliation_key = build_reconciliation_key(op, op_type, ticker, op_date, qty, payment, price, currency, trade_nums)
      return nil unless @seen_reconciliation_keys.add?(reconciliation_key)

      is_trade = trade_operation?(op_type, qty)
      external_id = reconcile_external_id(op_id, reconciliation_key, trade_nums, is_trade: is_trade)

      if is_trade
        return import_trade_operation(op, op_id, op_type, op_date, external_id, security, ticker, qty, price, accrued_int, payment, currency, reconciliation_key, trade_nums)
      end

      if BOND_REPAYMENT_TYPES.include?(op_type)
        return import_bond_repayment_cash(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency, reconciliation_key, trade_nums)
      end

      import_cash_operation(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency, reconciliation_key, trade_nums)
    rescue => e
      @failed_operations << op
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

    def import_trade_operation(_op, op_id, op_type, op_date, external_id, security, ticker, qty, price, accrued_int, payment, currency, reconciliation_key, trade_nums)
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

      entry = import_adapter.import_trade(
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

      persist_trade_reconciliation_extra(entry, op_id, op_type, ticker, security, reconciliation_key, trade_nums)

      :trades
    end

    def import_bond_repayment_cash(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency, reconciliation_key, trade_nums)
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
        extra: operation_extra(op_id, op_type, ticker, security, reconciliation_key: reconciliation_key, trade_numbers: trade_nums)
      )

      :transactions
    end

    def import_cash_operation(op, op_id, op_type, op_date, external_id, security, ticker, payment, currency, reconciliation_key, trade_nums)
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
        extra: operation_extra(op_id, op_type, ticker, security, reconciliation_key: reconciliation_key, trade_numbers: trade_nums)
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

    # T-Invest operation IDs can change on reloads or cursor overlaps, so key
    # entries by trade numbers (when present) or a natural execution signature.
    def build_reconciliation_key(op, op_type, ticker, op_date, qty, payment, price, currency, trade_nums)
      acct_id = @tinkoff_invest_account.tinkoff_invest_account_id.to_s
      if trade_nums.any?
        return [ "trades", acct_id, op_type, *trade_nums ].join("|")
      end

      instrument_key = op["instrumentUid"].presence || op["figi"].presence || ticker.presence || ""
      timestamp = canonical_timestamp(op["date"], fallback: op_date.iso8601)
      [
        "natural",
        acct_id,
        op_type,
        instrument_key,
        timestamp,
        qty.to_s("F"),
        payment.to_s("F"),
        currency,
        (price || BigDecimal("0")).to_s("F")
      ].join("|")
    end

    def canonical_timestamp(raw, fallback:)
      return fallback if raw.blank?

      Time.iso8601(raw.to_s).utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
    rescue ArgumentError
      raw.to_s.strip
    end

    def reconcile_external_id(op_id, reconciliation_key, trade_nums, is_trade:)
      stable_id = "tinkoff_invest_#{Digest::SHA256.hexdigest(reconciliation_key).first(32)}"

      return stable_id if account.entries.exists?(source: "tinkoff_invest", external_id: stable_id)

      if op_id.present?
        legacy_id = "tinkoff_invest_op_#{op_id}"
        return legacy_id if account.entries.exists?(source: "tinkoff_invest", external_id: legacy_id)
      end

      matched_external_id = find_reconciled_external_id(reconciliation_key, trade_nums, is_trade: is_trade)
      matched_external_id || stable_id
    end

    def find_reconciled_external_id(reconciliation_key, trade_nums, is_trade:)
      reconcile_needle = { tinkoff_invest: { reconciliation_key: reconciliation_key } }.to_json

      if is_trade
        scope = account.entries.where(source: "tinkoff_invest", entryable_type: "Trade")
          .joins("INNER JOIN trades ON trades.id = entries.entryable_id")
        by_key = scope.where("trades.extra @> ?", reconcile_needle).pick(:external_id)
        return by_key if by_key.present?
        return nil if trade_nums.empty?

        scope.where("jsonb_exists_any((trades.extra -> 'tinkoff_invest' -> 'trade_numbers'), ARRAY[?]::text[])", trade_nums).pick(:external_id)
      else
        scope = account.entries.where(source: "tinkoff_invest", entryable_type: "Transaction")
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        by_key = scope.where("transactions.extra @> ?", reconcile_needle).pick(:external_id)
        return by_key if by_key.present?
        return nil if trade_nums.empty?

        scope.where("jsonb_exists_any((transactions.extra -> 'tinkoff_invest' -> 'trade_numbers'), ARRAY[?]::text[])", trade_nums).pick(:external_id)
      end
    end

    def persist_trade_reconciliation_extra(entry, op_id, op_type, ticker, security, reconciliation_key, trade_nums)
      trade = entry&.entryable
      return unless trade.is_a?(Trade)

      payload = operation_extra(op_id, op_type, ticker, security, reconciliation_key: reconciliation_key, trade_numbers: trade_nums)
      merged = (trade.extra || {}).merge(
        "security_id" => payload[:security_id],
        "tinkoff_invest" => payload[:tinkoff_invest].transform_keys(&:to_s)
      ).compact
      trade.update!(extra: merged) if trade.extra != merged
    end

    def operation_extra(op_id, op_type, ticker, security, reconciliation_key: nil, trade_numbers: [])
      tinvest_meta = {
        operation_id: op_id.presence,
        type: op_type,
        ticker: ticker.presence,
        reconciliation_key: reconciliation_key,
        trade_numbers: trade_numbers.presence
      }.compact

      {
        security_id: security&.id,
        tinkoff_invest: tinvest_meta
      }.compact
    end
end
