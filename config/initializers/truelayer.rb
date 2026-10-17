Rails.application.configure do
  # Years of history to request straight after a bank is connected, while UK
  # banks still release more than 90 days (TRUELAYER_BACKFILL_YEARS, default 7).
  years = Integer(ENV.fetch("TRUELAYER_BACKFILL_YEARS", "7"), exception: false)
  config.x.truelayer.backfill_years = years&.between?(1, 20) ? years : 7
end
