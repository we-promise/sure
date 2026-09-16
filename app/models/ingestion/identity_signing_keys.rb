require "base64"
require "digest"
require "json"
require "openssl"

# Permanent evidence has its own retained keys. Application-secret or encryption
# key rotation must never silently select a different signing or verification key.
class Ingestion::IdentitySigningKeys
  class InvalidConfiguration < StandardError; end
  class InvalidSignature < StandardError; end

  VERSION = 1
  DOMAIN = "provider-financial-identities/signature/v1".freeze
  MAX_KEYS = 32
  MAX_CONFIG_BYTES = 16 * 1024
  KEY_ID = /\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,63}\z/
  DIGEST = /\A[0-9a-f]{64}\z/

  def self.configured
    new(Rails.application.config.x.provider_identity_signing)
  end

  def initialize(configuration = {})
    unless configuration.is_a?(Hash) && configuration.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } &&
        configuration.keys.map(&:to_s).uniq.size == configuration.size &&
        (configuration.keys.map(&:to_s) - %w[active_key_id keys legacy_v1_key_id]).empty?
      raise InvalidConfiguration, "Identity signing configuration has unsupported fields"
    end
    configuration = configuration.stringify_keys
    @keys = decode_keys(configuration["keys"])
    @active_key_id = configured_id(configuration["active_key_id"])
    @legacy_v1_key_id = configured_id(configuration["legacy_v1_key_id"])
    if [ @active_key_id, @legacy_v1_key_id ].compact.any? { |id| !@keys.key?(id) }
      raise InvalidConfiguration, "Identity signing configuration references an unavailable key"
    end
    # A small opaque revision invalidates transaction-local proof reuse when the
    # retained key policy changes. It is never included in a proof or diagnostics.
    @cache_token = Digest::SHA256.hexdigest(JSON.generate([
      @active_key_id, @legacy_v1_key_id, @keys.sort.map { |id, key| [ id, Base64.strict_encode64(key) ] }
    ])).freeze
    freeze
  rescue JSON::ParserError, ArgumentError
    raise InvalidConfiguration, "Identity signing keys must be a bounded keyring of Base64 32-byte secrets", cause: nil
  end

  attr_reader :cache_token

  def sign(message)
    raise InvalidConfiguration, "An explicit active identity signing key is required" unless @active_key_id
    { "version" => VERSION, "key_id" => @active_key_id,
      "digest" => hmac(@keys.fetch(@active_key_id), authenticated_message(message, @active_key_id)) }.freeze
  end

  def verify!(signature, message)
    if signature.is_a?(Hash) && signature.keys.all? { |key| key.is_a?(String) } && signature.keys.sort == %w[digest key_id version] &&
        signature["version"] == VERSION && valid_id?(signature["key_id"]) && valid_digest?(signature["digest"])
      key = @keys[signature["key_id"]]
      expected = key && hmac(key, authenticated_message(message, signature["key_id"]))
      actual = signature["digest"]
    elsif valid_digest?(signature) && @legacy_v1_key_id
      # Unversioned proofs use exactly one explicitly designated historical
      # derived key and their original message encoding. Never try every key.
      expected = hmac(@keys.fetch(@legacy_v1_key_id), message)
      actual = signature
    end
    unless expected && ActiveSupport::SecurityUtils.secure_compare(actual, expected)
      raise InvalidSignature, "Identity evidence has an unknown signing key or invalid signature"
    end
    true
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def decode_keys(value)
      value ||= {}
      if value.is_a?(String)
        raise InvalidConfiguration, "Identity signing keyring exceeds its configuration bound" if value.bytesize > MAX_CONFIG_BYTES
        value = JSON.parse(value)
      end
      unless value.is_a?(Hash) && value.size <= MAX_KEYS
        raise InvalidConfiguration, "Identity signing keys must be a bounded keyring"
      end
      value.to_h do |id, encoded|
        unless valid_id?(id) && encoded.is_a?(String) && encoded.bytesize == 44
          raise InvalidConfiguration, "Identity signing keys require valid IDs and Base64 32-byte secrets"
        end
        decoded = Base64.strict_decode64(encoded)
        unless decoded.bytesize == 32 && Base64.strict_encode64(decoded) == encoded
          raise InvalidConfiguration, "Identity signing keys require Base64 32-byte secrets"
        end
        [ id.dup.freeze, decoded.freeze ]
      end.freeze
    end

    def configured_id(value)
      return if value.nil?
      raise InvalidConfiguration, "Identity signing key IDs are invalid" unless valid_id?(value)
      value.dup.freeze
    end

    def valid_id?(value)
      value.is_a?(String) && KEY_ID.match?(value)
    end

    def valid_digest?(value)
      value.is_a?(String) && DIGEST.match?(value)
    end

    def authenticated_message(message, key_id)
      # Fixed version domain and validated separator-free ID bind the selected
      # key and protocol version, even if two IDs accidentally share key bytes.
      "#{DOMAIN}\0#{key_id}\0#{message}"
    end

    def hmac(key, message)
      OpenSSL::HMAC.hexdigest("SHA256", key, message).freeze
    end
end
