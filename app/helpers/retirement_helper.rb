module RetirementHelper
  # Returns the display currency symbol/code for number_to_currency.
  # Maps common ISO codes to their symbols; falls back to the code itself.
  CURRENCY_SYMBOLS = { "EUR" => "€", "USD" => "$", "GBP" => "£", "CHF" => "CHF" }.freeze

  def retirement_currency_unit(config)
    CURRENCY_SYMBOLS.fetch(config.currency, config.currency)
  end
end
