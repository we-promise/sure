# Mixing currencies in Money arithmetic raises in development and test, so new
# code that forgets a conversion fails loudly there. Production reports it
# instead (see Money#ensure_same_currency!).
Rails.application.config.to_prepare do
  Money.strict_currency = Rails.env.local?
end
