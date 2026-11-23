# GTBank "GeNS" transaction notifications (GeNS@gtbank.com).
#
# Direction is only stated in the body ("a CREDIT transaction occurred"). An
# outward transfer produces three alerts: the transfer, "Commission on NIP
# Transfer" and "VAT", the fee ones with Remarks "CHARGES"; each is imported as
# its own transaction so the account matches the bank statement.
class EmailAlert::Parsers::Gtbank < EmailAlert::Parsers::Base
  configure key: "gtbank", institution_name: "GTBank", domains: [ "gtbank.com" ], timezone: "Africa/Lagos"

  LABELS = [
    "Account Number", "Transaction Location", "Description", "Amount", "Value Date",
    "Remarks", "Time of Transaction", "Document Number", "Current Balance", "Available Balance"
  ].freeze
  FEE_DESCRIPTION = /\A(commission on|vat\b|value added tax|sms alert|stamp duty|maintenance fee|card maintenance)/i

  def parse
    return nil unless message.from_address.start_with?("gens@")

    direction = text[/\ba\s+(CREDIT|DEBIT)\s+transaction occurred/i, 1]&.downcase&.to_sym
    amount, currency = parse_money(value_for("Amount"), default_currency: "NGN")
    account_number = value_for("Account Number").to_s
    return nil if direction.nil? || amount.nil? || account_number.empty?

    last_four = account_number.gsub(/\D/, "").last(4)
    description = value_for("Description").to_s
    remarks = value_for("Remarks")
    balance, = parse_money(value_for("Current Balance"), default_currency: currency)

    build(
      account_identifier: last_four,
      account_name: "GTBank ••#{last_four}",
      currency: currency,
      amount: amount,
      direction: direction,
      occurred_at: occurred_at,
      description: description.presence || remarks.presence || "GTBank #{direction}",
      reference: value_for("Document Number"),
      balance: balance,
      category_hint: fee?(description, remarks) ? :bank_fees : nil,
      details: { remarks: remarks, location: value_for("Transaction Location") }.compact
    )
  end

  private

    def labels = LABELS

    def occurred_at
      date = value_for("Value Date")
      time = value_for("Time of Transaction")
      parse_time("#{date} #{time}", "%Y-%m-%d %l:%M:%S %p") || parse_time(date, "%Y-%m-%d")
    end

    def fee?(description, remarks)
      remarks.to_s.casecmp?("CHARGES") || description.match?(FEE_DESCRIPTION)
    end
end
