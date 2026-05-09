# Port of PlaidAccount::Investments::TransactionsProcessor.
class Provider::Plaid::Investments::TransactionsProcessor
  SecurityNotFoundError = Class.new(StandardError)

  PLAID_TYPE_TO_LABEL = {
    "buy" => "Buy", "sell" => "Sell", "cancel" => "Other", "cash" => "Other",
    "fee" => "Fee", "transfer" => "Transfer", "dividend" => "Dividend",
    "interest" => "Interest", "contribution" => "Contribution",
    "withdrawal" => "Withdrawal", "dividend reinvestment" => "Reinvestment",
    "spin off" => "Other", "split" => "Other"
  }.freeze

  def initialize(provider_account, security_resolver:)
    @provider_account = provider_account
    @security_resolver = security_resolver
  end

  def process
    transactions.each do |t|
      cash_transaction?(t) ? find_or_create_cash_entry(t) : find_or_create_trade_entry(t)
    end
  end

  private
    attr_reader :provider_account, :security_resolver

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(provider_account.account)
    end

    def cash_transaction?(t)
      %w[cash fee transfer contribution withdrawal].include?(t["type"])
    end

    def find_or_create_trade_entry(t)
      result = security_resolver.resolve(plaid_security_id: t["security_id"])
      unless result.security.present?
        Sentry.capture_exception(SecurityNotFoundError.new("Could not find security for plaid trade")) do |scope|
          scope.set_tags(provider_account_id: provider_account.id)
        end
        return
      end

      external_id = t["investment_transaction_id"]
      return if external_id.blank?

      import_adapter.import_trade(
        external_id:    external_id,
        security:       result.security,
        quantity:       derived_qty(t),
        price:          t["price"],
        amount:         derived_qty(t) * t["price"],
        currency:       t["iso_currency_code"],
        date:           t["date"],
        name:           t["name"],
        source:         "plaid",
        activity_label: label_from_plaid_type(t)
      )
    end

    def find_or_create_cash_entry(t)
      external_id = t["investment_transaction_id"]
      return if external_id.blank?

      import_adapter.import_transaction(
        external_id:               external_id,
        amount:                    t["amount"],
        currency:                  t["iso_currency_code"],
        date:                      t["date"],
        name:                      t["name"],
        source:                    "plaid",
        investment_activity_label: label_from_plaid_type(t)
      )
    end

    def label_from_plaid_type(t)
      PLAID_TYPE_TO_LABEL[t["type"]&.downcase] || "Other"
    end

    def transactions
      provider_account.raw_holdings_payload&.dig("transactions") || []
    end

    # Plaid's quantity signage is unreliable on sells — derive from type+amount.
    def derived_qty(t)
      reported_qty = t["quantity"]
      abs_qty = reported_qty.abs
      if t["type"] == "sell" || t["amount"] < 0
        -abs_qty
      elsif t["type"] == "buy" || t["amount"] > 0
        abs_qty
      else
        reported_qty
      end
    end
end
