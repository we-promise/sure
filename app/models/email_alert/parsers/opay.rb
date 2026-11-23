# OPay "Transfer Successful" / "Payment Successful" alerts (no-reply@opay-nigeria.com).
#
# OPay emails debits only; credits arrive by push/SMS. Every debit states the
# available balance, which keeps the account balance right regardless.
# The Date header carries a wrong offset, so the body's local time is used.
class EmailAlert::Parsers::Opay < EmailAlert::Parsers::Base
  configure key: "opay", institution_name: "OPay", domains: [ "opay-nigeria.com" ], timezone: "Africa/Lagos"

  LABELS = [
    "Name", "Bank", "Account Number", "Amount", "Transaction No.", "Transaction Date",
    "Merchant Name", "Merchant Order Number"
  ].freeze

  def parse
    kind = message.subject[/\A(Transfer|Payment) Successful\z/i, 1]&.downcase
    return nil unless kind

    amount, currency = parse_money(line_after(/\AYour #{kind} of\z/i), default_currency: "NGN")
    return nil if amount.nil?

    balance, = parse_money(line_after(/\AYour available balance is\z/i), default_currency: currency)

    build(
      account_identifier: "wallet",
      account_name: "OPay",
      currency: currency,
      amount: amount,
      direction: :debit,
      occurred_at: occurred_at,
      description: kind == "transfer" ? transfer_description : payment_description,
      reference: value_for("Transaction No."),
      balance: balance,
      details: details_for(kind)
    )
  end

  private

    def labels = LABELS

    def occurred_at
      raw = value_for("Transaction Date").to_s.sub(/(\d+)(st|nd|rd|th),/i, '\1,')
      parse_time(raw, "%b %d, %Y %H:%M:%S")
    end

    def transfer_description
      name = value_for("Name")
      bank = value_for("Bank")
      [ "Transfer to #{name.presence || 'recipient'}", bank.presence && "(#{bank})" ].compact.join(" ")
    end

    def payment_description
      "Payment to #{value_for('Merchant Name').presence || 'merchant'}"
    end

    def details_for(kind)
      if kind == "transfer"
        { counterparty_name: value_for("Name"), counterparty_bank: value_for("Bank"),
          counterparty_account: value_for("Account Number") }.compact
      else
        { merchant_name: value_for("Merchant Name"), merchant_order_number: value_for("Merchant Order Number") }.compact
      end
    end
end
