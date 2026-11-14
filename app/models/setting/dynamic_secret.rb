class Setting::DynamicSecret
  MARKER = "sure_provider_secret".freeze
  VERSION = 1
  ERROR_MESSAGE = "Provider secret could not be processed".freeze

  class << self
    def encrypt(key, value)
      return value if value.blank?
      return value unless Provider::ConfigurationRegistry.field_for_setting(key)&.secret

      { MARKER => VERSION, "ciphertext" => encryptor.encrypt_and_sign(value, purpose: purpose(key)) }
    rescue StandardError
      raise Setting::SecretError, ERROR_MESSAGE, cause: nil
    end

    def marked?(value)
      value.is_a?(Hash) && value.key?(MARKER)
    end

    def decrypt(key, value)
      return value unless marked?(value)

      unless value.keys.sort == [ "ciphertext", MARKER ].sort &&
          value[MARKER] == VERSION && value["ciphertext"].is_a?(String) && value["ciphertext"].present?
        raise Setting::SecretError, ERROR_MESSAGE
      end

      # Do not use decrypt_setting: its legacy fallback returns unauthenticated input.
      encryptor.decrypt_and_verify(value["ciphertext"], purpose: purpose(key)).tap do |plaintext|
        raise Setting::SecretError, ERROR_MESSAGE if plaintext.nil?
      end
    rescue StandardError
      raise Setting::SecretError, ERROR_MESSAGE, cause: nil
    end

    private
      def encryptor
        raise Setting::SecretError, ERROR_MESSAGE if Rails.application.secret_key_base.blank?

        Setting.send(:setting_encryptor)
      end

      def purpose(key)
        "dynamic_provider_setting:#{key}"
      end
  end
end
