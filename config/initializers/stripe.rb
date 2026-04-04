Rails.application.configure do
  config.x.stripe.one_time_contribution_url = ENV.fetch(
    "STRIPE_ONE_TIME_CONTRIBUTION_URL",
    "https://buy.stripe.com/3cIcN6euM23D7GQ3wT97G00"
  )
end
