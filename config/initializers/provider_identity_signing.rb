# These secrets are independent of SECRET_KEY_BASE and Active Record encryption.
# Parse and validate lazily when evidence is used, so an unconfigured deployment
# can run normally while permanent-proof capture fails closed.
Rails.application.configure do
  options = config.x.provider_identity_signing
  {
    active_key_id: "PROVIDER_IDENTITY_SIGNING_KEY_ID",
    keys: "PROVIDER_IDENTITY_SIGNING_KEYS",
    legacy_v1_key_id: "PROVIDER_IDENTITY_LEGACY_V1_KEY_ID"
  }.each do |field, environment_key|
    options[field] = ENV[environment_key] if ENV.key?(environment_key)
  end
end
