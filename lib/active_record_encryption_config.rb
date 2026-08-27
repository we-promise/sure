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
    config = credentials.active_record_encryption
    return false unless config.present?

    CONFIG_KEYS.all? { |key| config.public_send(key).present? }
  rescue NoMethodError
    false
  end

  # Unlike partial_env? (ENV vars), a present-but-incomplete Rails credentials
  # block does NOT fall through to auto-generation from SECRET_KEY_BASE - see
  # config/initializers/active_record_encryption.rb's `elsif ... &&
  # !Rails.application.credentials.active_record_encryption.present?` guard.
  # Left unchecked this silently disables encryption entirely (ready? / thus
  # every model's `encrypts` declaration goes false) instead of failing loudly
  # like the equivalent partial-ENV case does.
  def partial_credentials?(credentials = Rails.application.credentials)
    config = credentials.active_record_encryption
    return false unless config.present?

    present_count = CONFIG_KEYS.count { |key| config.public_send(key).present? }
    present_count.positive? && present_count < CONFIG_KEYS.count
  rescue NoMethodError
    false
  end

  def missing_credential_keys(credentials = Rails.application.credentials)
    config = credentials.active_record_encryption
    return CONFIG_KEYS.dup unless config.present?

    CONFIG_KEYS.reject { |key| config.public_send(key).present? }
  rescue NoMethodError
    CONFIG_KEYS.dup
  end

  def partial_credentials_message(credentials = Rails.application.credentials)
    "Active Record encryption Rails credentials are partially configured. Missing: #{missing_credential_keys(credentials).join(', ')}"
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

  # Deliberately independent of explicitly_configured?/ready?: this is a fact
  # about SECRET_KEY_BASE itself, not about whether Active Record Encryption's
  # own keys happen to be derived from it. Explicit AR keys only mean AR
  # encryption isn't affected - SECRET_KEY_BASE also signs/encrypts Rails
  # session cookies and is the sole key source for Setting's own encryptor
  # (app/models/setting.rb's setting_encryptor), independently of AR
  # encryption config. A previous version of this method returned false
  # whenever explicitly_configured? was true, which suppressed the warning
  # in config/initializers/encryption_warning.rb entirely for installs with
  # explicit AR keys - even though their sessions and Setting-encrypted
  # provider/AI API keys remained trivially crackable by anyone who knows
  # this public compromised value. See ActiveRecordEncryptionConfig#ready?
  # for the (separate) question of whether AR encryption itself is affected.
  def using_known_compromised_secret_key_base?(secret_key_base = Rails.application.secret_key_base)
    KNOWN_COMPROMISED_SECRET_KEY_BASES.include?(secret_key_base)
  rescue NoMethodError
    false
  end

  def env_value_present?(env, key)
    env[key].present?
  end
end
