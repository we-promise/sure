class Financekit::Mapping
  # FinanceKit magnitudes plus explicit direction become Sure expense-positive,
  # income-negative amounts exactly once. Refunds and card payments are credits.
  def self.transaction_amount(record)
    amount = BigDecimal(record.fetch("amount"))
    record.fetch("credit_debit") == "credit" ? -amount : amount
  end

  # Assets: credit = money held, debit = overdraft. Liabilities: debit = owed,
  # credit = overpayment. Available credit is retained only as source metadata.
  def self.balance(record, accountable_type)
    amount = BigDecimal(record.fetch("amount"))
    positive = accountable_type == "CreditCard" ? "debit" : "credit"
    record.fetch("credit_debit") == positive ? amount : -amount
  end

  def self.ledger_date(record, timezone)
    timestamp = Financekit::Payload.timestamp!(record["posted_at"] || record.fetch("transacted_at"))
    timestamp.in_time_zone(timezone).to_date
  end
end
