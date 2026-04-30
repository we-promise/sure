module FxRegressionTestHelper
  def create_exchange_rate!(from:, to:, rate:, date: Date.current)
    ExchangeRate.create!(
      from_currency: from,
      to_currency: to,
      rate: rate,
      date: date
    )
  end

  def create_foreign_account!(family:, name: "Foreign Account", currency: "EUR", accountable: Depository.new)
    family.accounts.create!(
      name: name,
      currency: currency,
      balance: 0,
      accountable: accountable
    )
  end
end
