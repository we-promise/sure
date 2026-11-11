# frozen_string_literal: true

module ActiveRecordEncryptionConfig
  ENV_KEYS = %w[
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  ].freeze

  # SECRET_KEY_BASE values ever shipped as a working default in
  # compose.example.yml / compose.example.ai.yml. Self-hosted installs that
  # deployed from one of those files without overriding it are running with
  # a publicly known secret. Since the auto-derived encryption keys
  # (config/initializers/active_record_encryption.rb) are a deterministic
  # function of SECRET_KEY_BASE, anyone with this value can compute the same
  # encryption keys, so `ready?` alone is not a meaningful signal of safety
  # for these installs even though it makes `runtime_configured?` true.
  KNOWN_COMPROMISED_SECRET_KEY_BASES = %w[
    a7523c3d0ae56415046ad8abae168d71074a79534a7062258f8d1d51ac2f76d3c3bc86d86b6b0b307df30d9a6a90a2066a3fa9e67c5e6f374dbd7dd4e0778e13
  ].freeze

  # Set only for the one-off commands of a key rotation (see the Docker
  # hosting guide): the SECRET_KEY_BASE whose derived keys encrypted the
  # existing data, so it still decrypts while the backfill moves it to the
  # current keys.
  PREVIOUS_SECRET_KEY_BASE_ENV = "ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE"

  # Previous-scheme key provider for keys derived from an old
  # SECRET_KEY_BASE. Rails derives every scheme's keys with the globally
  # configured salt, so the old salt needs a provider of its own. Keys are
  # derived on first use, once Rails has settled hash_digest_class.
  class DerivedKeyProvider
    def initialize(password, salt)
      @password = password
      @salt = salt
    end

    def encryption_key
      @encryption_key ||= begin
        config = ActiveRecord::Encryption.config
        secret = ActiveSupport::KeyGenerator.new(@password, hash_digest_class: config.hash_digest_class)
          .generate_key(@salt, ActiveRecord::Encryption.cipher.key_length)
        ActiveRecord::Encryption::Key.new(secret)
      end
    end

    def decryption_keys(_encrypted_message)
      [ encryption_key ]
    end
  end

  CONFIG_KEYS = %i[
    primary_key
    deterministic_key
    key_derivation_salt
  ].freeze

  module_function

  def complete_env?(env = ENV)
    ENV_KEYS.all? { |key| env_value_present?(env, key) }
  end

  def partial_env?(env = ENV)
    present_count = ENV_KEYS.count { |key| env_value_present?(env, key) }
    present_count.positive? && present_count < ENV_KEYS.count
  end

  def missing_env_keys(env = ENV)
    ENV_KEYS.reject { |key| env_value_present?(env, key) }
  end

  def partial_env_message(env = ENV)
    "Active Record encryption environment variables are partially configured. Missing: #{missing_env_keys(env).join(', ')}"
  end

  def credentials_configured?(credentials = Rails.application.credentials)
    credentials.active_record_encryption.present?
  rescue NoMethodError
    false
  end

  def runtime_configured?(config = Rails.application.config.active_record.encryption)
    CONFIG_KEYS.all? { |key| config.public_send(key).present? }
  rescue NoMethodError
    false
  end

  def explicitly_configured?
    complete_env? || credentials_configured?
  end

  def ready?
    explicitly_configured? || runtime_configured?
  end

  # Only meaningful for the auto-derived path: explicit env vars or Rails
  # credentials (explicitly_configured?) take precedence over SECRET_KEY_BASE
  # in config/initializers/active_record_encryption.rb, so an install that
  # set its own encryption keys but happens to still have this SECRET_KEY_BASE
  # value (e.g. never bothered rotating it because it isn't the key source)
  # is not actually affected and should not be warned.
  def using_known_compromised_secret_key_base?(secret_key_base = Rails.application.secret_key_base)
    return false if explicitly_configured?

    KNOWN_COMPROMISED_SECRET_KEY_BASES.include?(secret_key_base)
  rescue NoMethodError
    false
  end

  # The keys config/initializers/active_record_encryption.rb derives from
  # SECRET_KEY_BASE when no explicit keys are configured.
  def derived_keys(secret_key_base)
    CONFIG_KEYS.to_h do |key|
      [ key, Digest::SHA256.hexdigest("#{secret_key_base}:#{key}")[0..63] ]
    end
  end

  # Previous schemes for `config.active_record.encryption.previous`, built
  # from the keys derived from PREVIOUS_SECRET_KEY_BASE_ENV. Rails applies a
  # global previous scheme only to attributes with the same determinism, so
  # there is one scheme for each kind.
  def previous_schemes(env = ENV)
    old_base = env[PREVIOUS_SECRET_KEY_BASE_ENV]
    return [] if old_base.blank?

    keys = derived_keys(old_base)
    [
      { key_provider: DerivedKeyProvider.new(keys[:primary_key], keys[:key_derivation_salt]) },
      { deterministic: true, key_provider: DerivedKeyProvider.new(keys[:deterministic_key], keys[:key_derivation_salt]) }
    ]
  end

  def env_value_present?(env, key)
    env[key].present?
  end
end
