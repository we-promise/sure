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

  def using_known_compromised_secret_key_base?(secret_key_base = Rails.application.secret_key_base)
    KNOWN_COMPROMISED_SECRET_KEY_BASES.include?(secret_key_base)
  rescue NoMethodError
    false
  end

  def env_value_present?(env, key)
    env[key].present?
  end
end
