require Rails.root.join("lib/active_record_encryption_config").to_s

# Until every existing row has been re-encrypted (see
# `bin/rails security:backfill_encryption`), plenty of installs still have
# genuinely plaintext data in columns that `encryption_ready?` now treats as
# encrypted (see #3142). Without these two settings, Rails raises
# ActiveRecord::Encryption::Errors::Decryption the moment any of that legacy
# data is read (e.g. an admin's or a self-hosted user's own email at login,
# via User#email's deterministic encryption) and deterministic lookups like
# `User.find_by(email:)` stop matching not-yet-backfilled rows entirely.
# Both default to false upstream and are meant exactly for this transition
# period; see https://guides.rubyonrails.org/active_record_encryption.html.
Rails.application.config.active_record.encryption.support_unencrypted_data = true
Rails.application.config.active_record.encryption.extend_queries = true

# KNOWN LIMITATION: extend_queries does not reliably extend deterministic
# lookups to match legacy plaintext data for attributes that combine
# `encrypts ..., deterministic: true, downcase: true` with a model-level
# `normalizes` declaration on the same attribute - which is exactly
# User#email and User#unconfirmed_email (see app/models/user.rb's
# `normalizes :email, with: ->(email) { email.strip.downcase }`).
# Arel::Nodes::HomogeneousIn#casted_values calls #serialize on the
# *outermost* ActiveModel::Attributes::Normalization::NormalizedValueType
# wrapper, whose #cast runs the normalization proc directly on each query
# value - including extend_queries' internal AdditionalValue wrapper for
# the clean-text fallback, which doesn't respond to #strip. In production
# this makes `User.find_by(email:)` (and Rails' own `User.authenticate_by`,
# which calls it internally) silently fail to match not-yet-backfilled
# legacy rows instead of raising (support_unencrypted_data still makes
# plain *reads* of already-loaded records work). Fixing this generically
# would mean patching the shared ActiveModel normalization type, which is
# used for unrelated attributes across the app - too invasive for this fix.
# Every production call site that looks a user up by email
# (app/controllers/sessions_controller.rb, password_resets_controller.rb,
# invitations_controller.rb, oidc_accounts_controller.rb, mcp_controller.rb,
# api/v1/auth_controller.rb, demo_family_refresh_job.rb) goes through
# User.find_by_email / User.authenticate_by_email instead of a bare
# find_by(email:) / authenticate_by(email:) - those fall back to a literal
# SQL match so login/invitation/password-reset flows keep working for
# not-yet-backfilled accounts even before an operator runs the backfill
# task. Still run `bin/rails security:backfill_encryption` immediately
# after upgrading so this fallback becomes unnecessary going forward.
# Other deterministic downcase+encrypted fields without a model-level
# `normalizes` declaration (Invitation#email, InviteCode#token) and
# non-downcase deterministic fields (tokens, API keys, ...) are unaffected
# by this specific bug - confirmed in
# test/initializers/active_record_encryption_test.rb.

if Rails.env.test?
  # Rails' fixture-time attribute encryption (encrypt_fixtures, set in
  # config/environments/test.rb) replaces a fixture's clean value with an
  # already-serialized ciphertext String. For jsonb/json columns, the
  # fixture loader's own column type-casting then serializes *that string*
  # again on insert, double-JSON-encoding it — the same failure mode as
  # rails/rails#48601 (encrypted fixtures + a non-string column type). The
  # result fails to decrypt and, thanks to support_unencrypted_data above,
  # falls back to the still-double-encoded String instead of the original
  # Hash/Array, breaking every consumer of the payload (e.g. `.to_h`).
  #
  # String-column fixtures (tokens, api keys, email, ...) round-trip fine
  # through encrypt_fixtures and keep exercising real encrypt/decrypt in
  # tests; only json/jsonb-typed attributes are exempted here, so their
  # fixtures load as plain values — read back correctly via
  # support_unencrypted_data, exactly like not-yet-backfilled legacy data.
  Rails.application.config.after_initialize do
    ActiveRecord::Encryption::EncryptedFixtures.module_eval do
      def encrypt_fixture_data(fixture, model_class)
        model_class&.encrypted_attributes&.each do |attribute_name|
          next unless (clean_value = fixture[attribute_name.to_s])

          type = model_class.type_for_attribute(attribute_name)
          next if type.cast_type.is_a?(ActiveRecord::Type::Json)

          @clean_values[attribute_name.to_s] = clean_value
          fixture[attribute_name.to_s] = type.serialize(clean_value)
        end
      end
    end
  end
end

# Configure Active Record encryption keys
# Priority order:
# 1. Environment variables (works for both managed and self-hosted modes)
# 2. Auto-generation from SECRET_KEY_BASE (self-hosted only, if credentials not present)
# 3. Rails credentials (fallback, handled in application.rb)

# Check if keys are provided via environment variables
primary_key = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
deterministic_key = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]

if ActiveRecordEncryptionConfig.partial_env?
  raise ActiveRecordEncryptionConfig.partial_env_message
end

# If all environment variables are present, use them (works for both managed and self-hosted)
if ActiveRecordEncryptionConfig.complete_env?
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
