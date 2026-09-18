class Financekit::Mapping
  def self.transaction_amount(record)
    amount = Financekit::Payload.money!(record.fetch("amount"))
    record.fetch("amount").fetch("direction") == "credit" ? -amount : amount
  end

  def self.balance(record, accountable_type)
    money = record.key?("money") ? record.fetch("money") : record
    amount = Financekit::Payload.money!(money)
    positive = accountable_type == "CreditCard" ? "debit" : "credit"
    money.fetch("direction") == positive ? amount : -amount
  end

  def self.ledger_date(record, timezone)
    timestamp = Financekit::Payload.timestamp!(record["posted_at"] || record.fetch("transacted_at"))
    timestamp.in_time_zone(timezone).to_date
  end
end
