require "json/jwt"

# JOSE serialization/cryptography is delegated to the existing json-jwt and jwt
# dependencies. Never accept caller-selected algorithms or remote key URLs.
class Financekit::Crypto
  class << self
    def public_device_key(jwk)
      Financekit.require!(jwk.is_a?(Hash) && jwk.keys.sort == %w[crv kty x y] &&
        jwk["kty"] == "EC" && jwk["crv"] == "P-256" &&
        %w[x y].all? { |field| jwk[field].is_a?(String) && /\A[A-Za-z0-9_-]{43}\z/.match?(jwk[field]) }, "invalid_device_key")
      JWT::JWK.import(jwk).public_key
    rescue JWT::JWKError, OpenSSL::PKey::PKeyError, ArgumentError
      raise Financekit::Error.new("invalid_device_key")
    end

    def encryption_key
      key = OpenSSL::PKey.read(ENV.fetch("FINANCEKIT_ENCRYPTION_KEY"))
      raise "FinanceKit requires a private RSA key of at least 3072 bits" unless key.is_a?(OpenSSL::PKey::RSA) && key.private? && key.n.num_bits >= 3072
      key
    end

    def receipt_key
      key = OpenSSL::PKey.read(ENV.fetch("FINANCEKIT_RECEIPT_KEY"))
      raise "FinanceKit requires a private P-256 receipt key" unless key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.curve_name == "prime256v1"
      key
    end

    def server_id
      ENV.fetch("FINANCEKIT_SERVER_ID")
    end

    def keys
      {
        server_id: server_id,
        encryption: JWT::JWK.new(encryption_key).export,
        receipt: JWT::JWK.new(receipt_key).export
      }
    end

    def verify(envelope, item)
      claims, header = JWT.decode(envelope, public_device_key(item.device_public_key), true,
        algorithms: [ "ES256" ], verify_expiration: false, verify_iat: false,
        verify_aud: true, aud: server_id)
      Financekit.require!(header.keys.sort == %w[alg typ] && header["typ"] == "sure-financekit+jwt", "invalid_envelope", 400)
      Financekit.require!(claims.is_a?(Hash) && claims.keys.sort == %w[aud batch_id ciphertext connection_id digest generation previous_digest protocol sequence], "invalid_envelope", 400)
      Financekit.require!(claims["generation"].is_a?(Integer) && claims["protocol"].is_a?(Integer) && claims["connection_id"] == item.id &&
        claims["generation"] == item.generation && claims["protocol"] == Financekit::VERSION,
        "generation_conflict", 409)
      Financekit.require!(claims["ciphertext"].is_a?(String) &&
        Digest::SHA256.hexdigest(claims["ciphertext"]) == claims["digest"], "invalid_digest", 400)
      claims
    rescue JWT::DecodeError, ArgumentError
      raise Financekit::Error.new("invalid_signature", 401)
    end

    def decrypt(ciphertext)
      jwe = JSON::JWE.decode(ciphertext, :skip_decryption)
      Financekit.require!(jwe.header.keys.map(&:to_s).sort == %w[alg enc] &&
        jwe.alg.to_s == "RSA-OAEP" && jwe.enc.to_s == "A256GCM", "invalid_envelope", 400)
      jwe.decrypt!(encryption_key, [ "RSA-OAEP" ], [ "A256GCM" ])
      JSON.parse(jwe.plain_text, max_nesting: 12)
    rescue JSON::JWT::Exception, JSON::ParserError, OpenSSL::OpenSSLError, ArgumentError
      raise Financekit::Error.new("invalid_envelope", 400)
    end

    def receipt(batch)
      JWT.encode({
        "aud" => batch.financekit_item_id, "iss" => server_id,
        "protocol" => Financekit::VERSION, "batch_id" => batch.batch_id,
        "generation" => batch.generation, "sequence" => batch.sequence,
        "digest" => batch.digest, "status" => batch.status, "error_code" => batch.error_code,
        "counts" => batch.counts, "accepted_at" => batch.created_at.iso8601(6),
        "applied_at" => batch.applied_at&.iso8601(6), "issued_at" => Time.current.iso8601(6)
      }, receipt_key, "ES256", { typ: "sure-financekit-receipt+jwt" })
    end
  end
end
