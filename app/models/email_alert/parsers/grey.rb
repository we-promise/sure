# Grey wallet alerts (hello@grey.co): wallet funding, withdrawals and virtual
# card spend. Grey holds one wallet per currency, so the currency is the account
# identifier. Withdrawals can convert (USD tendered -> NGN received); the wallet
# is debited the tendered amount. No balance is included in these emails.
class EmailAlert::Parsers::Grey < EmailAlert::Parsers::Base
  configure key: "grey", institution_name: "Grey", domains: [ "grey.co" ], timezone: "UTC"

  LABELS = [
    "Transaction Type", "Amount tendered", "Amount received", "Memo", "Reference", "Date & Time",
    "Bank name", "Account name", "Account number", "Merchant", "Amount debited", "Description"
  ].freeze

  def parse
    case message.subject
    when /\AWallet Funding Successful\z/i then funding
    when /\AWithdrawal Successful\z/i then withdrawal
    when /\ACard transaction successful\z/i then card
    end
  end

  private

    def labels = LABELS

    def funding
      amount, currency = parse_money(value_for("Amount received"))
      return nil unless amount

      memo = value_for("Memo")
      build_for(currency, amount: amount, direction: :credit,
                description: [ "Grey wallet funding", memo.presence && "- #{memo}" ].compact.join(" "),
                details: { transaction_type: value_for("Transaction Type"),
                           amount_tendered: value_for("Amount tendered"), memo: memo }.compact)
    end

    def withdrawal
      amount, currency = parse_money(value_for("Amount tendered"))
      return nil unless amount

      recipient = value_for("Account name")
      bank = value_for("Bank name")
      build_for(currency, amount: amount, direction: :debit,
                description: [ "Withdrawal to #{recipient.presence || 'bank account'}", bank.presence && "(#{bank})" ].compact.join(" "),
                details: { transaction_type: value_for("Transaction Type"), amount_received: value_for("Amount received"),
                           counterparty_name: recipient, counterparty_bank: bank,
                           counterparty_account: value_for("Account number") }.compact)
    end

    def card
      amount, currency = parse_money(value_for("Amount debited"))
      return nil unless amount

      merchant = value_for("Merchant")
      build_for(currency, amount: amount, direction: :debit,
                description: merchant.present? ? "Card: #{merchant}" : (value_for("Description") || "Card transaction"),
                details: { merchant_name: merchant, card_type: value_for("Transaction type") }.compact)
    end

    def build_for(currency, **attrs)
      build(
        account_identifier: currency.downcase,
        account_name: "Grey #{currency}",
        currency: currency,
        occurred_at: parse_time(value_for("Date & Time").to_s.delete_suffix(" UTC"), "%m/%d/%Y - %l:%M %p"),
        reference: value_for("Reference"),
        **attrs
      )
    end
end
