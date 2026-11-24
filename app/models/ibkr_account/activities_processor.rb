class IbkrAccount::ActivitiesProcessor
  include IbkrAccount::DataHelpers

  # Flex `CashTransaction` types, upper-cased, and the label each is booked
  # with: fees are a Fee, interest is Interest, a payment in lieu is a
  # Dividend. Withholding tax carries the label of the income it was withheld
  # from (see cash_transaction_label), so dividends read net, as Trade
  # Republic books them. Every one keeps the sign IBKR gives it, so a
  # reversal, a refund or interest paid on margin moves cash the way it did at
  # IBKR.
  CASH_TRANSACTION_LABELS = {
    "DIVIDENDS" => "Dividend",
    "PAYMENT IN LIEU OF DIVIDENDS" => "Dividend",
    "WITHHOLDING TAX" => "Dividend",
    "OTHER FEES" => "Fee",
    "COMMISSION ADJUSTMENTS" => "Fee",
    "BROKER INTEREST RECEIVED" => "Interest",
    "BROKER INTEREST PAID" => "Interest",
    "BOND INTEREST RECEIVED" => "Interest",
    "BOND INTEREST PAID" => "Interest"
  }.freeze

  SUPPORTED_CASH_TRANSACTION_TYPES = [ "DEPOSITS/WITHDRAWALS", *CASH_TRANSACTION_LABELS.keys ].freeze

  # Stocks and ETFs (STK), mutual funds (FUND) and bonds (BOND). Others are
  # left out and reported (see capture_skipped_trade_types). A category added
  # here must resolve its trades to the security its positions resolve to.
  SUPPORTED_TRADE_ASSET_CATEGORIES = %w[STK FUND BOND].freeze

  def initialize(ibkr_account)
    @ibkr_account = ibkr_account
  end

  def process
    return { trades: 0, transactions: 0, failed_rows: [] } unless account.present?

    activities = (@ibkr_account.raw_activities_payload || {}).with_indifferent_access
    trades = Array(activities[:trades])
    cash_transactions = Array(activities[:cash_transactions])

    @failed_rows = []
    @skipped_trade_types = Hash.new(0)
    trade_results = trades.map { |trade| process_trade(trade.with_indifferent_access) }
    trades_count = trade_results.count { |r| r[:imported] }
    fee_count    = trade_results.sum   { |r| r[:fees] }
    capture_skipped_trade_types
    capture_bond_unit_disagreements

    @cash_transactions = cash_transactions.map(&:with_indifferent_access)
    @skipped_cash_types = Hash.new(0)
    cash_count = @cash_transactions.sum { |t| process_cash_transaction(t) ? 1 : 0 }
    capture_skipped_cash_types

    { trades: trades_count, transactions: cash_count + fee_count, failed_rows: @failed_rows }
  end

  private

    def account
      @ibkr_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_trade(row)
      return { imported: false, fees: 0 } unless supported_trade?(row)

      security = resolve_security(row)
      return { imported: false, fees: 0 } unless security

      quantity = parse_decimal(row[:quantity])
      native_price = parse_decimal(row[:trade_price])
      return { imported: false, fees: 0 } if quantity.nil? || native_price.nil?

      quantity *= quantity_multiplier(row)
      native_price *= price_scale(row)

      buy_sell = row[:buy_sell].to_s.upcase
      signed_quantity = buy_sell == "SELL" ? -quantity.abs : quantity.abs
      native_amount = buy_sell == "SELL" ? -(native_price * quantity.abs) : (native_price * quantity.abs)
      currency = extract_currency(row, fallback: @ibkr_account.currency)
      date = trade_date_for(row)
      external_id = "ibkr_trade_#{row[:trade_id]}"

      # The commission belongs to the trade: it goes into `trades.fee`, which
      # the cost basis and the realized gain read, and into the entry's amount,
      # which is what moves cash -- money out is positive, so it adds to a buy
      # and takes from a sell's proceeds, as the manual trade form does.
      #
      # A trade the user edited keeps the fee it has, and its cash follows that
      # fee. The import rewrites the rest of an edited trade, as it always has,
      # but it never wrote a fee before, so it must not start overwriting one
      # the user set.
      edited_fee = edited_trade_fee(external_id)
      commission = edited_fee.nil? ? folded_commission(row, currency) : nil
      fee = edited_fee || commission || 0

      Entry.transaction do
        import_adapter.import_trade(
          external_id: external_id,
          security: security,
          quantity: signed_quantity,
          price: native_price,
          amount: native_amount + fee,
          currency: currency,
          date: date,
          name: build_trade_name(security.ticker, signed_quantity, unit: bond?(row) ? "units" : "shares"),
          source: "ibkr",
          activity_label: buy_sell == "SELL" ? "Sell" : "Buy",
          exchange_rate: parse_decimal(row[:fx_rate_to_base])&.to_f,
          fee: fee
        )

        # Imported before the commission moved onto the trade, this would now
        # count it twice.
        legacy_commission_entry(row)&.destroy! if commission
      end

      # A commission not on the trade stays a transaction of its own, unless an
      # edited trade already carries a fee, which would count it twice.
      separate = commission.nil? && (edited_fee.nil? || edited_fee.zero?)
      fees = separate && import_commission_transaction(row, security, date) ? 1 : 0
      { imported: true, fees: fees }
    rescue => e
      @failed_rows << "trade #{row[:trade_id]}"
      Rails.logger.error("IbkrAccount::ActivitiesProcessor - Failed to process trade #{row[:trade_id]}: #{e.message}")
      { imported: false, fees: 0 }
    end

    def process_cash_transaction(row)
      return false unless supported_cash_transaction?(row)

      amount = parse_decimal(row[:amount])
      return false if amount.nil? || amount.zero?

      label, signed_amount = classify_cash_transaction(row, amount)
      return false unless label
      currency = extract_currency(row, fallback: @ibkr_account.currency)
      security = resolve_security_for_cash_transaction(row)

      import_adapter.import_transaction(
        external_id: "ibkr_cash_#{row[:transaction_id]}",
        amount: signed_amount,
        currency: currency,
        date: parse_date(row[:report_date]),
        name: build_cash_transaction_name(row, label, security),
        source: "ibkr",
        investment_activity_label: label,
        extra: {
          exchange_rate: parse_decimal(row[:fx_rate_to_base])&.to_f,
          security_id: security&.id,
          ibkr: {
            transaction_id: row[:transaction_id],
            type: row[:type],
            conid: row[:conid],
            amount: row[:amount],
            currency: row[:currency],
            fx_rate_to_base: row[:fx_rate_to_base],
            report_date: row[:report_date]
          }.compact
        }
      )

      true
    rescue => e
      @failed_rows << "cash #{row[:transaction_id]}"
      Rails.logger.error("IbkrAccount::ActivitiesProcessor - Failed to process cash transaction #{row[:transaction_id]}: #{e.message}")
      false
    end

    # The commission as a positive fee in the trade's currency, or nil when it
    # stays a transaction of its own: when there is none, when IBKR charged it
    # in another currency or did not say which -- `trades.fee` is in the
    # trade's, and the separate entry falls back to the account's -- or when the
    # separate commission entry from an earlier import is the user's: edited,
    # locked, or carrying a receipt.
    def folded_commission(row, trade_currency)
      commission = parse_decimal(row[:ib_commission])
      return nil if commission.nil? || commission.zero?

      return nil unless row[:ib_commission_currency].to_s.upcase == trade_currency
      legacy = legacy_commission_entry(row)
      return nil if legacy && users_commission_entry?(legacy)

      commission.abs
    end

    # Neither attaching a receipt nor an API edit made without the user-modified
    # flag marks an entry modified, and destroying it would take what the user
    # gave it with it. An API edit still locks what it changed, so a lock only a
    # person sets counts: one on the entry itself, or on its tags. A lock on the
    # category or merchant does not, since auto-categorization sets those too.
    def users_commission_entry?(entry)
      return true if entry.protected_from_sync? || entry.locked_attributes.present?

      transaction = entry.entryable
      transaction.is_a?(Transaction) && (transaction.attachments.attached? || transaction.locked?(:tag_ids))
    end

    # The fee of an existing trade the user edited, nil for any other.
    def edited_trade_fee(external_id)
      entry = account.entries.find_by(external_id: external_id, source: "ibkr")
      return nil unless entry&.protected_from_sync? && entry.entryable.is_a?(Trade)

      entry.entryable.fee || 0
    end

    def legacy_commission_entry(row)
      account.entries.find_by(external_id: "ibkr_trade_fee_#{row[:trade_id]}", source: "ibkr")
    end

    def import_commission_transaction(row, security, date)
      commission = parse_decimal(row[:ib_commission])
      return false if commission.nil? || commission.zero?

      currency = row[:ib_commission_currency].to_s.upcase.presence || @ibkr_account.currency
      ticker = security&.ticker || row[:symbol]

      result = import_adapter.import_transaction(
        external_id: "ibkr_trade_fee_#{row[:trade_id]}",
        amount: commission.abs,
        currency: currency,
        date: date,
        name: "Trade Commission for #{ticker}",
        source: "ibkr",
        investment_activity_label: "Fee",
        extra: {
          exchange_rate: parse_decimal(row[:fx_rate_to_base])&.to_f,
          security_id: security&.id,
          ibkr: {
            trade_id: row[:trade_id],
            transaction_id: row[:transaction_id],
            ib_commission: row[:ib_commission],
            ib_commission_currency: row[:ib_commission_currency],
            fx_rate_to_base: row[:fx_rate_to_base]
          }.compact
        }
      )

      !!result
    end

    def build_trade_name(ticker, signed_quantity, unit: "shares")
      action = signed_quantity.negative? ? "Sell" : "Buy"
      "#{action} #{signed_quantity.abs} #{unit} of #{ticker}"
    end

    def supported_trade?(row)
      category = asset_category(row)
      unless SUPPORTED_TRADE_ASSET_CATEGORIES.include?(category)
        # A currency conversion (CASH) is not a position; its two legs are
        # already in IBKR's cash and balance, so it is not reported.
        @skipped_trade_types[category.presence || "unknown"] += 1 unless category == "CASH"
        return false
      end

      row[:buy_sell].present? &&
        row[:conid].present? &&
        row[:currency].present? &&
        row[:quantity].present? &&
        row[:symbol].present? &&
        row[:trade_date].present? &&
        row[:trade_id].present? &&
        row[:trade_price].present? &&
        row[:transaction_id].present? &&
        fx_rate_available?(row)
    end

    def supported_cash_transaction?(row)
      type = row[:type].to_s.upcase.strip
      unless SUPPORTED_CASH_TRANSACTION_TYPES.include?(type)
        amount = parse_decimal(row[:amount])
        @skipped_cash_types[row[:type].to_s.strip] += 1 if amount.present? && !amount.zero?
        return false
      end
      return false unless row[:transaction_id].present? && row[:amount].present? && row[:currency].present? && row[:report_date].present?
      return false unless fx_rate_available?(row)

      type == "WITHHOLDING TAX" || CASH_TRANSACTION_LABELS[type] != "Dividend" || row[:conid].present?
    end

    # supported_cash_transaction? ensures only known types reach here.
    # IBKR's amount is negative for money out, Sure's is positive.
    def classify_cash_transaction(row, amount)
      type = row[:type].to_s.upcase.strip

      case type
      when "DEPOSITS/WITHDRAWALS"
        amount.positive? ? [ "Contribution", -amount.abs ] : [ "Withdrawal", amount.abs ]
      else
        [ cash_transaction_label(row, type), -amount ]
      end
    end

    # Tax withheld on a security's dividend reduces that dividend. Without a
    # conid it was withheld on credit interest, and on a bond it was withheld
    # from the coupon; both reduce the interest.
    def cash_transaction_label(row, type)
      return "Interest" if type == "WITHHOLDING TAX" && (row[:conid].blank? || bond_withholding?(row))

      CASH_TRANSACTION_LABELS[type]
    end

    # The row's asset category says so when the query includes it; otherwise a
    # bond interest row for the same conid in the statement does.
    def bond_withholding?(row)
      return true if bond?(row)

      @cash_transactions.any? do |other|
        other[:conid].to_s == row[:conid].to_s && other[:type].to_s.upcase.strip.start_with?("BOND INTEREST")
      end
    end

    # A skipped row with an amount is cash the account no longer accounts for.
    def capture_skipped_cash_types
      return if @skipped_cash_types.empty?

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Skipped IBKR cash transactions of unsupported types",
        source: self.class.name,
        provider_key: "ibkr",
        account_provider: @ibkr_account.account_provider,
        family: @ibkr_account.ibkr_item&.family,
        metadata: { ibkr_account_id: @ibkr_account.id, skipped_cash_transaction_types: @skipped_cash_types }
      )
    end

    # A trade whose proceeds are not quantity x its quoted price (quoted per
    # unit, or principal-adjusted) has its price carried to the proceeds, which
    # the trade's price shows.
    def capture_bond_unit_disagreements
      disagreements = bond_unit_disagreements(:trades)
      return if disagreements.empty?

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "IBKR bond trades priced to their reported value",
        source: self.class.name,
        provider_key: "ibkr",
        account_provider: @ibkr_account.account_provider,
        family: @ibkr_account.ibkr_item&.family,
        metadata: { ibkr_account_id: @ibkr_account.id, bonds: disagreements }
      )
    end

    # A skipped trade changed a position the holdings do not replay, so the
    # holdings history leaves it out.
    def capture_skipped_trade_types
      return if @skipped_trade_types.empty?

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Skipped IBKR trades of unsupported types",
        source: self.class.name,
        provider_key: "ibkr",
        account_provider: @ibkr_account.account_provider,
        family: @ibkr_account.ibkr_item&.family,
        metadata: { ibkr_account_id: @ibkr_account.id, skipped_trade_types: @skipped_trade_types }
      )
    end

    def build_cash_transaction_name(row, label, security = nil)
      type = row[:type].to_s.upcase.strip
      return label if type == "DEPOSITS/WITHDRAWALS"

      ticker = security&.ticker || security_symbol_for_conid(row[:conid])
      return "Dividend from #{ticker || row[:conid]}" if type == "DIVIDENDS"

      [ row[:type].to_s.strip, ticker ].compact.join(" for ")
    end

    # Resolved from the position or trade with the row's conid, so a coupon
    # lands on the same security as the bond it was paid on.
    def resolve_security_for_cash_transaction(row)
      source = security_row_for_conid(row[:conid])
      return nil if source.nil?

      resolve_security(source.slice(:symbol, :conid, :asset_category, :description))
    end

    def security_symbol_for_conid(conid)
      security_row_for_conid(conid)&.dig(:symbol)
    end

    def security_row_for_conid(conid)
      return nil if conid.blank?

      holding = Array(@ibkr_account.raw_holdings_payload).map(&:with_indifferent_access).find do |row|
        row[:conid].to_s == conid.to_s && row[:symbol].present?
      end
      return holding if holding

      activities = (@ibkr_account.raw_activities_payload || {}).with_indifferent_access
      Array(activities[:trades]).map(&:with_indifferent_access).find do |row|
        row[:conid].to_s == conid.to_s && row[:symbol].present?
      end
    end

    def fx_rate_available?(row)
      source_currency = extract_currency(row, fallback: nil)
      return false if source_currency.blank?
      return true if source_currency == @ibkr_account.currency

      row[:fx_rate_to_base].present?
    end
end
