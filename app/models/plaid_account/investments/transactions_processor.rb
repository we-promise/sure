class PlaidAccount::Investments::TransactionsProcessor
  SecurityNotFoundError = Class.new(StandardError)

  # Map Plaid investment transaction types to activity labels
  # All values must be valid Transaction::ACTIVITY_LABELS
  PLAID_TYPE_TO_LABEL = {
    "buy" => "Buy",
    "sell" => "Sell",
    "cancel" => "Other",
    "cash" => "Other",
    "fee" => "Fee",
    "transfer" => "Transfer",
    "dividend" => "Dividend",
    "interest" => "Interest",
    "contribution" => "Contribution",
    "withdrawal" => "Withdrawal",
    "dividend reinvestment" => "Reinvestment",
    "spin off" => "Other",
    "split" => "Other"
  }.freeze

  PERCENT_OF_PAR_TOLERANCE = BigDecimal("0.1")

  def initialize(plaid_account, security_resolver:)
    @plaid_account = plaid_account
    @security_resolver = security_resolver
  end

  def process
    transactions.each do |transaction|
      if cash_transaction?(transaction)
        find_or_create_cash_entry(transaction)
      else
        find_or_create_trade_entry(transaction)
      end
    end
  end

  private
    attr_reader :plaid_account, :security_resolver

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.current_account
    end

    def cash_transaction?(transaction)
      %w[cash fee transfer contribution withdrawal].include?(transaction["type"])
    end

    def find_or_create_trade_entry(transaction)
      resolved_security_result = security_resolver.resolve(plaid_security_id: transaction["security_id"])

      unless resolved_security_result.security.present?
        Sentry.capture_exception(SecurityNotFoundError.new("Could not find security for plaid trade")) do |scope|
          scope.set_tags(plaid_account_id: plaid_account.id)
        end

        return # We can't process a non-cash transaction without a security
      end

      external_id = transaction["investment_transaction_id"]
      return if external_id.blank?

      price = trade_price(transaction)

      import_adapter.import_trade(
        external_id: external_id,
        security: resolved_security_result.security,
        quantity: derived_qty(transaction),
        price: price,
        amount: derived_qty(transaction) * price,
        currency: transaction["iso_currency_code"],
        date: transaction["date"],
        name: transaction["name"],
        source: "plaid",
        activity_label: label_from_plaid_type(transaction)
      )
    end

    def find_or_create_cash_entry(transaction)
      external_id = transaction["investment_transaction_id"]
      return if external_id.blank?

      import_adapter.import_transaction(
        external_id: external_id,
        amount: transaction["amount"],
        currency: transaction["iso_currency_code"],
        date: transaction["date"],
        name: transaction["name"],
        source: "plaid",
        investment_activity_label: label_from_plaid_type(transaction)
      )
    end

    def label_from_plaid_type(transaction)
      plaid_type = transaction["type"]&.downcase
      PLAID_TYPE_TO_LABEL[plaid_type] || "Other"
    end

    def transactions
      plaid_account.raw_holdings_payload&.dig("transactions") || []
    end

    # Institutions quote some fixed income trades as a percent of par, so
    # quantity * price comes out 100x the cash amount. Plaid's amount can
    # include fees and accrued interest, so it isn't used as the price
    # directly; the price is only rescaled when the gap is close to 100x.
    def trade_price(transaction)
      price = transaction["price"].to_d
      quantity = transaction["quantity"].to_d.abs
      cash = transaction["amount"].to_d.abs
      return transaction["price"] if price.zero? || quantity.zero? || cash.zero?

      ratio = quantity * price / cash
      (ratio / 100 - 1).abs <= PERCENT_OF_PAR_TOLERANCE ? price / 100 : transaction["price"]
    end

    # Plaid unfortunately returns incorrect signage on some `quantity` values. They claim all "sell" transactions
    # are negative signage, but we have found multiple instances of production data where this is not the case.
    #
    # This method attempts to use several Plaid data points to derive the true quantity with the correct signage.
    def derived_qty(transaction)
      reported_qty = transaction["quantity"]
      abs_qty = reported_qty.abs

      if transaction["type"] == "sell" || transaction["amount"] < 0
        -abs_qty
      elsif transaction["type"] == "buy" || transaction["amount"] > 0
        abs_qty
      else
        reported_qty
      end
    end
end
