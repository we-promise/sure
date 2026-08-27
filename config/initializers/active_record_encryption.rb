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
#
# Gated on ActiveRecordEncryptionConfig.backfill_completed? (see #3214)
# instead of being unconditional: leaving this on forever means a plaintext
# value that lands in an encrypted column later - a bug, a bad migration, a
# manual DB edit - would be silently accepted instead of raising, quietly
# undermining the integrity guarantee encryption exists to provide. The flag
# it checks is a versioned Setting, flipped by security:backfill_encryption
# only on a clean (zero-failure), non-dry-run completion, and defaults to
# "not complete" (fallback enabled) whenever it can't be read - fresh
# installs, pre-migration boots, or DB errors - so this preserves the
# original crash-safe behavior for anyone who hasn't backfilled yet.
#
# MUST stay a plain, synchronous call here (not deferred into
# after_initialize or any other lazy hook): ActiveRecord's own
# "active_record_encryption.configuration" railtie initializer registers an
# ActiveSupport.on_load(:active_record_encryption) callback that snapshots
# Rails.application.config.active_record.encryption.* into the real,
# long-lived ActiveRecord::Encryption.config object the FIRST time anything
# touches ActiveRecord::Base's connection (verified empirically: it's the
# ActiveRecord::Base.connection call inside backfill_completed? itself that
# fires this, since establishing a connection pulls in AR's encrypted-type
# machinery). That same connection touch also fires the separate
# ActiveSupport.on_load(:active_record) hook AR's railtie uses to decide,
# ONCE, whether to install ExtendedDeterministicQueries/
# ExtendedDeterministicUniquenessValidator support - based on whatever
# extend_queries was at that moment (still unset, since this all happens
# before this statement gets to set it). Setting
# Rails.application.config.active_record.encryption.* afterwards (below) is
# necessary for anything that reads it directly, but insufficient on its
# own for either of these: ActiveRecord::Encryption.config is patched
# directly so the encryption engine picks up the right value regardless of
# exactly when the snapshot fired, and install_support is called directly
# (idempotent - Module#prepend/include are no-ops if already applied) so
# deterministic queries/uniqueness validations against legacy plaintext
# rows actually work when extend_queries ends up true, instead of silently
# never getting the query-rewriting support installed. Deferring the whole
# block into after_initialize does NOT fix any of this - the snapshot
# always happens before after_initialize runs (also verified empirically) -
# and reading `Setting` (an autoloaded app/* constant) directly here isn't
# possible in the first place: Rails autoloading isn't available yet while
# config/initializers/*.rb are still being evaluated. See the comment on
# ActiveRecordEncryptionConfig.backfill_completed? (lib/
# active_record_encryption_config.rb) for why it reads the `settings` table
# via raw SQL instead.
encryption_fallback_enabled = !ActiveRecordEncryptionConfig.backfill_completed?
Rails.application.config.active_record.encryption.support_unencrypted_data = encryption_fallback_enabled
Rails.application.config.active_record.encryption.extend_queries = encryption_fallback_enabled
if defined?(ActiveRecord::Encryption)
  ActiveRecord::Encryption.config.support_unencrypted_data = encryption_fallback_enabled
  ActiveRecord::Encryption.config.extend_queries = encryption_fallback_enabled
  if encryption_fallback_enabled
    ActiveRecord::Encryption::ExtendedDeterministicQueries.install_support
    ActiveRecord::Encryption::ExtendedDeterministicUniquenessValidator.install_support
  end
end

# KNOWN LIMITATION: extend_queries does not reliably extend deterministic
# lookups to match legacy plaintext data for attributes that combine
# `encrypts ..., deterministic: true, downcase: true` with a model-level
# `normalizes` declaration on the same attribute - which is exactly
# User#email, User#unconfirmed_email, Invitation#email, and InviteCode#token
# (see app/models/user.rb's `normalizes :email, with: ->(email) {
# email.strip.downcase }`). Arel::Nodes::HomogeneousIn#casted_values calls
# #serialize on the *outermost* ActiveModel::Attributes::Normalization::
# NormalizedValueType wrapper, whose #cast runs the normalization proc
# directly on each query value - including extend_queries' internal
# AdditionalValue wrapper for the clean-text fallback, which doesn't
# respond to #strip. In production this makes `User.find_by(email:)`
# silently fail to match not-yet-backfilled legacy rows instead of raising
# (support_unencrypted_data still makes plain *reads* of already-loaded
# records work). Fixing this generically would mean patching the shared
# ActiveModel normalization type, which is used for unrelated attributes
# across the app - too invasive for this fix. Operators MUST run
# `bin/rails security:backfill_encryption` immediately after upgrading,
# before relying on login/invitation flows for accounts whose data
# predates this fix. Non-downcase deterministic fields (tokens, API keys,
# ...) are unaffected - confirmed in
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
