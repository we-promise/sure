# Configure Active Record encryption keys
# Priority order:
# 1. Environment variables (works for both managed and self-hosted modes)
# 2. Auto-generation from SECRET_KEY_BASE (self-hosted only, if credentials not present)
# 3. Rails credentials (fallback, handled in application.rb)

# Check if keys are provided via environment variables
primary_key = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
deterministic_key = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]

# If all environment variables are present, use them (works for both managed and self-hosted)
if primary_key.present? && deterministic_key.present? && key_derivation_salt.present?
  Rails.application.config.active_record.encryption.primary_key = primary_key
  Rails.application.config.active_record.encryption.deterministic_key = deterministic_key
  Rails.application.config.active_record.encryption.key_derivation_salt = key_derivation_salt
elsif Rails.application.config.app_mode.self_hosted? && !Rails.application.credentials.active_record_encryption.present?
  # For self-hosted instances without credentials or env vars, auto-generate keys
  # Use SECRET_KEY_BASE as the seed for deterministic key generation
  # This ensures keys are consistent across container restarts
  secret_base = Rails.application.secret_key_base

  # Generate deterministic keys from the secret base
  primary_key = Digest::SHA256.hexdigest("#{secret_base}:primary_key")[0..63]
  deterministic_key = Digest::SHA256.hexdigest("#{secret_base}:deterministic_key")[0..63]
  key_derivation_salt = Digest::SHA256.hexdigest("#{secret_base}:key_derivation_salt")[0..63]

  # Configure Active Record encryption
  Rails.application.config.active_record.encryption.primary_key = primary_key
  Rails.application.config.active_record.encryption.deterministic_key = deterministic_key
  Rails.application.config.active_record.encryption.key_derivation_salt = key_derivation_salt
end
# If none of the above conditions are met, credentials from application.rb will be used
