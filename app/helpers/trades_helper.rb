module TradesHelper
  # Options for the sale picker: what the account holds on +date+, each with
  # its quantity, keyed by security id so the choice cannot resolve to another
  # security with the same ticker.
  def held_security_options(account, date)
    return [] unless account

    account.held_securities_on(date).map do |security, qty|
      label = t(
        "trades.form.held_security",
        name: security.name.presence || security.ticker,
        ticker: security.ticker,
        qty: number_with_precision(qty, precision: 8, strip_insignificant_zeros: true)
      )

      [ label, security.id ]
    end
  end
end
