Rails.application.configure do
  config.x.enable_banking ||= ActiveSupport::OrderedOptions.new

  # Ceiling for requested consent duration (days). Used as the top rung of the
  # fallback ladder when an ASPSP doesn't advertise maximum_consent_validity,
  # and as a defensive cap against an implausibly large ASPSP-reported value.
  # Enable Banking's own default became 180 days in Oct 2025; the EU SCA
  # renewal window for account-information access was extended from 90 to
  # 180 days for the same reason. Set ENABLE_BANKING_CONSENT_DAYS to override.
  raw_configured_days = ENV["ENABLE_BANKING_CONSENT_DAYS"].presence
  configured_days = raw_configured_days.to_i if raw_configured_days&.match?(/\A\d+\z/)
  config.x.enable_banking.consent_days = (configured_days && configured_days.positive?) ? configured_days : 180
end
